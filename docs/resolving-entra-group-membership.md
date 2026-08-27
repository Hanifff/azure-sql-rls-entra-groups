# Resolving Entra group membership inside Azure SQL

A row references a Microsoft Entra security group, and the database has to determine
whether the person writing that row is a member of it. Row-level security is the
appropriate mechanism for that decision, but the decision depends on a fact the
database does not hold.

The constraint that shapes the work is that Azure SQL cannot query Entra during a
statement. An RLS predicate is ordinary T-SQL and can only use what the database
already holds. The question is therefore not how to write the predicate, but how
group membership reaches the database before the query runs.

We implemented all four approaches against a live Azure SQL database and measured
them.

## What we tested

Azure SQL Basic tier at 5 DTU, the cheapest available. 100,000 rows across 2,000
projects, 4,004 group IDs, a test user in 250 groups. Entra-only authentication,
with the user's own token opening the connection.

The implementation of option 1 carries seven enforcement tests that run on every
deploy and fail it if the policy is not doing its job:

```
PASS  1. A user in no groups still reads all 100002 lines.
PASS  2. Member of the write group inserted into project 12345678.
PASS  3. A user outside the write group was blocked from inserting.
PASS  4. Write access to one project did not grant it on another.
PASS  5. A row could not be moved into a project the user cannot write.
PASS  6. Security schema is not directly readable by the app role.
PASS  7. Deleting the membership row revoked write on the next statement.
```

Tests 5 and 7 cover the cases most often missed. Test 5 fails if the policy blocks
only inserts, because a user could otherwise move an existing row into a project
they do not hold. Test 7 confirms that revocation applies on the next statement,
with no reconnect and no cache to clear.

Only 4 of the 4,004 group IDs are real Entra groups; the remainder are generated
GUIDs. The predicate compares GUIDs held in local tables and cannot distinguish
between the two, so creating 4,000 real groups would not have changed the result. It
would have taken approximately 2.8 hours at the 2,540 ms per group we measured.

## The options

Three ways to answer that question, and a fourth that changes who is asking.

| # | Option | Where membership comes from | Extra database principals | Usable in an RLS predicate |
| --- | --- | --- | --- | --- |
| 1 | Synced membership table | a table a job keeps current | none | Yes |
| 2 | `IS_MEMBER` with a principal per group | the login token, matched by name | one per group | Yes |
| 3 | `sys.login_token` read directly | the login token, matched by object ID | none | No |
| 4 | `SESSION_CONTEXT` | a table, as in option 1 | none | Yes |

Options 1 to 3 are three answers to the same question: how does the database learn
the caller's groups. Option 4 answers a different one: who is the caller. It is
combined with option 1 rather than chosen instead of it, and it matters when the
application connects on the user's behalf.

## Shared groundwork: the data model

All four options sit on the same three business tables.

```
Document       DocumentId, DocumentName
ProjectAccess  ProjectId, EntraIdWrite, EntraIdRead      synced from an IAM system
DocumentLine   DocumentLineId, DocumentId, ProjectId     the protected table
```

A row carries a `ProjectId`, not a group. The group is reached through `ProjectAccess`.
Reads are open and handled by table permissions, so only writes need row-level security.

What differs between the options is only the last hop: how the database establishes
whether the caller is in the group that `ProjectAccess` names.

---

## Option 1: Synced membership table (implemented here)

A scheduled job writes user-to-group membership into a table, and the predicate joins it.

**How it works.** One row per user-to-group pair, keyed on Entra object IDs.

```
Security.GroupMembership (UserObjectId, GroupObjectId)
```

The predicate walks three hops, all of them local:

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

**Two things the sync job has to get right.** It must read *transitive* membership,
Graph's `getMemberObjects` rather than `memberOf`, or nested groups fail silently.
And the merge must delete: it takes the user's complete current membership and
removes what is no longer there, so offboarding needs no separate cleanup.

The interval is a revocation SLA, not a performance setting. Adding someone late is
harmless; removing someone late is a security window. Note that option 2 has the
same lag and less control over it: `IS_MEMBER` resolves at login and never
refreshes, so with connection pooling a revoked user keeps access until the pool
recycles that connection, at an interval nobody sets or measures.

**Use it when** groups number in the thousands or more and the user's own token opens the
connection.

---

## Option 2: `IS_MEMBER` with a principal per group (small group sets)

The database answers the membership question natively, at the cost of registering every
group it might be asked about.

**How it works.** `IS_MEMBER` accepts a value from a column, so the group named on the row
can be passed straight in. It only resolves groups that already exist as database
principals, so each one has to be created first:

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

**Use it when** the set of groups is small and stable. The mechanism is sound; it is the
group count that rules it out.

---

## Option 3: `sys.login_token` read directly

Azure SQL already knows the caller's groups at login and exposes them in a system
view.

**How it works.** `sys.login_token` lists every group the caller belongs to. We
checked what it holds: 18 group entries for a test user, and every SID casts
cleanly to the Entra object ID:

```sql
SELECT CAST(sid AS UNIQUEIDENTIFIER) AS oid, type, usage
FROM sys.login_token WHERE type = 'WINDOWS GROUP';
```

```
oid                                   type           usage
11111111-2222-3333-4444-555555555555  WINDOWS GROUP  DENY ONLY
66666666-7777-8888-9999-aaaaaaaaaaaa  WINDOWS GROUP  DENY ONLY
```

Those are object IDs in exactly the form `ProjectAccess.EntraIdWrite` stores. No
names, no registration, nothing to keep in step with the directory.

**Pros**

- No sync job and no staleness. The information is already in the session.
- No database principal per group, unlike option 2.
- Matches on object IDs, so group renames are irrelevant.
- Outside RLS, in a stored procedure or an ordinary query, this is a better
  membership check than `IS_MEMBER` and needs nothing set up.

**Cons**

- It cannot be used in an RLS predicate. Predicate functions must be schema-bound,
  and schema binding forbids system objects:

  ```
  Cannot schema bind table valued function because it references
  system object 'sys.login_token'.
  ```

- The workaround, copying the token into a real table at session start, keys on
  `@@SPID`, which Azure SQL reuses after a disconnect. A session that fails to
  clear and repopulate leaves the next caller holding the previous caller's groups.
  That fails open.
- Membership is fixed when the connection opens, so with pooling a revoked user
  keeps access until the connection recycles.

**Use it when** the check lives in a stored procedure rather than in row-level
security. For RLS itself it is ruled out by one specific restriction, not by any
weakness in the data it holds.

---

## Option 4: `SESSION_CONTEXT`, when the application connects

This one is not an alternative to the first three. It changes how the database
learns *who the caller is*, and is combined with option 1's table.

**How it works.** The application connects with a service account, validates the
user's token itself, and asserts the identity on the connection:

```sql
EXEC sp_set_session_context 'UserObjectId', '<oid from the validated token>', @read_only = 1;
```

The predicate reads `SESSION_CONTEXT` instead of `DATABASE_PRINCIPAL_ID()`. One
line changes; the entitlement table and the sync job are identical.

**Pros**

- No per-user database principals, so nothing to create as staff join and leave.
- One connection pool for all users rather than a pool per user, which matters at
  high concurrency.
- The 2,048 group login limit does not apply, because the user never authenticates
  to SQL.
- Works when users reach the data through an application, which is the common case.

**Cons**

- The application becomes part of the security boundary. The database believes what
  it is told, so a bug or an injection point becomes impersonation of any user.
- Every connection must set the context. A missed one is a silent hole, not an
  error.
- Session context survives on a pooled connection, so the reset path has to be
  right.
- Nothing is auditable against the directory from the database side.

**Use it when** the application connects on the user's behalf. If the user's own
token opens the connection, `DATABASE_PRINCIPAL_ID()` is stronger and free.

---

## What option 1 costs to run

Measured on the environment above, with the test user seeing 12,500 of 100,000 rows.

| Query | Reads on the data table | Reads on the entitlement tables | Elapsed |
| --- | --- | --- | --- |
| Paged list, `TOP 50` | 6 | 100 | 0 ms |
| Single row by primary key | 3 | 2 | 0 ms |
| `COUNT(*)` over everything visible | 1,314 | 200,000 | 4,247 ms |

The first two are the queries an API typically issues. The predicate is effectively
free at that shape, because the clustered key turns the check into a seek.

The third row is the one to plan around. The predicate is evaluated per candidate
row, so a full scan costs roughly two logical reads per row against the entitlement
table. A security predicate remains a join even though it does not appear in the
query text, and whole-table aggregates are better served from a summary table.

For comparison, the setup cost of option 2: `CREATE USER ... FROM EXTERNAL PROVIDER`
measured at 90 ms, so registering 100,000 groups is approximately 2.5 hours per
database. That cost recurs for every database and does not end, since the directory
continues to change.

## Limits that apply regardless

All three limits are per user, and none is affected by how many groups exist in the
tenant.

| Limit | Value | Effect |
| --- | --- | --- |
| Azure SQL login | 2,048 groups | The user cannot connect at all |
| Entra membership | 7,000 groups | Cannot be added to more groups |
| JWT `groups` claim | 200 groups | Claim omitted, overage claim returned instead |

The JWT limit does not apply to any of these options. Azure SQL resolves group
membership itself at login and does not read the `groups` claim from the token.

The 2,048 limit is a login constraint rather than an authorization one. A user who
exceeds it is addressed by option 4, not by changing how rows are filtered. A
membership table holds any number of groups per user without difficulty.

## Which one to pick

- Groups in the thousands or more, user's own token opens the connection: **option 1**.
  The only cost is a sync job, and option 2 needs one anyway.
- A small, stable set of groups: **option 2**. Fewer moving parts.
- The check sits in a stored procedure rather than in RLS: **option 3**. It is the
  cleanest membership read available and needs no setup at all.
- The application connects on the user's behalf, or concurrency is high, or anyone
  is near 2,048 groups: **option 4**, with option 1's table behind it.

## Conclusion

The difficulty in this problem is not row-level security itself. A predicate is
ordinary T-SQL and can only use facts the database already holds, and no database
can call an identity provider in the middle of a statement. Each option is therefore
a way of making membership available in advance.

The three membership options succeed or fail for different reasons, and none of them
for lack of data. Option 2 holds the data but reaches it by display name, which
requires a database principal per group and breaks silently when a group is renamed.
Option 3 holds the data in the ideal form, object IDs, and is prevented from use
only by schema binding. Option 1 places those same object IDs in an ordinary table,
where a predicate can seek on them, at the cost of a job that keeps it current.

Three observations apply beyond this comparison.

**Identity taken from the connection is stronger than identity asserted by the
application.** When the user's own token opens the connection, the application sits
outside the security boundary. This is what distinguishes option 4 from the others,
and why it is better treated as a fallback than a default.

**Reads and writes are separate decisions.** A FILTER predicate governs visibility
and a BLOCK predicate governs modification, and nothing requires the two to agree. A
user granted write access to a project they cannot read will insert rows they cannot
subsequently see. Whether that is desirable is worth deciding explicitly.

**A group count in six figures is worth examining.** It can indicate that the
directory is being used to store per-object permissions. Entra groups are designed
for organisational membership, with governance, access reviews and lifecycle
attached, and those features carry overhead that per-object entitlements do not
need. One established middle ground is a smaller number of groups for organisational
roles, with fine-grained permissions modelled as data.

Two questions determine the rest. Does the user's own token open the connection, or
does an application connect on their behalf? That decides between
`DATABASE_PRINCIPAL_ID()` and option 4. And how quickly must removal from a group
withdraw access? That sets the sync interval. Both are worth settling before
implementation begins.

## Reference implementation

A working implementation, including the enforcement tests and the benchmark that
produced these figures, is available at
[Hanifff/azure-sql-rls-entra-groups](https://github.com/Hanifff/azure-sql-rls-entra-groups).
