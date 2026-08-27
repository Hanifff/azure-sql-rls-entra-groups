-- ============================================================================
-- 14_demo_readwrite.sql
--
-- The read plus write story. 11_demo_run.sql covers writes with reads left
-- open, which is the default. This one switches read filtering on and shows
-- both predicates working at once, including the case where they disagree.
--
-- Turns read filtering on at the start and back off at the end, so it leaves
-- the database in the documented default state.
-- ============================================================================
SET NOCOUNT ON;
SET ANSI_WARNINGS OFF;

DECLARE @annaOid UNIQUEIDENTIFIER = '0a0a0a0a-0000-0000-0000-00000000000a';
GO

PRINT '';
PRINT '============================================================';
PRINT ' STEP 1  Bind a read predicate alongside the write ones';
PRINT '============================================================';
GO

IF EXISTS (SELECT 1 FROM sys.security_policies WHERE name = 'ProjectLinePolicy')
    DROP SECURITY POLICY Security.ProjectLinePolicy;

CREATE SECURITY POLICY Security.ProjectLinePolicy
    ADD FILTER PREDICATE Security.fn_can_read_project(ProjectId)  ON dbo.DocumentLine,
    ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine AFTER INSERT,
    ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine BEFORE UPDATE,
    ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine AFTER UPDATE,
    ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine BEFORE DELETE
WITH (STATE = ON, SCHEMABINDING = ON);
GO

SELECT predicate_type_desc AS [Predicate], ISNULL(operation_desc, 'all reads') AS [Operation]
FROM sys.security_predicates AS sp
JOIN sys.security_policies  AS p ON p.object_id = sp.object_id
WHERE p.name = 'ProjectLinePolicy'
ORDER BY predicate_type_desc, operation_desc;

PRINT '  One FILTER for reads, four BLOCK for every write path.';
PRINT '';
GO

PRINT '============================================================';
PRINT ' STEP 2  What each user can see now';
PRINT '============================================================';
GO

DECLARE @total INT, @anna INT, @bjorn INT;
SELECT @total = COUNT(*) FROM dbo.DocumentLine;
EXECUTE AS USER = 'anna';  SELECT @anna  = COUNT(*) FROM dbo.DocumentLine; REVERT;
EXECUTE AS USER = 'bjorn'; SELECT @bjorn = COUNT(*) FROM dbo.DocumentLine; REVERT;

PRINT CONCAT('  rows in the table : ', @total);
PRINT CONCAT('  anna sees         : ', @anna);
PRINT CONCAT('  bjorn sees        : ', @bjorn);
PRINT '';
PRINT '  Same table, same query, no WHERE clause. Anna is in the read group';
PRINT '  for project 12345678. Bjorn is in no groups, so he sees nothing.';
PRINT '';
GO

PRINT '============================================================';
PRINT ' STEP 3  Anna writes to the project she can see';
PRINT '============================================================';
GO

DECLARE @imp BIT = 0, @before INT, @after INT;

EXECUTE AS USER = 'anna'; SELECT @before = COUNT(*) FROM dbo.DocumentLine; REVERT;

BEGIN TRY
    EXECUTE AS USER = 'anna'; SET @imp = 1;
    INSERT INTO dbo.DocumentLine (DocumentId, ProjectId, Comment)
    VALUES (21, 12345678, N'demo:anna can read and write here');
    SELECT @after = COUNT(*) FROM dbo.DocumentLine;
    REVERT; SET @imp = 0;

    PRINT CONCAT('  rows visible to anna: before ', @before, ', after ', @after, '.');
    PRINT '  Allowed. She is in the write group, and in the read group, so the';
    PRINT '  row she just created is visible to her.';
END TRY
BEGIN CATCH
    IF @imp = 1 BEGIN REVERT; SET @imp = 0; END
    PRINT '  Unexpected: the insert was blocked.';
END CATCH
PRINT '';
GO

PRINT '============================================================';
PRINT ' STEP 4  Anna tries a project she can neither read nor write';
PRINT '============================================================';
GO

DECLARE @imp BIT = 0;
BEGIN TRY
    EXECUTE AS USER = 'anna'; SET @imp = 1;
    INSERT INTO dbo.DocumentLine (DocumentId, ProjectId, Comment)
    VALUES (42, 98765432, N'demo:should not land');
    REVERT; SET @imp = 0;
    PRINT '  Unexpected: that should have been blocked.';
END TRY
BEGIN CATCH
    IF @imp = 1 BEGIN REVERT; SET @imp = 0; END
    PRINT '  Blocked. She is in neither group for project 98765432.';
    PRINT '  Both predicates agree here, so there is nothing surprising yet.';
END CATCH
PRINT '';
GO

PRINT '============================================================';
PRINT ' STEP 5  Write access without read access';
PRINT '============================================================';
GO

DECLARE @annaOid UNIQUEIDENTIFIER = '0a0a0a0a-0000-0000-0000-00000000000a';
DECLARE @p2Write UNIQUEIDENTIFIER = (SELECT EntraIdWrite FROM dbo.ProjectAccess WHERE ProjectId = 98765432);
DECLARE @imp BIT = 0, @seen INT, @actually INT;

-- Write group only. Deliberately not the read group.
INSERT INTO Security.GroupMembership (UserObjectId, GroupObjectId) VALUES (@annaOid, @p2Write);

PRINT '  Added anna to the WRITE group of project 98765432, and not the read';
PRINT '  group. The two predicates now disagree about that project.';
PRINT '';

BEGIN TRY
    EXECUTE AS USER = 'anna'; SET @imp = 1;
    INSERT INTO dbo.DocumentLine (DocumentId, ProjectId, Comment)
    VALUES (42, 98765432, N'demo:written but not visible to anna');
    SELECT @seen = COUNT(*) FROM dbo.DocumentLine WHERE ProjectId = 98765432;
    REVERT; SET @imp = 0;

    SELECT @actually = COUNT(*) FROM dbo.DocumentLine WHERE ProjectId = 98765432;

    PRINT '  The insert succeeded. Then, in the same session:';
    PRINT CONCAT('    rows anna can see in project 98765432 : ', @seen);
    PRINT CONCAT('    rows actually there                   : ', @actually);
    PRINT '';
    PRINT '  She wrote a row she cannot read back. FILTER governs reads, BLOCK';
    PRINT '  governs writes, and nothing requires them to agree. If that is not';
    PRINT '  the behaviour you want, both groups have to be granted together.';
END TRY
BEGIN CATCH
    IF @imp = 1 BEGIN REVERT; SET @imp = 0; END
    PRINT '  Unexpected: the insert was blocked.';
END CATCH
PRINT '';
GO

PRINT '============================================================';
PRINT ' STEP 6  Bjorn, for contrast';
PRINT '============================================================';
GO

DECLARE @imp BIT = 0, @bjorn INT;
EXECUTE AS USER = 'bjorn'; SELECT @bjorn = COUNT(*) FROM dbo.DocumentLine; REVERT;

BEGIN TRY
    EXECUTE AS USER = 'bjorn'; SET @imp = 1;
    INSERT INTO dbo.DocumentLine (DocumentId, ProjectId, Comment)
    VALUES (21, 12345678, N'demo:bjorn should not land');
    REVERT; SET @imp = 0;
    PRINT '  Unexpected: that should have been blocked.';
END TRY
BEGIN CATCH
    IF @imp = 1 BEGIN REVERT; SET @imp = 0; END
    PRINT CONCAT('  bjorn sees ', @bjorn, ' rows and cannot write anywhere.');
    PRINT '  No membership rows at all. Nothing was configured for him';
    PRINT '  specifically, and nothing needed to be.';
END CATCH
PRINT '';
GO

PRINT '============================================================';
PRINT ' STEP 7  Put everything back';
PRINT '============================================================';
GO

DECLARE @annaOid UNIQUEIDENTIFIER = '0a0a0a0a-0000-0000-0000-00000000000a';
DECLARE @p2Write UNIQUEIDENTIFIER = (SELECT EntraIdWrite FROM dbo.ProjectAccess WHERE ProjectId = 98765432);

DELETE FROM Security.GroupMembership WHERE UserObjectId = @annaOid AND GroupObjectId = @p2Write;
DELETE FROM dbo.DocumentLine WHERE Comment LIKE N'demo:%';

IF EXISTS (SELECT 1 FROM sys.security_policies WHERE name = 'ProjectLinePolicy')
    DROP SECURITY POLICY Security.ProjectLinePolicy;

CREATE SECURITY POLICY Security.ProjectLinePolicy
    ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine AFTER INSERT,
    ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine BEFORE UPDATE,
    ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine AFTER UPDATE,
    ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine BEFORE DELETE
WITH (STATE = ON, SCHEMABINDING = ON);

PRINT '  Temporary membership removed, demo rows deleted, read filtering off.';
PRINT '  Back to the default: writes restricted, reads open.';
PRINT '';
GO
