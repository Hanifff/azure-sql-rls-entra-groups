-- ============================================================================
-- 11_project_model_policy.sql
--
-- Two predicates, because the customer has told us two different things and
-- both need to be demonstrable:
--
--   write   BLOCK on DocumentLine, member of ProjectAccess.EntraIdWrite.
--           This is what the diagram asks for.
--
--   read    FILTER on DocumentLine, member of ProjectAccess.EntraIdRead.
--           The diagram says everyone reads everything, but the original
--           email described a read group per row. Both are built. Read
--           filtering is OFF by default, matching the diagram.
--           Switch it with 14_project_model_toggle_read.sql.
--
-- Idempotent.
-- ============================================================================

IF EXISTS (SELECT 1 FROM sys.security_policies WHERE name = 'ProjectLinePolicy')
    DROP SECURITY POLICY Security.ProjectLinePolicy;
GO

IF OBJECT_ID('Security.fn_can_write_project', 'IF') IS NOT NULL
    DROP FUNCTION Security.fn_can_write_project;
GO
IF OBJECT_ID('Security.fn_can_read_project', 'IF') IS NOT NULL
    DROP FUNCTION Security.fn_can_read_project;
GO

-- ----------------------------------------------------------------------------
-- Write check. This is the answer to "how do we resolve whether the person
-- entering a row is in the write group for that project".
--
-- The chain is:
--   row.ProjectId -> ProjectAccess.EntraIdWrite -> GroupMembership -> caller
--
-- No call to Entra happens here. Everything the database needs is local,
-- which is the whole point: SQL cannot query a directory mid-statement.
-- ----------------------------------------------------------------------------
CREATE FUNCTION Security.fn_can_write_project (@ProjectId BIGINT)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT 1 AS allowed
    WHERE
        EXISTS (
            SELECT 1
            FROM dbo.ProjectAccess        AS pa
            INNER JOIN Security.GroupMembership AS gm
                    ON gm.GroupObjectId = pa.EntraIdWrite
            INNER JOIN Security.UserIdentity    AS ui
                    ON ui.UserObjectId = gm.UserObjectId
            WHERE pa.ProjectId = @ProjectId
              AND ui.DatabasePrincipalId = DATABASE_PRINCIPAL_ID()
              AND ui.IsActive = 1
        )
        -- IS_MEMBER always returns 0 for dbo, so the Entra admin needs its own
        -- bypass for seeding and operations.
        OR USER_NAME() = 'dbo'
        OR IS_MEMBER('db_owner') = 1;
GO

-- ----------------------------------------------------------------------------
-- Read check. Same shape, read group instead of write group.
-- Only bound to the policy when read filtering is switched on.
-- ----------------------------------------------------------------------------
CREATE FUNCTION Security.fn_can_read_project (@ProjectId BIGINT)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT 1 AS allowed
    WHERE
        EXISTS (
            SELECT 1
            FROM dbo.ProjectAccess        AS pa
            INNER JOIN Security.GroupMembership AS gm
                    ON gm.GroupObjectId = pa.EntraIdRead
            INNER JOIN Security.UserIdentity    AS ui
                    ON ui.UserObjectId = gm.UserObjectId
            WHERE pa.ProjectId = @ProjectId
              AND ui.DatabasePrincipalId = DATABASE_PRINCIPAL_ID()
              AND ui.IsActive = 1
        )
        OR USER_NAME() = 'dbo'
        OR IS_MEMBER('db_owner') = 1;
GO

-- ----------------------------------------------------------------------------
-- Default policy: writes restricted, reads open. This matches the diagram.
--
-- BLOCK covers every write path. Without BEFORE UPDATE a user could move a row
-- out of a project they control; without AFTER UPDATE they could move one into
-- a project they do not.
-- ----------------------------------------------------------------------------
CREATE SECURITY POLICY Security.ProjectLinePolicy
    ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine AFTER INSERT,
    ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine BEFORE UPDATE,
    ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine AFTER UPDATE,
    ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine BEFORE DELETE
WITH (STATE = ON, SCHEMABINDING = ON);
GO

PRINT 'Write policy active on dbo.DocumentLine. Reads are open.';
GO

-- ----------------------------------------------------------------------------
-- Application role.
-- ----------------------------------------------------------------------------
IF DATABASE_PRINCIPAL_ID('rls_app_user') IS NULL
    CREATE ROLE rls_app_user;
GO

GRANT SELECT, INSERT, UPDATE, DELETE ON dbo.DocumentLine  TO rls_app_user;
GRANT SELECT ON dbo.Document      TO rls_app_user;
GRANT SELECT ON dbo.ProjectAccess TO rls_app_user;
DENY  SELECT, INSERT, UPDATE, DELETE ON SCHEMA::Security TO rls_app_user;
GO

-- ----------------------------------------------------------------------------
-- Lets a caller see how the database identified them, without granting access
-- to the entitlement tables. Ownership chaining applies: the view and the
-- tables it reads share an owner, so SELECT on the view is enough.
-- ----------------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_MyAccess
AS
SELECT
    USER_NAME()                          AS DatabaseUser,
    DATABASE_PRINCIPAL_ID()              AS DatabasePrincipalId,
    u.UserObjectId                       AS UserObjectId,
    ISNULL(m.MembershipCount, 0)         AS GroupMembershipCount,
    (SELECT COUNT(*) FROM dbo.DocumentLine) AS VisibleDocumentCount,
    u.SyncedAt                           AS MembershipSyncedAt
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

-- ============================================================================
-- For comparison: the IS_MEMBER version of the same check.
--
-- It is shorter, and because it only runs on writes the per-row cost that
-- rules it out elsewhere does not apply here. Two conditions make it awkward
-- at high project counts:
--
--   1. Every write group must exist as a database principal:
--        CREATE USER [<group display name>] FROM EXTERNAL PROVIDER;
--      One per project, maintained as projects come and go.
--
--   2. IS_MEMBER takes a group NAME, not an object ID. ProjectAccess would
--      need to store display names, which are not unique in Entra and change.
--
--   CREATE FUNCTION Security.fn_can_write_ismember (@ProjectId BIGINT)
--   RETURNS TABLE
--   WITH SCHEMABINDING
--   AS
--   RETURN
--       SELECT 1 AS allowed
--       WHERE EXISTS (
--           SELECT 1
--           FROM dbo.ProjectAccess AS pa
--           WHERE pa.ProjectId = @ProjectId
--             AND IS_MEMBER(pa.EntraIdWriteName) = 1
--       );
-- ============================================================================
