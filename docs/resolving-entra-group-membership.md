# Resolving Entra group membership inside Azure SQL

A row references a Microsoft Entra security group, and the database has to decide whether
the person writing that row is a member of it. Row-level security is the right mechanism
for the decision, but the decision needs a fact the database does not have.

The constraint that shapes the work is that Azure SQL cannot query Entra during a
statement. There is no mechanism for it. An RLS predicate is ordinary T-SQL, so it can
only use what the database already holds. So the real question is not how to write the
predicate, it is how group membership gets into the database before the query runs.

We tested four ways.

## The four options

| # | Option | Extra database principals | Works for any group | Freshness | Usable in an RLS predicate |
| --- | --- | --- | --- | --- | --- |
| 1 | Synced membership table | None | Yes | Sync interval you choose | Yes |
| 2 | `IS_MEMBER` with a principal per group | One per group | Only registered groups | Connection open | Yes |
| 3 | Identity passed by the application | None | Yes | Per request | Yes |
| 4 | `sys.login_token` snapshot | None | Yes | Connection open | No |

The deciding factors are how many database principals each option requires, and whether
the predicate can actually reach the data.

Environment for the numbers below: Azure SQL Basic tier (5 DTU), 100,000 rows across
2,000 projects, a test user in 250 groups, Entra-only authentication with the user's own
token opening the connection.

## Shared groundwork: the data model

All four options sit on the same three tables.

```
Document       DocumentId, DocumentName
ProjectAccess  ProjectId, EntraIdWrite, EntraIdRead      synced from an IAM system
DocumentLine   DocumentLineId, DocumentId, ProjectId     the protected table
```

A row carries a `ProjectId`, not a group. The group is reached through `ProjectAccess`.
Reads are open and handled by table permissions, so only writes need row-level security.

What differs between the options is only the last hop: how the database establishes
whether the caller is in the group that `ProjectAccess` names.

## Option 1: Synced membership table

A scheduled job writes user-to-group membership into a table, and the predicate joins it.

```
Security.GroupMembership (UserObjectId, GroupObjectId)
```

One row per user-to-group pair, keyed on Entra object IDs. The predicate walks:

```
row.ProjectId -> ProjectAccess.EntraIdWrite -> GroupMembership -> caller
```

**Pros**

- No database principals per group. Only the per-user principals any connection needs.
- Any group works, including ones defined after the system was built, because the sync
  stores each user's full membership rather than a catalogue of groups.
- Matches on object IDs, so renaming a group in Entra changes nothing.
- The clustered key makes the check an index seek. A paged API query costs 6 logical
  reads on the data table.
- Revocation timing is a number you choose and can state in a contract.
- The sync needs only `db_datawriter` on one schema, so directory administration stays
  separate from database administration.

**Cons**

- A sync job to build and operate.
- Membership is as fresh as the last run. Removing someone from a group takes effect at
  the next sync, which is a real security window.
- More rows than any other option. Ten thousand users in 200 groups each is about two
  million rows, roughly 120 MB.
- A full table scan costs about two logical reads per row against the entitlement table,
  so whole-table aggregates should come from a summary table.

## Option 2: `IS_MEMBER` with a principal per group

The database answers the membership question natively. `IS_MEMBER` accepts a value from a
column, so the group named on the row can be passed straight in.

It only resolves groups that already exist as database principals, so every group that
might appear on a row has to be registered first:

```sql
CREATE USER [project-4711-writers] FROM EXTERNAL PROVIDER;
```

**Pros**

- No sync job for membership. The database resolves it at login.
- No staleness within a session. Membership is whatever it was when the connection
  opened.
- The predicate is a single function call and is easy to read.

**Cons**

- One database principal per group, in every database, maintained for the life of the
  system. We measured `CREATE USER ... FROM EXTERNAL PROVIDER` at 90 ms each, so 100,000
  groups is about 2.5 hours of setup per database, and every new group adds more.
- It matches on display name, not object ID. Entra permits duplicate display names and
  Azure SQL requires them to be unique, so collisions are certain at scale. Renaming a
  group in Entra silently stops it matching, and access is denied with no error.
- Not usable by an index. It is a scalar function evaluated per candidate row, so a
  filter on the row's group column cannot seek.
- Registering groups is DDL, so the process doing it needs permanent DDL rights in
  production plus Graph read access.
- A sync job is still required, just a different one: something has to create and drop
  those principals as the directory changes.

**Where it fits.** A small, stable set of groups. The mechanism is sound; it is the
group count that rules it out.

## Option 3: Identity passed by the application

The application connects with a service account, validates the user's token itself, and
tells the database who the caller is.

```sql
EXEC sp_set_session_context 'UserObjectId', '<oid from the validated token>', @read_only = 1;
```

The predicate then reads `SESSION_CONTEXT` instead of the connection identity. Membership
still comes from a table, so this is Option 1 with a different identity anchor.

**Pros**

- No per-user database principals either. One service account connects for everyone.
- One connection pool for all users, rather than a pool per user, which matters at high
  concurrency.
- Sidesteps the 2,048 group login limit entirely, because the user never authenticates to
  SQL.

**Cons**

- The application becomes part of the security model. The database believes whatever it
  is told, and a bug or an injection point becomes full impersonation of any user.
- Every connection must set the context. A missed one is a silent security hole rather
  than an error.
- Session context persists on a pooled connection, so the reset path has to be correct.
- Nothing is auditable against the directory from the database side.

**Where it fits.** When users reach the database through an application rather than with
their own credentials, which is common, and the application is already inside the trust
boundary.

## Option 4: `sys.login_token` snapshot

Azure SQL already knows the caller's groups at login. `sys.login_token` lists them.

We checked what it contains: 16 entries, 15 of them Entra groups, and only one an actual
database principal. So group membership is genuinely present without anyone running
`CREATE USER`.

Two things stop it being the answer.

It stores SIDs, not names:

```
name                                                   type
S-1-9-3-0x2462162104615311810661601441596557243178225  WINDOWS GROUP
```

That is precisely why `IS_MEMBER` needs the `CREATE USER` step. The principal supplies the
name-to-SID mapping. Matching on object IDs avoids needing it at all.

And it cannot appear in a predicate. RLS predicate functions must be schema-bound, and
schema binding forbids system objects:

```
Cannot schema bind table valued function because it references
system object 'sys.login_token'.
```

**Pros**

- No principals, no sync, no staleness. The information is already there.
- Outside RLS, in a stored procedure or an ordinary query, it is a better replacement for
  `IS_MEMBER` than `IS_MEMBER` is, because it works on SIDs and needs no registration.

**Cons**

- Unusable in an RLS predicate, which is the one place this problem needs solving.
- The workaround is to copy the token into a real table at session start and read that.
  It works, but it keys on `@@SPID`, which Azure SQL reuses after a disconnect. A session
  that fails to clear and repopulate leaves the next caller holding the previous caller's
  groups. That fails open.
- Requires the application to run the copy on every connection, so a missed one is again
  silent.

**Where it fits.** Authorization checks in stored procedures rather than row-level
security.

## Limits that apply regardless

All three are per user and unaffected by how many groups exist in the tenant.

| Limit | Value | Effect |
| --- | --- | --- |
| Azure SQL login | 2,048 groups | The user cannot connect at all |
| Entra membership | 7,000 groups | Cannot be added to more groups |
| JWT `groups` claim | 200 groups | Claim omitted, overage claim returned instead |

The JWT limit does not apply to any of these. Azure SQL resolves group membership itself
at login and does not read the `groups` claim from the token.

The 2,048 limit is a login constraint rather than an authorization one. If a user exceeds
it, the fix is Option 3, not a change to how rows are filtered. A membership table holds
any number of groups per user without difficulty.

## Which one to pick

- **Groups numbering in the thousands or more, and the user's own token opens the
  connection: Option 1.** The only cost is a sync job, and one is needed for Option 2
  anyway.
- **A small, stable set of groups: Option 2.** Fewer moving parts, and the principal count
  stays manageable.
- **Users reach the database through an application on a shared service account, or
  connection concurrency is high, or anyone is near 2,048 groups: Option 3**, with Option
  1's table behind it.
- **Authorization in stored procedures rather than row-level security: Option 4.**

Options 1 and 3 are not really alternatives to each other. They share the same entitlement
table and differ only in where the caller's identity comes from, so moving between them is
a one-line change to the predicate.

## Takeaway

Row-level security is not the hard part. Predicates are ordinary T-SQL and can only use
facts the database already holds, and no database can call an identity provider in the
middle of a statement. Every option is a variation on getting membership in ahead of time.

The choice comes down to what you are willing to maintain. `IS_MEMBER` looks like it
avoids a sync job but does not, because something still has to create and drop a database
principal for every group in the directory. A two-column table needs the same sync and
none of the schema churn.

## Try it yourself

A working implementation, with the enforcement tests and the benchmark that produced these
numbers, is in the repository:
[Hanifff/azure-sql-rls-entra-groups](https://github.com/Hanifff/azure-sql-rls-entra-groups).
