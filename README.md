# Row-level authorization in Azure SQL driven by Microsoft Entra groups

> [!NOTE]
> Guidance, not a production-ready setup. Adapt, harden and test it for your own
> environment before relying on it.

Rows reference a Microsoft Entra security group. The database decides who may read
and write each row, not the application.

The signed-in user's own token opens the database connection, so Azure SQL
authenticates the end user directly. The API sends no identity and no group
membership, so there is nothing for it to assert or spoof.

Deploy it into your own subscription, run the tests, read the numbers, tear it
down.

## Contents

- [Run it](#run-it)
- [What gets created](#what-gets-created)
- [How authorization works](#how-authorization-works)
- [The sync job](#the-sync-job)
- [Measured results](#measured-results)
- [Design decisions](#design-decisions)
- [Repository layout](#repository-layout)

## Run it

Five steps. Requires the az CLI, the .NET SDK and `zip`. No `sqlcmd`.

### 1. Sign in and configure

```bash
az login
./setup.sh
```

`setup.sh` asks for your subscription, region, naming and two demo users. It
validates each answer, checks whether you can create security groups in your
directory, and saves the result to `infra/.env`. Nothing it saves is secret, and
the file is not committed.

### 2. Deploy the database

```bash
cd infra
./deploy.sh --sql-only
```

A couple of minutes. It shows what it will create and asks before creating it.

The run ends with 19 verification checks and 7 enforcement tests. If either
fails, the deployment fails.

### 3. Run the demo

```bash
./demo.sh
```

Resets the data, waits for Enter, then prints eight steps. It handles the access
token, the configuration and the firewall itself, including adding your current IP
if it has changed and re-enabling public network access if a policy switched it off.

The setup: anna is in the write and read groups for project 12345678. bjorn is in
no groups. Both are ordinary database users with no special rights, and nothing else
differs between them.

| Step | Who does what | Result |
| --- | --- | --- |
| 1 | Show `ProjectAccess` and `DocumentLine` | Project 12345678 maps to a write group. Rows carry a `ProjectId`, not a group. |
| 2 | anna and bjorn each `SELECT` | Both see all 100,002 rows. Reads are open, handled by table permissions. |
| 3 | anna inserts into project 12345678 | Allowed. `Security.GroupMembership` has her in that project's write group. |
| 4 | bjorn runs the identical insert | Blocked. He has no row in `GroupMembership`. |
| 5 | anna inserts into project 98765432 | Blocked. Her membership covers one project, not the other. |
| 6 | anna updates her own row to point at project 98765432 | Blocked. A FILTER predicate alone would miss this. |
| 7 | Delete anna's rows from `GroupMembership`, she retries step 3 | Blocked. Revocation applies on the next statement, with no reconnect. |
| 8 | Restore and clean up | Back to the starting state, safe to run again. |

Steps 6 and 7 are the ones people have not usually considered.

Every block traces to one table. Remove the row from `GroupMembership` and access
disappears; put it back and it returns. Nothing else in the system changes.

### Reads and writes together

Reads are open by default, which is why step 2 shows both users seeing everything.
A second story switches read filtering on and shows both predicates at once:

```bash
./demo.sh readwrite
```

| Step | Shows |
| --- | --- |
| 1 | One FILTER and four BLOCK predicates now bound |
| 2 | anna sees 1 row, bjorn sees 0, table holds 100,002 |
| 3 | anna writes to a project she can read, and sees the row afterwards |
| 4 | anna is blocked on a project she can neither read nor write |
| 5 | Write access without read access |
| 6 | bjorn sees nothing and writes nothing |
| 7 | Restores everything, including read filtering off |

Step 5 is worth pausing on. anna is added to the write group of a project but not
its read group, then inserts a row:

```
  rows anna can see in project 98765432 : 0
  rows actually there                   : 2
```

She wrote a row she cannot read back. FILTER governs reads, BLOCK governs writes,
and nothing requires them to agree.

For the same comparison as a table rather than a narrative:

```bash
./demo.sh compare
```

```
Read filtering  User   Rows visible  Write 12345678  Write 98765432
read OFF        anna   100002        yes             no
read OFF        bjorn  100002        no              no
read ON         anna   1             yes             no
read ON         bjorn  0             no              no
```

### Running it at your own pace

Both stories can be driven one step at a time, so you can pause and explain.

```bash
./demo.sh reset
./demo.sh tables     # the five tables and how they connect
./demo.sh access     # who is entitled to what
./demo.sh who anna   # her groups, her projects, and what she cannot reach
./demo.sh step 3     # anna writes, allowed
./demo.sh step 4     # bjorn, identical statement, blocked
./demo.sh step 6     # anna cannot move her own row
./demo.sh step 7     # delete one membership row, access gone
./demo.sh step 8     # restore
```

`./demo.sh rwstep 1` to `7` walks the read plus write story the same way. Run
`rwstep 1` first, since it binds the FILTER predicate, and finish with `rwstep 7`.

In `./demo.sh tables`, anna's rows in `GroupMembership` carry the same GUIDs as the
write and read groups on project 12345678 in `ProjectAccess`, so the whole chain can
be traced before anything runs.

### 4. Optional, add the APIs and gateway

The database and `./demo.sh` are enough to show row-level security. To show the
whole path, from a signed-in user through a gateway and an API into the database,
deploy everything:

```bash
./deploy.sh
```

Adds storage, an App Service plan, Application Insights, both Function Apps and API
Management. **APIM takes 30 to 45 minutes to provision on first create** and is by
far the most expensive resource, so start it early and tear it down afterwards.

```bash
source ./config.sh
GATEWAY="https://${APIM_NAME}.azure-api.net"
TOKEN=$(az account get-access-token \
    --resource https://database.windows.net --query accessToken -o tsv)
```

The gateway rejects unauthenticated traffic before it reaches the function app:

```bash
curl -s -o /dev/null -w '%{http_code}\n' "$GATEWAY/rest/health"
curl -s -o /dev/null -w '%{http_code}\n' "$GATEWAY/rest/documents"
curl -s -o /dev/null -w '%{http_code}\n' "$GATEWAY/rest/documents" -H "Authorization: Bearer $TOKEN"
```

| Request | Expected | Why |
| --- | --- | --- |
| `/rest/health` without a token | 200 | Health is deliberately open |
| `/rest/documents` without a token | 401 | Rejected at the gateway, never reaches the function |
| `/rest/documents` with a token | 200 | Reaches the database, which decides the rows |

Then show how the database identified the caller:

```bash
curl -s "$GATEWAY/rest/my-access" -H "Authorization: Bearer $TOKEN"
```

It returns the database principal, the Entra object ID, the synced group count and
how many rows are visible. The point to make out loud is that the API sent no
identity and no group membership. It forwarded a token, and the database worked out
the rest.

The same thing through GraphQL, whose queries are `documents`, `document(id:)` and
`myAccess`:

```bash
curl -s "$GATEWAY/graphql" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ myAccess { databaseUser groupMembershipCount visibleDocumentCount } }"}'
```

Two API styles, no filtering logic in either, identical results.

As the Entra admin you connect as `dbo`, which bypasses the policy by design, so
`my-access` reports every row. That is correct rather than a bug, but it means the
API path does not demonstrate filtering unless you call it as a non-admin. Use the
API to show the token flow and the gateway, and `./demo.sh` to show the rows.

### 5. Tear it down

```bash
./destroy.sh
```

Removes the resource group and the Entra groups it created. `./deploy.sh`
rebuilds the same environment under the same names.

### Other commands

| Command | Shows |
| --- | --- |
| `./demo.sh tables` | all five tables, for opening the demo |
| `./demo.sh access` | who is entitled to read and write what |
| `./demo.sh who anna` | one user in full, with the project mapping |
| `./demo.sh compare` | read and write, both users, both modes, one table |
| `./demo.sh step N` | one step of the write story, 1 to 8 |
| `./demo.sh rwstep N` | one step of the read plus write story, 1 to 7 |
| `./demo.sh story` | run the write story again without resetting |
| `./demo.sh readwrite` | the read plus write story |
| `./demo.sh tests` | the seven enforcement tests |
| `./demo.sh bench` | logical reads and timings |
| `./demo.sh read on` | switch read filtering on |
| `./demo.sh read off` | switch it back off, the default |
| `./demo.sh policy` | print the predicate and policy |
| `./sync-membership.sh` | sync the signed-in user's group membership |
| `./sync-membership.sh --all` | sync every registered user |

## What gets created

In your subscription:

| Resource | Purpose | Cost |
| --- | --- | --- |
| Azure SQL server and database | The demo, Basic tier | Low |
| Storage account | Functions runtime | Negligible |
| App Service plan, B1 | Hosts both function apps | Low |
| Application Insights | Function logs | Negligible |
| Two function apps | REST and GraphQL | Included in the plan |
| API Management, Developer tier | Gateway and JWT validation | The expensive one |

In your directory, four security groups.

Four, not thousands. Scale is demonstrated with synthetic group IDs in the
database, because the predicate only compares GUIDs and cannot tell the
difference. Creating thousands of real directory objects would prove nothing
extra and would leave debris behind.

### A note on who you are signed in as

Whoever deploys becomes the Entra admin of the SQL server, and an Entra admin
connects as `dbo`, which bypasses row-level security by design. Your own account
will see every row. That is correct behaviour, not a fault.

This is why `setup.sh` asks for two ordinary users. Filtering is only observable
when a non-admin signs in.

## How authorization works

Three objects.

**`Security.GroupMembership`** holds one row per user-to-group edge, keyed on
Entra object IDs. Object IDs rather than display names, because names are neither
unique nor stable in Entra. The clustered primary key is what makes the check an
index seek.

**`Security.UserIdentity`** maps the database principal on the connection to its
Entra object ID. It exists because an RLS predicate must be `SCHEMABINDING` and
therefore cannot read `sys.database_principals`.

**`Security.fn_can_write_project`** is the predicate:

```sql
CREATE FUNCTION Security.fn_can_write_project (@ProjectId BIGINT)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT 1 AS allowed
    WHERE EXISTS (
        SELECT 1
        FROM dbo.ProjectAccess              AS pa
        INNER JOIN Security.GroupMembership AS gm ON gm.GroupObjectId = pa.EntraIdWrite
        INNER JOIN Security.UserIdentity    AS ui ON ui.UserObjectId  = gm.UserObjectId
        WHERE pa.ProjectId = @ProjectId
          AND ui.DatabasePrincipalId = DATABASE_PRINCIPAL_ID()
    );
```

The chain it walks:

```
row.ProjectId -> ProjectAccess.EntraIdWrite -> GroupMembership -> caller
```

`DATABASE_PRINCIPAL_ID()` is the identity on the authenticated connection. The
application cannot set it, forge it or pass it.

The policy binds it to every write path:

```sql
CREATE SECURITY POLICY Security.ProjectLinePolicy
    ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine AFTER INSERT,
    ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine BEFORE UPDATE,
    ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine AFTER UPDATE,
    ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine BEFORE DELETE
WITH (STATE = ON, SCHEMABINDING = ON);
```

`BEFORE UPDATE` and `AFTER UPDATE` are both required. Without the first, a user
could move a row out of a project they control. Without the second, into one they
do not.

Reads are open by default and handled by table-level permissions. A read
predicate exists and can be switched on with `./demo.sh read on` if rows need
read restrictions too.

`SCHEMABINDING` is not optional. `CREATE SECURITY POLICY` rejects a predicate
function that was not created with it:

```
Cannot schema bind security policy. Function is not schema bound.
```

That is also what makes the permission model work. Callers hold the
`rls_app_user` role, which is granted the data and explicitly denied the
`Security` schema. The predicate still reads those tables, because a schema-bound
predicate does not require the caller to hold permission on what it references.
Without it, every user would need read access to the entitlement data.

## The sync job

A scheduled job reads group membership and writes it into SQL, so the database
never calls Entra during a query.

It uses `getMemberObjects`, which returns transitive membership. `memberOf`
returns direct membership only and silently misses nested groups.

The merge replaces rather than appends, so removal from a group in Entra removes
the row here. Offboarding needs no separate cleanup.

**Scope by user, not by group.** Sync each user's full membership rather than a
catalogue of groups. Table size then follows your user count and is unaffected by
how many groups exist in the tenant. This also means any group can be referenced
by any dataset without changing the sync.

| Users | Groups each | Rows | Approximate size |
| --- | --- | --- | --- |
| 1,000 | 200 | 200,000 | 12 MB |
| 10,000 | 200 | 2,000,000 | 120 MB |
| 100,000 | 200 | 20,000,000 | 1.2 GB |

**The interval is a revocation SLA.** Adding someone to a group late is harmless.
Removing them late is a security window. Set the frequency from that requirement.

`sync-membership.sh` uses delegated Graph permissions through the az CLI, so it
needs no admin consent. In production this is a timer-triggered Function or Logic
App authenticating as a managed identity with `GroupMember.Read.All`, using a
delta query so only changes transfer.

If membership is already maintained by an identity governance system, that system
can write the table directly and Graph is not needed. Use Graph if membership can
change directly in Entra without passing through that system, otherwise the
database will miss those changes.

## Measured results

Azure SQL Basic tier (5 DTU), 100,000 rows across 2,000 groups, test user in 250
groups, seeing 12,500 rows.

| Query | Documents | GroupMembership | UserIdentity | Elapsed |
| --- | --- | --- | --- | --- |
| Paged list, `TOP 50` | 6 reads | 100 | 100 | 0 ms |
| Single row by primary key | 3 reads | 2 | 2 | 0 ms |
| `COUNT(*)` over everything visible | 1,314 reads | 200,000 | 200,000 | 4,247 ms |

The predicate is evaluated per candidate row, so a full scan costs roughly two
logical reads per row per entitlement table. Point lookups and paged queries,
which is what an API issues, are inexpensive. Whole-table aggregates are not, and
should be served from a summary table.

Write predicates are cheap regardless, because writes are evaluated one row at a
time.

Basic tier is throttled at 5 DTU. Treat the reads-per-row shape as the meaningful
figure rather than the wall clock.

One optimisation was considered and rejected. Keying `GroupMembership` on
`DatabasePrincipalId` would remove the `UserIdentity` lookup and halve the reads,
but database principal IDs can be reused after `DROP USER`, which would let a new
user inherit a deleted user's entitlements. The Entra object ID is the safer key.

## Design decisions

### The four ways to resolve membership

Azure SQL cannot query Entra during a statement, so membership has to already be in
the database. There are four ways to get it there.

| # | Option | Principals per group | Any group | Usable in a predicate |
| --- | --- | --- | --- | --- |
| 1 | Synced membership table | None | Yes | Yes |
| 2 | `IS_MEMBER` with a principal per group | One each | Registered only | Yes |
| 3 | `sys.login_token` read directly | None | Yes | No |
| 4 | `SESSION_CONTEXT` | None | Yes | Yes |

Options 1 to 3 answer how the database learns the caller's groups. Option 4 answers
who the caller is, and is combined with option 1 rather than chosen instead of it.

This repository implements option 1. The sections below cover why, and the
trade-offs behind each of the others.

### Why not `IS_MEMBER()`

| | `IS_MEMBER()` | Membership table |
| --- | --- | --- |
| Group must exist as a database principal | Yes, one `CREATE USER` per group | No |
| Index usable on the group column | No, scalar function per row | Yes |
| Accepts object IDs | No, display names only | Yes |
| Membership freshness | Snapshot at connection open | Interval you choose |
| Revocation timing | Whenever the pooled connection recycles | The sync interval |

`IS_MEMBER` will accept a value from a column, which is what people usually hope
for. It fails on the prerequisite rather than the syntax: it only resolves groups
that already exist as database principals.

It remains the right tool for a small, stable set of groups.

### Why the principals are the problem, not the row count

The membership table holds far more rows than there would be principals. Rows are
the cheaper thing by a wide margin, because the two are different in kind.

| | One principal per group | Rows in a table |
| --- | --- | --- |
| What it is | Schema object, DDL | Data, DML |
| Initial load | One `CREATE USER` each, every one a Graph lookup | One bulk insert |
| Ongoing change | `DROP` and `CREATE` per directory change | Set-based update |
| Permission to maintain | DDL rights in production, plus Graph read | `db_datawriter` on one schema |
| Per database | Repeated in full | Repeated, but only data |
| Name collisions | Certain. Entra allows duplicate display names, SQL does not | None, keyed on object IDs |
| Group renamed in Entra | Silently stops matching | No effect, IDs do not change |
| Usable by an index | No | Yes |

A sync job is required either way. Groups are created, renamed and deleted
continuously, and something has to reflect that in the database. The only
question is whether that job emits `CREATE USER` and `DROP USER`, or `INSERT` and
`DELETE`.

A million rows load in seconds and update set-based. A hundred thousand
principals is a permanent DDL pipeline holding elevated rights in production.

### What the login token does and does not give you

`sys.login_token` lists the caller's Entra groups, including ones that are not
database principals, so the membership information is genuinely present at login.
Two things prevent it being the answer.

It stores SIDs, not names. `IS_MEMBER` matches by name, which is precisely why
the `CREATE USER` step exists: it supplies the name-to-SID mapping. Matching on
object IDs instead avoids needing it at all.

And it cannot be used in a predicate. Schema binding forbids system objects:

```
Cannot schema bind table valued function because it references
system object 'sys.login_token'.
```

Copying the token into a real table at session start does work, but it keys on
`@@SPID`, which Azure SQL reuses after a disconnect. A session that fails to
clear and repopulate leaves the next caller holding the previous caller's groups.
That fails open, so it is not suitable for a security control.

Outside RLS, in a stored procedure or ordinary query, `sys.login_token` is a
perfectly good replacement for `IS_MEMBER` and needs no principals.

### Limits

All three are per user and unaffected by how many groups exist in the tenant.

| Limit | Value | Effect |
| --- | --- | --- |
| Azure SQL login | 2,048 groups | The user cannot connect at all |
| Entra membership | 7,000 groups | Cannot be added to more groups |
| JWT `groups` claim | 200 groups | Claim omitted, overage claim instead |

The JWT limit does not apply here. Azure SQL resolves group membership itself at
login and does not read the `groups` claim, which is why group-based database
principals work with a plain `az account get-access-token`.

The 2,048 limit is a login constraint, not an authorization one. If a user
exceeds it, the fix is to stop authenticating that user directly to SQL, not to
change the authorization model. The membership table itself has no such limit.

Sources: [Entra authentication limitations for Azure SQL](https://learn.microsoft.com/azure/azure-sql/database/authentication-aad-overview#limitations),
[IS_MEMBER](https://learn.microsoft.com/sql/t-sql/functions/is-member-transact-sql).

### If users connect through a shared service account

This design assumes the user's own token opens the connection. That is what makes
`DATABASE_PRINCIPAL_ID()` trustworthy.

If the application connects with a service account or managed identity, SQL only
sees the application, and identity has to be passed in:

```sql
EXEC sp_set_session_context 'UserObjectId', '<oid from the validated token>', @read_only = 1;
```

```sql
-- and the predicate line becomes
WHERE u.UserObjectId = CAST(SESSION_CONTEXT(N'UserObjectId') AS UNIQUEIDENTIFIER)
```

The entitlement tables, the sync job and the policies are unchanged. What changes
is the trust boundary: the application becomes part of the security model.

### Database principals still required

Dropping `IS_MEMBER` removes the need for a principal per group. It does not
remove the need for a principal per user, if users connect with their own tokens.
Under `SESSION_CONTEXT` neither is required.

### Questions worth answering before adopting this

1. Whose credential opens the database connection: the user's or a service
   account's?
2. What does one group represent: a project, a tenant, a customer?
3. How many groups is a typical user in, and what is the maximum?
4. How fast must a group removal actually revoke access?
5. Do groups nest? If so the sync must use transitive membership.
6. One database or several? The entitlement tables and the sync fan out per
   database.

If a group exists per business object, consider keeping a small number of Entra
groups for organisational roles and modelling fine-grained permissions as data in
SQL. Entra groups are built for organisational membership with governance, access
reviews and lifecycle, not for per-object access control lists.

## Repository layout

```
setup.sh                   Interactive first-run setup, writes infra/.env
infra/
  config.sh                Naming and tags, reads .env and the az session
  deploy.sh                Empty subscription to running demo
  destroy.sh               Removes the resource group and the Entra groups
  demo.sh                  Runs the demo, handles token and firewall
  sync-membership.sh       Membership sync
  sqlrunner/               Runs .sql files with an Entra token, replaces sqlcmd
  sql/
    01_schema.sql          Business tables and the entitlement tables
    02_policy.sql          Predicates, policy, app role, dbo.vw_MyAccess
    03_procedures.sql      Procedures the sync job calls
    04_seed.sql            Demo data, size set by setup.sh
    05_verify.sql          19 post-deployment assertions
    06_test.sql            7 enforcement tests
    07_benchmark.sql       Logical reads and timings
    08_show_access.sql     Who is entitled to what
    09_toggle_read.sql     Switch read filtering on or off
    10_demo_setup.sql      Creates the demo users
    11_demo_run.sql        The eight-step write demo
    12_who.sql             One user, in full
    13_compare_modes.sql   Both read modes side by side
    14_demo_readwrite.sql  The seven-step read plus write demo
graphql-server/            Azure Function, GraphQL via HotChocolate
rest-api/                  Azure Function, REST
api-test-ui/               Browser client
```

### Naming and tags

Resources follow `<abbreviation>-<component>-<environment>-<region>-<instance>`,
using the [Cloud Adoption Framework abbreviations](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-abbreviations).
Names needing global uniqueness use a short hash of the subscription ID instead of
the instance number, so a rebuild lands on the same names but two subscriptions
never collide.

Everything is tagged with `application`, `costCenter`, `criticality`,
`dataClassification`, `environment`, `lifecycle`, `managedBy`, `owner` and
`project`. Change them in `infra/config.sh`.

## License

BSD 2-Clause. See [LICENSE](LICENSE).
