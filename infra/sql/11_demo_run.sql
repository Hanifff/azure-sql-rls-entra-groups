-- ============================================================================
-- 16_project_model_demo_run.sql
--
-- The demo, as one narrated script. Run it after 15_..._demo_setup.sql.
--
-- Each step prints what it is about to do and what happened, so it can be run
-- top to bottom while talking, or a section at a time by highlighting it.
--
-- Nothing here is destructive: the rows it creates are cleaned up at the end.
-- ============================================================================
SET NOCOUNT ON;

PRINT '============================================================';
PRINT ' STEP 1  The model';
PRINT '============================================================';
GO

SELECT TOP 2 ProjectId, ProjectName, EntraIdWrite AS [Write group], EntraIdRead AS [Read group]
FROM dbo.ProjectAccess
WHERE ProjectId IN (12345678, 98765432);

SELECT TOP 2 DocumentLineId, DocumentId, ProjectId, Comment
FROM dbo.DocumentLine
WHERE ProjectId IN (12345678, 98765432)
ORDER BY DocumentLineId;
GO

PRINT '';
PRINT 'ProjectAccess comes from the IAM sync and already exists.';
PRINT 'DocumentLine rows carry a ProjectId, not a group.';
PRINT '';
GO

PRINT '============================================================';
PRINT ' STEP 2  Reads are open to everyone';
PRINT '============================================================';
GO

DECLARE @total INT, @anna INT, @bjorn INT;
SELECT @total = COUNT(*) FROM dbo.DocumentLine;
EXECUTE AS USER = 'anna';  SELECT @anna  = COUNT(*) FROM dbo.DocumentLine; REVERT;
EXECUTE AS USER = 'bjorn'; SELECT @bjorn = COUNT(*) FROM dbo.DocumentLine; REVERT;

PRINT CONCAT('  total lines : ', @total);
PRINT CONCAT('  anna sees   : ', @anna);
PRINT CONCAT('  bjorn sees  : ', @bjorn);
PRINT '';
PRINT '  Read is handled by RBAC on the table, so no FILTER predicate.';
PRINT '';
GO

PRINT '============================================================';
PRINT ' STEP 3  Anna writes to the project she is a member of';
PRINT '============================================================';
GO

BEGIN TRY
    EXECUTE AS USER = 'anna';
    INSERT INTO dbo.DocumentLine (DocumentId, ProjectId, Comment)
    VALUES (21, 12345678, N'demo: written by anna');
    REVERT;
    PRINT '  OK. Anna is in the write group for 12345678, so the insert succeeded.';
END TRY
BEGIN CATCH
    IF USER_NAME() <> 'dbo' REVERT;
    PRINT CONCAT('  UNEXPECTED: ', ERROR_MESSAGE());
END CATCH
PRINT '';
GO

PRINT '============================================================';
PRINT ' STEP 4  Bjorn tries the same insert';
PRINT '============================================================';
GO

BEGIN TRY
    EXECUTE AS USER = 'bjorn';
    INSERT INTO dbo.DocumentLine (DocumentId, ProjectId, Comment)
    VALUES (21, 12345678, N'demo: written by bjorn');
    REVERT;
    PRINT '  UNEXPECTED: bjorn was allowed to write.';
END TRY
BEGIN CATCH
    IF USER_NAME() <> 'dbo' REVERT;
    PRINT '  Blocked, as intended. Bjorn is not in the write group.';
    PRINT CONCAT('  SQL says: ', LEFT(ERROR_MESSAGE(), 120));
END CATCH
PRINT '';
GO

PRINT '============================================================';
PRINT ' STEP 5  Anna tries a project she is NOT a member of';
PRINT '============================================================';
GO

BEGIN TRY
    EXECUTE AS USER = 'anna';
    INSERT INTO dbo.DocumentLine (DocumentId, ProjectId, Comment)
    VALUES (42, 98765432, N'demo: anna into the wrong project');
    REVERT;
    PRINT '  UNEXPECTED: write access leaked across projects.';
END TRY
BEGIN CATCH
    IF USER_NAME() <> 'dbo' REVERT;
    PRINT '  Blocked. Access to one project does not grant access to another.';
END CATCH
PRINT '';
GO

PRINT '============================================================';
PRINT ' STEP 6  Anna tries to move her own row into that project';
PRINT '============================================================';
GO

DECLARE @row INT = (SELECT MIN(DocumentLineId) FROM dbo.DocumentLine WHERE ProjectId = 12345678);

BEGIN TRY
    EXECUTE AS USER = 'anna';
    UPDATE dbo.DocumentLine SET ProjectId = 98765432 WHERE DocumentLineId = @row;
    REVERT;
    PRINT '  UNEXPECTED: the row was moved.';
END TRY
BEGIN CATCH
    IF USER_NAME() <> 'dbo' REVERT;
    PRINT '  Blocked. This is why BEFORE UPDATE and AFTER UPDATE are both needed.';
    PRINT '  A FILTER predicate alone would not catch this.';
END CATCH
PRINT '';
GO

PRINT '============================================================';
PRINT ' STEP 7  Remove Anna from the group. One row.';
PRINT '============================================================';
GO

DECLARE @annaOid UNIQUEIDENTIFIER = '0a0a0a0a-0000-0000-0000-00000000000a';
DELETE FROM Security.GroupMembership WHERE UserObjectId = @annaOid;
PRINT '  DELETE FROM Security.GroupMembership WHERE UserObjectId = anna';
PRINT '';

BEGIN TRY
    EXECUTE AS USER = 'anna';
    INSERT INTO dbo.DocumentLine (DocumentId, ProjectId, Comment)
    VALUES (21, 12345678, N'demo: anna after revocation');
    REVERT;
    PRINT '  UNEXPECTED: anna could still write.';
END TRY
BEGIN CATCH
    IF USER_NAME() <> 'dbo' REVERT;
    PRINT '  Blocked immediately, on the next statement. No reconnect, no cache flush.';
    PRINT '  This is what the sync job does when someone leaves a group in Entra.';
END CATCH
PRINT '';
GO

PRINT '============================================================';
PRINT ' STEP 8  Put it back and clean up';
PRINT '============================================================';
GO

DECLARE @annaOid UNIQUEIDENTIFIER = '0a0a0a0a-0000-0000-0000-00000000000a';
DECLARE @p1Write UNIQUEIDENTIFIER = (SELECT EntraIdWrite FROM dbo.ProjectAccess WHERE ProjectId = 12345678);

IF NOT EXISTS (SELECT 1 FROM Security.GroupMembership WHERE UserObjectId = @annaOid)
    INSERT INTO Security.GroupMembership (UserObjectId, GroupObjectId) VALUES (@annaOid, @p1Write);

DELETE FROM dbo.DocumentLine WHERE Comment LIKE N'demo:%';

PRINT '  Anna restored, demo rows removed. Safe to run again.';
PRINT '';
GO
