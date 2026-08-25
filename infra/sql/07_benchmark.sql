-- ============================================================================
-- 07_benchmark.sql
-- Measures what the predicate costs, so the design can be defended with numbers
-- rather than assertions.
--
-- Writes are the interesting case here, because the policy only restricts
-- writes. A write predicate is evaluated one row at a time, which is why it
-- stays cheap regardless of table size. Reads are measured too, for the case
-- where read filtering is switched on.
--
-- Cleans up after itself.
-- ============================================================================
SET NOCOUNT ON;

IF DATABASE_PRINCIPAL_ID('rls_bench_user') IS NOT NULL DROP USER rls_bench_user;
GO

CREATE USER rls_bench_user WITHOUT LOGIN;
ALTER ROLE rls_app_user ADD MEMBER rls_bench_user;
GO

DECLARE @benchOid UNIQUEIDENTIFIER = '33333333-3333-3333-3333-333333333333';
DECLARE @MembershipCount INT = 250;   -- a realistic number of groups for one user

DELETE FROM Security.GroupMembership WHERE UserObjectId = @benchOid;
DELETE FROM Security.UserIdentity    WHERE UserObjectId = @benchOid;

INSERT INTO Security.UserIdentity (DatabasePrincipalId, UserObjectId, UserPrincipalName)
VALUES (DATABASE_PRINCIPAL_ID('rls_bench_user'), @benchOid, N'bench@test.local');

INSERT INTO Security.GroupMembership (UserObjectId, GroupObjectId)
SELECT TOP (@MembershipCount) @benchOid, EntraIdWrite
FROM dbo.ProjectAccess
ORDER BY ProjectId;
GO

DECLARE @benchOid UNIQUEIDENTIFIER = '33333333-3333-3333-3333-333333333333';
DECLARE @lines INT, @projects INT, @members INT;

SELECT @lines    = COUNT(*) FROM dbo.DocumentLine;
SELECT @projects = COUNT(*) FROM dbo.ProjectAccess;
SELECT @members  = COUNT(*) FROM Security.GroupMembership WHERE UserObjectId = @benchOid;

PRINT '============================================================';
PRINT 'Predicate benchmark';
PRINT '============================================================';
PRINT CONCAT('Lines in table              : ', @lines);
PRINT CONCAT('Projects                    : ', @projects);
PRINT CONCAT('Groups this user belongs to : ', @members);
PRINT '';
GO

SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO

PRINT '--- Write: single insert into a permitted project -----------';
GO
DECLARE @p BIGINT = (SELECT TOP 1 pa.ProjectId
                     FROM dbo.ProjectAccess pa
                     JOIN Security.GroupMembership gm ON gm.GroupObjectId = pa.EntraIdWrite
                     WHERE gm.UserObjectId = '33333333-3333-3333-3333-333333333333'
                     ORDER BY pa.ProjectId);
EXECUTE AS USER = 'rls_bench_user';
INSERT INTO dbo.DocumentLine (DocumentId, ProjectId, Comment)
VALUES (21, @p, N'bench: single insert');
REVERT;
GO

PRINT '--- Read: paged list, the common API call -------------------';
GO
EXECUTE AS USER = 'rls_bench_user';
SELECT TOP (50) DocumentLineId, ProjectId, Comment
FROM dbo.DocumentLine
ORDER BY DocumentLineId;
REVERT;
GO

PRINT '--- Read: single row by primary key -------------------------';
GO
EXECUTE AS USER = 'rls_bench_user';
SELECT DocumentLineId, ProjectId, Comment
FROM dbo.DocumentLine
WHERE DocumentLineId = 1;
REVERT;
GO

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

DELETE FROM dbo.DocumentLine WHERE Comment LIKE N'bench:%';
DECLARE @benchOid UNIQUEIDENTIFIER = '33333333-3333-3333-3333-333333333333';
DELETE FROM Security.GroupMembership WHERE UserObjectId = @benchOid;
DELETE FROM Security.UserIdentity    WHERE UserObjectId = @benchOid;
GO

DROP USER IF EXISTS rls_bench_user;
GO

PRINT 'Benchmark complete.';
GO
