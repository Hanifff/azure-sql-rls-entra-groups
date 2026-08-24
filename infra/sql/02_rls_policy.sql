-- ============================================================================
-- 02_rls_policy.sql
-- The predicate function and the security policy. This is the whole
-- authorization mechanism - everything else just feeds it data.
--
-- Idempotent: drops and recreates the policy and function on each run.
-- ============================================================================

-- The policy must go first: the function cannot be dropped while bound to it.
IF EXISTS (SELECT 1 FROM sys.security_policies WHERE name = 'DocumentAccessPolicy')
    DROP SECURITY POLICY Security.DocumentAccessPolicy;
GO

IF OBJECT_ID('Security.fn_rowaccess', 'IF') IS NOT NULL
    DROP FUNCTION Security.fn_rowaccess;
GO

-- ----------------------------------------------------------------------------
-- Returns a row (= access granted) when the caller is a member of @group_id.
--
-- Identity comes from DATABASE_PRINCIPAL_ID(), which is the principal on the
-- authenticated connection. Because the user's own Entra token opens the
-- connection (identity pass-through), the API cannot set, forge or influence
-- this value. There is no application-supplied input in this predicate at all.
--
-- Must be an inline TVF with SCHEMABINDING - that is a hard requirement for
-- RLS, and it is why the caller's object ID has to be looked up from
-- Security.UserIdentity rather than sys.database_principals.
--
-- NOTE: the IS_MEMBER call below tests the db_owner *database role*, not an
-- Entra group. That usage carries none of the scale problems that make
-- IS_MEMBER unsuitable for per-row Entra group checks.
-- ----------------------------------------------------------------------------
CREATE FUNCTION Security.fn_rowaccess (@group_id UNIQUEIDENTIFIER)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT 1 AS fn_rowaccess_result
    WHERE
        EXISTS (
            SELECT 1
            FROM Security.UserIdentity AS u
            INNER JOIN Security.GroupMembership AS m
                    ON m.UserObjectId = u.UserObjectId
            WHERE u.DatabasePrincipalId = DATABASE_PRINCIPAL_ID()
              AND u.IsActive = 1
              AND m.GroupObjectId = @group_id
        )
        -- IS_MEMBER always returns 0 for dbo, so the Entra admin (who connects
        -- as dbo) needs its own bypass for seeding and operations.
        OR USER_NAME() = 'dbo'
        OR IS_MEMBER('db_owner') = 1;
GO

-- ----------------------------------------------------------------------------
-- FILTER controls what SELECT returns.
-- BLOCK controls what INSERT/UPDATE/DELETE may touch.
--
-- Both are required. A FILTER predicate alone would let a user modify rows they
-- are only entitled to read, because the write path is not filtered.
-- ----------------------------------------------------------------------------
CREATE SECURITY POLICY Security.DocumentAccessPolicy
    ADD FILTER PREDICATE Security.fn_rowaccess(ReadGroupId)   ON dbo.Documents,
    ADD BLOCK  PREDICATE Security.fn_rowaccess(WriteGroupId)  ON dbo.Documents AFTER INSERT,
    ADD BLOCK  PREDICATE Security.fn_rowaccess(WriteGroupId)  ON dbo.Documents BEFORE UPDATE,
    ADD BLOCK  PREDICATE Security.fn_rowaccess(WriteGroupId)  ON dbo.Documents AFTER UPDATE,
    ADD BLOCK  PREDICATE Security.fn_rowaccess(WriteGroupId)  ON dbo.Documents BEFORE DELETE
WITH (STATE = ON, SCHEMABINDING = ON);
GO

PRINT 'RLS policy active on dbo.Documents.';
GO

-- ----------------------------------------------------------------------------
-- Application role. Users get their data access through this, and are denied
-- direct access to the entitlement tables - the predicate still reads them,
-- because a schema-bound predicate does not require the caller to have
-- permission on the tables it references.
-- ----------------------------------------------------------------------------
IF DATABASE_PRINCIPAL_ID('rls_app_user') IS NULL
    CREATE ROLE rls_app_user;
GO

GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.Documents TO rls_app_user;
DENY  SELECT, INSERT, UPDATE, DELETE ON SCHEMA::Security TO rls_app_user;
GO

-- ----------------------------------------------------------------------------
-- Lets a caller see how the database identified them, without granting access
-- to the entitlement tables. Ownership chaining applies: the view and the
-- tables it reads share an owner, so SELECT on the view is enough.
--
-- VisibleDocumentCount goes through the RLS policy, so it reports what this
-- caller can actually see - not the table total.
-- ----------------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_MyAccess
AS
SELECT
    USER_NAME()                                  AS DatabaseUser,
    DATABASE_PRINCIPAL_ID()                      AS DatabasePrincipalId,
    u.UserObjectId                               AS UserObjectId,
    ISNULL(m.MembershipCount, 0)                 AS GroupMembershipCount,
    (SELECT COUNT(*) FROM dbo.Documents)         AS VisibleDocumentCount,
    u.SyncedAt                                   AS MembershipSyncedAt
FROM (SELECT 1 AS anchor) AS a
LEFT JOIN Security.UserIdentity AS u
       ON u.DatabasePrincipalId = DATABASE_PRINCIPAL_ID()
OUTER APPLY (
    SELECT COUNT(*) AS MembershipCount
    FROM Security.GroupMembership AS gm
    WHERE gm.UserObjectId = u.UserObjectId
) AS m;
GO

GRANT SELECT ON dbo.vw_MyAccess TO rls_app_user;
GO

PRINT 'Role rls_app_user configured.';
GO
