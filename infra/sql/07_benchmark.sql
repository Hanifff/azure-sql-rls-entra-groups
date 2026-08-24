-- ============================================================================
-- 07_benchmark.sql
-- Measures the RLS predicate at demo scale so the design can be defended with
-- numbers instead of assertions.
--
-- Creates a test principal with a realistic membership count (a few hundred
-- groups, not tens of thousands), then reports logical reads and elapsed time
-- for the queries an application would actually run.
--
-- Cleans up after itself.
-- ============================================================================
SET NOCOUNT ON;

DECLARE @MembershipCount INT = 250;   -- groups this test user belongs to

IF DATABASE_PRINCIPAL_ID('rls_bench_user') IS NOT NULL DROP USER rls_bench_user;
GO

CREATE USER rls_bench_user WITHOUT LOGIN;
ALTER ROLE rls_app_user ADD MEMBER rls_bench_user;
GO

DECLARE @benchOid UNIQUEIDENTIFIER = '33333333-3333-3333-3333-333333333333';
DECLARE @MembershipCount INT = 250;

DELETE FROM Security.GroupMembership WHERE UserObjectId = @benchOid;
DELETE FROM Security.UserIdentity    WHERE UserObjectId = @benchOid;

INSERT INTO Security.UserIdentity (DatabasePrincipalId, UserObjectId, UserPrincipalName)
VALUES (DATABASE_PRINCIPAL_ID('rls_bench_user'), @benchOid, N'bench@test.local');

INSERT INTO Security.GroupMembership (UserObjectId, GroupObjectId)
SELECT TOP (@MembershipCount) @benchOid, ReadGroupId
FROM dbo.Projects
ORDER BY ProjectId;
GO

-- --- context ----------------------------------------------------------------
DECLARE @benchOid UNIQUEIDENTIFIER = '33333333-3333-3333-3333-333333333333';
DECLARE @docs INT, @groups INT, @members INT, @visible INT;

SELECT @docs    = COUNT(*) FROM dbo.Documents;
SELECT @groups  = COUNT(DISTINCT ReadGroupId) FROM dbo.Documents;
SELECT @members = COUNT(*) FROM Security.GroupMembership WHERE UserObjectId = @benchOid;

EXECUTE AS USER = 'rls_bench_user';
    SELECT @visible = COUNT(*) FROM dbo.Documents;
REVERT;

PRINT '============================================================';
PRINT 'RLS predicate benchmark';
PRINT '============================================================';
PRINT CONCAT('Documents in table          : ', @docs);
PRINT CONCAT('Distinct read groups        : ', @groups);
PRINT CONCAT('Groups this user belongs to : ', @members);
PRINT CONCAT('Rows visible to this user   : ', @visible);
PRINT '';
GO

SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO

PRINT '--- Query 1: paged list, the common API call ---------------';
GO
EXECUTE AS USER = 'rls_bench_user';
SELECT TOP (50) DocumentId, ProjectId, Title
FROM dbo.Documents
ORDER BY DocumentId;
REVERT;
GO

PRINT '--- Query 2: single row by primary key ---------------------';
GO
EXECUTE AS USER = 'rls_bench_user';
SELECT DocumentId, ProjectId, Title
FROM dbo.Documents
WHERE DocumentId = 1;
REVERT;
GO

PRINT '--- Query 3: full count across everything visible ----------';
GO
EXECUTE AS USER = 'rls_bench_user';
SELECT COUNT(*) AS VisibleDocuments FROM dbo.Documents;
REVERT;
GO

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-- --- cleanup ----------------------------------------------------------------
DECLARE @benchOid UNIQUEIDENTIFIER = '33333333-3333-3333-3333-333333333333';
DELETE FROM Security.GroupMembership WHERE UserObjectId = @benchOid;
DELETE FROM Security.UserIdentity    WHERE UserObjectId = @benchOid;
GO

DROP USER IF EXISTS rls_bench_user;
GO

PRINT 'Benchmark complete.';
GO
