-- ============================================================================
-- 05_verify.sql
-- Post-deployment checks. Prints PASS/FAIL per assertion and raises an error
-- at the end if anything failed, so deploy.sh can gate on it.
--
-- Run as the Entra admin. Read-only apart from a temp table.
-- ============================================================================
SET NOCOUNT ON;

DECLARE @failures INT = 0;
DECLARE @msg NVARCHAR(400);

DECLARE @results TABLE (Check_ NVARCHAR(80), Result NVARCHAR(8), Detail NVARCHAR(200));

-- --- object existence -------------------------------------------------------
INSERT INTO @results
SELECT 'Security schema',            CASE WHEN SCHEMA_ID('Security') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, NULL
UNION ALL SELECT 'Security.UserIdentity',     CASE WHEN OBJECT_ID('Security.UserIdentity','U')     IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, NULL
UNION ALL SELECT 'Security.GroupMembership',  CASE WHEN OBJECT_ID('Security.GroupMembership','U')  IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, NULL
UNION ALL SELECT 'Security.SyncState',        CASE WHEN OBJECT_ID('Security.SyncState','U')        IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, NULL
UNION ALL SELECT 'dbo.Documents',             CASE WHEN OBJECT_ID('dbo.Documents','U')             IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, NULL
UNION ALL SELECT 'dbo.vw_MyAccess',           CASE WHEN OBJECT_ID('dbo.vw_MyAccess','V')           IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, NULL
UNION ALL SELECT 'Predicate fn_rowaccess',    CASE WHEN OBJECT_ID('Security.fn_rowaccess','IF')    IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, NULL
UNION ALL SELECT 'usp_RefreshUserIdentity',   CASE WHEN OBJECT_ID('Security.usp_RefreshUserIdentity','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, NULL
UNION ALL SELECT 'usp_MergeGroupMembership',  CASE WHEN OBJECT_ID('Security.usp_MergeGroupMembership','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END, NULL;

-- --- policy is enabled ------------------------------------------------------
INSERT INTO @results
SELECT 'Security policy enabled',
       CASE WHEN EXISTS (SELECT 1 FROM sys.security_policies
                         WHERE name = 'DocumentAccessPolicy' AND is_enabled = 1)
            THEN 'PASS' ELSE 'FAIL' END,
       NULL;

-- --- both a FILTER and BLOCK predicate are bound ----------------------------
INSERT INTO @results
SELECT 'FILTER predicate bound',
       CASE WHEN EXISTS (SELECT 1 FROM sys.security_predicates sp
                         JOIN sys.security_policies pol ON pol.object_id = sp.object_id
                         WHERE pol.name = 'DocumentAccessPolicy' AND sp.predicate_type_desc = 'FILTER')
            THEN 'PASS' ELSE 'FAIL' END, NULL
UNION ALL
SELECT 'BLOCK predicates bound',
       CASE WHEN (SELECT COUNT(*) FROM sys.security_predicates sp
                  JOIN sys.security_policies pol ON pol.object_id = sp.object_id
                  WHERE pol.name = 'DocumentAccessPolicy' AND sp.predicate_type_desc = 'BLOCK') >= 3
            THEN 'PASS' ELSE 'FAIL' END,
       CONCAT('count=', (SELECT COUNT(*) FROM sys.security_predicates sp
                         JOIN sys.security_policies pol ON pol.object_id = sp.object_id
                         WHERE pol.name = 'DocumentAccessPolicy' AND sp.predicate_type_desc = 'BLOCK'));

-- --- supporting indexes exist (this is the performance design) --------------
INSERT INTO @results
SELECT 'PK_GroupMembership clustered',
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes
                         WHERE object_id = OBJECT_ID('Security.GroupMembership')
                           AND name = 'PK_GroupMembership' AND type_desc = 'CLUSTERED')
            THEN 'PASS' ELSE 'FAIL' END, NULL
UNION ALL
SELECT 'IX_Documents_ReadGroupId',
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes
                         WHERE object_id = OBJECT_ID('dbo.Documents')
                           AND name = 'IX_Documents_ReadGroupId')
            THEN 'PASS' ELSE 'FAIL' END, NULL;

-- --- app role cannot read the entitlement tables directly -------------------
INSERT INTO @results
SELECT 'Security schema denied to app role',
       CASE WHEN EXISTS (
            SELECT 1 FROM sys.database_permissions p
            JOIN sys.database_principals pr ON pr.principal_id = p.grantee_principal_id
            WHERE pr.name = 'rls_app_user'
              AND p.state_desc = 'DENY'
              AND p.major_id = SCHEMA_ID('Security'))
            THEN 'PASS' ELSE 'FAIL' END, NULL;

-- --- data volume ------------------------------------------------------------
DECLARE @docs INT      = (SELECT COUNT(*) FROM dbo.Documents);
DECLARE @groups INT    = (SELECT COUNT(DISTINCT ReadGroupId) FROM dbo.Documents);
DECLARE @members INT   = (SELECT COUNT(*) FROM Security.GroupMembership);
DECLARE @users INT     = (SELECT COUNT(*) FROM Security.UserIdentity);

INSERT INTO @results VALUES
    ('Documents seeded',  CASE WHEN @docs   > 0 THEN 'PASS' ELSE 'FAIL' END, CONCAT(@docs,   ' rows')),
    ('Distinct read groups', CASE WHEN @groups > 0 THEN 'PASS' ELSE 'FAIL' END, CONCAT(@groups, ' groups')),
    ('UserIdentity rows', CASE WHEN @users  > 0 THEN 'PASS' ELSE 'WARN' END, CONCAT(@users,  ' users')),
    ('GroupMembership rows', CASE WHEN @members > 0 THEN 'PASS' ELSE 'WARN' END, CONCAT(@members, ' memberships'));

-- --- results ----------------------------------------------------------------
SELECT Check_ AS [Check], Result, Detail FROM @results;

SELECT @failures = COUNT(*) FROM @results WHERE Result = 'FAIL';

PRINT '';
PRINT CONCAT('Documents: ', @docs, '  |  distinct read groups: ', @groups,
             '  |  users: ', @users, '  |  memberships: ', @members);

IF @failures > 0
BEGIN
    SET @msg = CONCAT('VERIFY FAILED: ', @failures, ' check(s) did not pass.');
    RAISERROR(@msg, 16, 1);
END
ELSE
    PRINT 'VERIFY PASSED: all checks green.';
GO
