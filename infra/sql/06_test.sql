-- ============================================================================
-- 06_test.sql
--
-- Proves the write check works, using throwaway WITHOUT LOGIN users so it runs
-- deterministically on every deploy without needing real Entra accounts.
--
-- Asserts:
--   1. everyone can read every line          (reads are open by default)
--   2. a member of the write group can insert into that project
--   3. a non-member cannot insert into that project
--   4. a member of one project cannot insert into another
--   5. a user cannot move an existing line into a project they cannot write
--   6. the app role cannot read the entitlement tables directly
--   7. removing the membership revokes write access immediately
--
-- Cleans up after itself and raises an error if any assertion fails.
-- ============================================================================
SET NOCOUNT ON;

IF DATABASE_PRINCIPAL_ID('proj_test_writer')  IS NOT NULL DROP USER proj_test_writer;
IF DATABASE_PRINCIPAL_ID('proj_test_reader')  IS NOT NULL DROP USER proj_test_reader;
GO

CREATE USER proj_test_writer WITHOUT LOGIN;
CREATE USER proj_test_reader WITHOUT LOGIN;
ALTER ROLE rls_app_user ADD MEMBER proj_test_writer;
ALTER ROLE rls_app_user ADD MEMBER proj_test_reader;
GO

DECLARE @writerOid UNIQUEIDENTIFIER = '44444444-4444-4444-4444-444444444444';
DECLARE @readerOid UNIQUEIDENTIFIER = '55555555-5555-5555-5555-555555555555';
DECLARE @p1Write   UNIQUEIDENTIFIER = (SELECT EntraIdWrite FROM dbo.ProjectAccess WHERE ProjectId = 12345678);

DELETE FROM Security.GroupMembership WHERE UserObjectId IN (@writerOid, @readerOid);
DELETE FROM Security.UserIdentity    WHERE UserObjectId IN (@writerOid, @readerOid);

-- Writer is in the write group of project 12345678 only.
INSERT INTO Security.UserIdentity (DatabasePrincipalId, UserObjectId, UserPrincipalName)
VALUES (DATABASE_PRINCIPAL_ID('proj_test_writer'), @writerOid, N'writer@test.local');
INSERT INTO Security.GroupMembership (UserObjectId, GroupObjectId) VALUES (@writerOid, @p1Write);

-- Reader is in nothing.
INSERT INTO Security.UserIdentity (DatabasePrincipalId, UserObjectId, UserPrincipalName)
VALUES (DATABASE_PRINCIPAL_ID('proj_test_reader'), @readerOid, N'reader@test.local');
GO

DECLARE @failures INT = 0;
DECLARE @seen INT, @total INT;
DECLARE @blocked BIT, @impersonating BIT = 0;
DECLARE @writerOid UNIQUEIDENTIFIER = '44444444-4444-4444-4444-444444444444';
DECLARE @readerOid UNIQUEIDENTIFIER = '55555555-5555-5555-5555-555555555555';

SELECT @total = COUNT(*) FROM dbo.DocumentLine;
PRINT CONCAT('Fixture: ', @total, ' lines total.');
PRINT '';

-- === 1. reads are open to everyone =========================================
EXECUTE AS USER = 'proj_test_reader';
    SELECT @seen = COUNT(*) FROM dbo.DocumentLine;
REVERT;

IF @seen = @total
    PRINT CONCAT('PASS  1. A user in no groups still reads all ', @seen, ' lines.');
ELSE
BEGIN
    SET @failures += 1;
    PRINT CONCAT('FAIL  1. Reader saw ', @seen, ' of ', @total, ' lines, expected all.');
END

-- === 2. a write-group member can insert ====================================
SET @blocked = 0;
BEGIN TRY
    EXECUTE AS USER = 'proj_test_writer';
    SET @impersonating = 1;
    INSERT INTO dbo.DocumentLine (DocumentId, ProjectId, Comment)
    VALUES (21, 12345678, N'written by the test writer');
    REVERT;
    SET @impersonating = 0;
END TRY
BEGIN CATCH
    IF @impersonating = 1 BEGIN REVERT; SET @impersonating = 0; END
    SET @blocked = 1;
END CATCH

IF @blocked = 0
    PRINT 'PASS  2. Member of the write group inserted into project 12345678.';
ELSE
BEGIN
    SET @failures += 1;
    PRINT 'FAIL  2. Member of the write group was blocked from its own project.';
END

-- === 3. a non-member cannot insert =========================================
SET @blocked = 0;
BEGIN TRY
    EXECUTE AS USER = 'proj_test_reader';
    SET @impersonating = 1;
    INSERT INTO dbo.DocumentLine (DocumentId, ProjectId, Comment)
    VALUES (21, 12345678, N'should never land');
    REVERT;
    SET @impersonating = 0;
END TRY
BEGIN CATCH
    IF @impersonating = 1 BEGIN REVERT; SET @impersonating = 0; END
    SET @blocked = 1;
END CATCH

IF @blocked = 1
    PRINT 'PASS  3. A user outside the write group was blocked from inserting.';
ELSE
BEGIN
    SET @failures += 1;
    PRINT 'FAIL  3. A non-member inserted a row.';
    DELETE FROM dbo.DocumentLine WHERE Comment = N'should never land';
END

-- === 4. write access does not leak across projects ==========================
SET @blocked = 0;
BEGIN TRY
    EXECUTE AS USER = 'proj_test_writer';
    SET @impersonating = 1;
    INSERT INTO dbo.DocumentLine (DocumentId, ProjectId, Comment)
    VALUES (42, 98765432, N'wrong project');
    REVERT;
    SET @impersonating = 0;
END TRY
BEGIN CATCH
    IF @impersonating = 1 BEGIN REVERT; SET @impersonating = 0; END
    SET @blocked = 1;
END CATCH

IF @blocked = 1
    PRINT 'PASS  4. Write access to one project did not grant it on another.';
ELSE
BEGIN
    SET @failures += 1;
    PRINT 'FAIL  4. Writer inserted into a project they do not control.';
    DELETE FROM dbo.DocumentLine WHERE Comment = N'wrong project';
END

-- === 5. a row cannot be moved into an uncontrolled project ==================
DECLARE @ownRow INT = (SELECT MIN(DocumentLineId) FROM dbo.DocumentLine WHERE ProjectId = 12345678);
SET @blocked = 0;
BEGIN TRY
    EXECUTE AS USER = 'proj_test_writer';
    SET @impersonating = 1;
    UPDATE dbo.DocumentLine SET ProjectId = 98765432 WHERE DocumentLineId = @ownRow;
    REVERT;
    SET @impersonating = 0;
END TRY
BEGIN CATCH
    IF @impersonating = 1 BEGIN REVERT; SET @impersonating = 0; END
    SET @blocked = 1;
END CATCH

IF @blocked = 1
    PRINT 'PASS  5. A row could not be moved into a project the user cannot write.';
ELSE
BEGIN
    SET @failures += 1;
    PRINT 'FAIL  5. Writer moved a row into another project.';
    UPDATE dbo.DocumentLine SET ProjectId = 12345678 WHERE DocumentLineId = @ownRow;
END

-- === 6. entitlement tables are not directly readable ========================
DECLARE @denied BIT = 0;
BEGIN TRY
    EXECUTE AS USER = 'proj_test_writer';
    SET @impersonating = 1;
    SELECT @seen = COUNT(*) FROM Security.GroupMembership;
    REVERT;
    SET @impersonating = 0;
END TRY
BEGIN CATCH
    IF @impersonating = 1 BEGIN REVERT; SET @impersonating = 0; END
    SET @denied = 1;
END CATCH

IF @denied = 1
    PRINT 'PASS  6. Security schema is not directly readable by the app role.';
ELSE
BEGIN
    SET @failures += 1;
    PRINT 'FAIL  6. App role read Security.GroupMembership directly.';
END

-- === 7. removing the membership revokes write immediately ===================
DELETE FROM Security.GroupMembership WHERE UserObjectId = @writerOid;

SET @blocked = 0;
BEGIN TRY
    EXECUTE AS USER = 'proj_test_writer';
    SET @impersonating = 1;
    INSERT INTO dbo.DocumentLine (DocumentId, ProjectId, Comment)
    VALUES (21, 12345678, N'after revocation');
    REVERT;
    SET @impersonating = 0;
END TRY
BEGIN CATCH
    IF @impersonating = 1 BEGIN REVERT; SET @impersonating = 0; END
    SET @blocked = 1;
END CATCH

IF @blocked = 1
    PRINT 'PASS  7. Deleting the membership row revoked write on the next statement.';
ELSE
BEGIN
    SET @failures += 1;
    PRINT 'FAIL  7. Writer still inserted after the membership was removed.';
    DELETE FROM dbo.DocumentLine WHERE Comment = N'after revocation';
END

-- --- cleanup ----------------------------------------------------------------
DELETE FROM dbo.DocumentLine WHERE Comment IN
    (N'written by the test writer', N'should never land', N'wrong project', N'after revocation');
DELETE FROM Security.GroupMembership WHERE UserObjectId IN (@writerOid, @readerOid);
DELETE FROM Security.UserIdentity    WHERE UserObjectId IN (@writerOid, @readerOid);

PRINT '';
IF @failures > 0
BEGIN
    DECLARE @msg NVARCHAR(200) = CONCAT('PROJECT MODEL TESTS FAILED: ', @failures, ' assertion(s).');
    RAISERROR(@msg, 16, 1);
END
ELSE
    PRINT 'PROJECT MODEL TESTS PASSED: 7 of 7 assertions green.';
GO

DROP USER IF EXISTS proj_test_writer;
DROP USER IF EXISTS proj_test_reader;
GO
