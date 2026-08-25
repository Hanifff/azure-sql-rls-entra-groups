-- ============================================================================
-- 05_verify.sql
-- Post-deployment checks. Prints PASS or FAIL per assertion and raises an error
-- at the end if anything failed, so deploy.sh can gate on it.
--
-- Run as the Entra admin. Read-only apart from a table variable.
-- ============================================================================
SET NOCOUNT ON;

DECLARE @failures INT = 0;
DECLARE @results TABLE (Check_ NVARCHAR(80), Result NVARCHAR(8), Detail NVARCHAR(200));

-- --- objects exist ----------------------------------------------------------
INSERT INTO @results
          SELECT 'Security schema',           CASE WHEN SCHEMA_ID('Security') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, NULL
UNION ALL SELECT 'dbo.Document',              CASE WHEN OBJECT_ID('dbo.Document','U')      IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, NULL
UNION ALL SELECT 'dbo.ProjectAccess',         CASE WHEN OBJECT_ID('dbo.ProjectAccess','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, NULL
UNION ALL SELECT 'dbo.DocumentLine',          CASE WHEN OBJECT_ID('dbo.DocumentLine','U')  IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, NULL
UNION ALL SELECT 'Security.GroupMembership',  CASE WHEN OBJECT_ID('Security.GroupMembership','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, NULL
UNION ALL SELECT 'Security.UserIdentity',     CASE WHEN OBJECT_ID('Security.UserIdentity','U')    IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, NULL
UNION ALL SELECT 'Write predicate',           CASE WHEN OBJECT_ID('Security.fn_can_write_project','IF') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, NULL
UNION ALL SELECT 'Read predicate',            CASE WHEN OBJECT_ID('Security.fn_can_read_project','IF')  IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, NULL
UNION ALL SELECT 'usp_RefreshUserIdentity',   CASE WHEN OBJECT_ID('Security.usp_RefreshUserIdentity','P')  IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, NULL
UNION ALL SELECT 'usp_MergeGroupMembership',  CASE WHEN OBJECT_ID('Security.usp_MergeGroupMembership','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, NULL;

-- --- policy is enabled ------------------------------------------------------
INSERT INTO @results
SELECT 'Security policy enabled',
       CASE WHEN EXISTS (SELECT 1 FROM sys.security_policies
                         WHERE name = 'ProjectLinePolicy' AND is_enabled = 1)
            THEN 'PASS' ELSE 'FAIL' END, NULL;

-- --- every write path is covered --------------------------------------------
-- INSERT, UPDATE both ways, and DELETE. Missing one leaves a gap that is not
-- obvious from reading the policy.
DECLARE @blocks INT = (
    SELECT COUNT(*) FROM sys.security_predicates sp
    JOIN sys.security_policies pol ON pol.object_id = sp.object_id
    WHERE pol.name = 'ProjectLinePolicy' AND sp.predicate_type_desc = 'BLOCK');

INSERT INTO @results
SELECT 'BLOCK predicates bound',
       CASE WHEN @blocks >= 4 THEN 'PASS' ELSE 'FAIL' END,
       CONCAT('count=', @blocks);

-- --- indexes that carry the predicate ---------------------------------------
INSERT INTO @results
          SELECT 'PK_GroupMembership clustered',
                 CASE WHEN EXISTS (SELECT 1 FROM sys.indexes
                                   WHERE object_id = OBJECT_ID('Security.GroupMembership')
                                     AND name = 'PK_GroupMembership' AND type_desc = 'CLUSTERED')
                      THEN 'PASS' ELSE 'FAIL' END, NULL
UNION ALL SELECT 'IX_DocumentLine_ProjectId',
                 CASE WHEN EXISTS (SELECT 1 FROM sys.indexes
                                   WHERE object_id = OBJECT_ID('dbo.DocumentLine')
                                     AND name = 'IX_DocumentLine_ProjectId')
                      THEN 'PASS' ELSE 'FAIL' END, NULL;

-- --- the app role cannot read the entitlement tables ------------------------
INSERT INTO @results
SELECT 'Security schema denied to app role',
       CASE WHEN EXISTS (
            SELECT 1 FROM sys.database_permissions p
            JOIN sys.database_principals pr ON pr.principal_id = p.grantee_principal_id
            WHERE pr.name = 'rls_app_user'
              AND p.state_desc = 'DENY'
              AND p.major_id = SCHEMA_ID('Security'))
            THEN 'PASS' ELSE 'FAIL' END, NULL;

-- --- data -------------------------------------------------------------------
DECLARE @lines INT    = (SELECT COUNT(*) FROM dbo.DocumentLine);
DECLARE @projects INT = (SELECT COUNT(*) FROM dbo.ProjectAccess);
DECLARE @members INT  = (SELECT COUNT(*) FROM Security.GroupMembership);
DECLARE @users INT    = (SELECT COUNT(*) FROM Security.UserIdentity);

INSERT INTO @results VALUES
    ('Lines seeded',       CASE WHEN @lines    > 0 THEN 'PASS' ELSE 'FAIL' END, CONCAT(@lines, ' rows')),
    ('Projects seeded',    CASE WHEN @projects > 0 THEN 'PASS' ELSE 'FAIL' END, CONCAT(@projects, ' projects')),
    ('UserIdentity rows',  CASE WHEN @users    > 0 THEN 'PASS' ELSE 'WARN' END, CONCAT(@users, ' users')),
    ('GroupMembership rows', CASE WHEN @members > 0 THEN 'PASS' ELSE 'WARN' END, CONCAT(@members, ' memberships'));

SELECT Check_ AS [Check], Result, Detail FROM @results;
SELECT @failures = COUNT(*) FROM @results WHERE Result = 'FAIL';

PRINT '';
PRINT CONCAT('Lines: ', @lines, '  |  projects: ', @projects,
             '  |  users: ', @users, '  |  memberships: ', @members);

IF @failures > 0
BEGIN
    DECLARE @msg NVARCHAR(200) = CONCAT('VERIFY FAILED: ', @failures, ' check(s) did not pass.');
    RAISERROR(@msg, 16, 1);
END
ELSE
    PRINT 'VERIFY PASSED: all checks green.';
GO
