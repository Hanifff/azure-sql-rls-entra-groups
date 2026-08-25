# Row-level authorization in Azure SQL driven by Microsoft Entra groups

> [!WARNING]
> **This is a baseline, not production guidance.**
> It exists to demonstrate a pattern and to make the trade-offs measurable. It has
> not been reviewed for your data classification, threat model, compliance
> obligations, availability targets or scale. You are responsible for adapting,
> hardening and testing it for your own environment before relying on it.

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

The run ends with 19 verification checks and 5 enforcement tests. If either
fails, the deployment fails.

### 3. Run the demo

```bash
./demo.sh
```

Prints who can read and write what, then runs the enforcement tests.

```
User                Groups  Readable  Writable
------------------  ------  --------  --------
admin                  253     12600        50
demo-readwrite           2        50        50
demo-readonly            1        50         0

PASS  1. Alice sees 50 of 100000 rows (only her group).
PASS  2. Bob has no memberships and sees 0 rows.
PASS  3. BLOCK predicate stopped a write on a read-only row.
PASS  4. Security schema is not directly readable by the app role.
PASS  5. Deleting the membership row revoked access immediately.
```

The row to point at is `demo-readonly`: 50 rows readable, none writable. Same
table, same query, same application code.

### 4. Optional, add the APIs and gateway

```bash
./deploy.sh
```

Adds both Function Apps and API Management. APIM takes 30 to 45 minutes to
provision on first create and is the expensive part.

```bash
source ./config.sh
TOKEN=$(az account get-access-token \
    --resource https://database.windows.net --query accessToken -o tsv)
GATEWAY="https://${APIM_NAME}.azure-api.net"

curl -s "$GATEWAY/rest/health"
curl -s "$GATEWAY/rest/my-access"  -H "Authorization: Bearer $TOKEN"
curl -s "$GATEWAY/rest/documents"  -H "Authorization: Bearer $TOKEN"
```

| Request | Expected |
| --- | --- |
| `/rest/health` without a token | 200 |
| `/rest/documents` without a token | 401, rejected at the gateway |
| `/rest/documents` with a token | 200, filtered by RLS |

`my-access` reports how the database identified you: database principal, Entra
object ID, synced group count, and how many rows you can see.

### 5. Tear it down

```bash
./destroy.sh
```

Removes the resource group and the Entra groups it created. `./deploy.sh`
rebuilds the same environment under the same names.

### Other commands

| Command | Shows |
| --- | --- |
| `./demo.sh access` | who can read and write what |
| `./demo.sh tests` | the five enforcement tests |
| `./demo.sh bench` | logical reads and timings |
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

**`Security.fn_rowaccess`** is the predicate:

```sql
CREATE FUNCTION Security.fn_rowaccess (@group_id UNIQUEIDENTIFIER)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT 1 AS fn_rowaccess_result
    WHERE EXISTS (
        SELECT 1
        FROM Security.UserIdentity AS u
        INNER JOIN Security.GroupMembership AS m ON m.UserObjectId = u.UserObjectId
        WHERE u.DatabasePrincipalId = DATABASE_PRINCIPAL_ID()
          AND m.GroupObjectId = @group_id
    );
```

`DATABASE_PRINCIPAL_ID()` is the identity on the authenticated connection. The
application cannot set it, forge it or pass it.

The policy binds it twice:

```sql
CREATE SECURITY POLICY Security.DocumentAccessPolicy
    ADD FILTER PREDICATE Security.fn_rowaccess(ReadGroupId)   ON dbo.Documents,
    ADD BLOCK  PREDICATE Security.fn_rowaccess(WriteGroupId)  ON dbo.Documents AFTER INSERT,
    ADD BLOCK  PREDICATE Security.fn_rowaccess(WriteGroupId)  ON dbo.Documents BEFORE UPDATE,
    ADD BLOCK  PREDICATE Security.fn_rowaccess(WriteGroupId)  ON dbo.Documents AFTER UPDATE,
    ADD BLOCK  PREDICATE Security.fn_rowaccess(WriteGroupId)  ON dbo.Documents BEFORE DELETE
WITH (STATE = ON, SCHEMABINDING = ON);
```

A FILTER predicate controls reads and does nothing about writes. Without BLOCK, a
user can modify rows they are only entitled to read.

Callers hold the `rls_app_user` role, which is granted access to the data and
denied access to the `Security` schema. The predicate still reads those tables,
because a schema-bound predicate does not require the caller to hold permission
on what it references.

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
    01_schema.sql          Business table and the entitlement tables
    02_rls_policy.sql      Predicate, policy, app role, dbo.vw_MyAccess
    03_procedures.sql      Procedures the sync job calls
    04_seed_demo_data.sql  Demo data, size set by setup.sh
    05_verify.sql          19 post-deployment assertions
    06_test_rls.sql        5 enforcement tests
    07_benchmark.sql       Logical reads and timings
    08_show_access.sql     Who can see what
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

MIT. See [LICENSE](LICENSE).
