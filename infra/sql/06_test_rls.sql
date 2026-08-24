-- ============================================================================
-- 06_test_rls.sql
-- Proves the RLS policy enforces what it claims, using throwaway WITHOUT LOGIN
-- users and EXECUTE AS. No Entra objects and no tokens are involved, so this
-- runs deterministically on every deploy.
--
-- Asserts:
--   1. a user sees only rows whose ReadGroupId they are a member of
--   2. a user with no memberships sees nothing
--   3. read access does not imply write access (BLOCK predicate)
--   4. the app role cannot read the entitlement tables directly
--   5. removing a membership revokes access on the next query
--
-- Cleans up after itself and raises an error if any assertion fails.
-- ============================================================================
SET NOCOUNT ON;

-- --- fixture principals -----------------------------------------------------
IF DATABASE_PRINCIPAL_ID('rls_test_alice') IS NOT NULL DROP USER rls_test_alice;
IF DATABASE_PRINCIPAL_ID('rls_test_bob')   IS NOT NULL DROP USER rls_test_bob;
GO

CREATE USER rls_test_alice WITHOUT LOGIN;
CREATE USER rls_test_bob   WITHOUT LOGIN;
ALTER ROLE rls_app_user ADD MEMBER rls_test_alice;
ALTER ROLE rls_app_user ADD MEMBER rls_test_bob;
GO

-- --- fixture entitlements ---------------------------------------------------
DECLARE @aliceOid UNIQUEIDENTIFIER = '11111111-1111-1111-1111-111111111111';
DECLARE @bobOid   UNIQUEIDENTIFIER = '22222222-2222-2222-2222-222222222222';
DECLARE @p1Read   UNIQUEIDENTIFIER = (SELECT ReadGroupId FROM dbo.Projects WHERE ProjectId = 1);

DELETE FROM Security.GroupMembership WHERE UserObjectId IN (@aliceOid, @bobOid);
DELETE FROM Security.UserIdentity    WHERE UserObjectId IN (@aliceOid, @bobOid);

-- Alice may READ project 1. Deliberately not a member of its write group.
INSERT INTO Security.UserIdentity (DatabasePrincipalId, UserObjectId, UserPrincipalName)
VALUES (DATABASE_PRINCIPAL_ID('rls_test_alice'), @aliceOid, N'alice@test.local');
INSERT INTO Security.GroupMembership (UserObjectId, GroupObjectId)
VALUES (@aliceOid, @p1Read);

-- Bob is registered but a member of nothing.
INSERT INTO Security.UserIdentity (DatabasePrincipalId, UserObjectId, UserPrincipalName)
VALUES (DATABASE_PRINCIPAL_ID('rls_test_bob'), @bobOid, N'bob@test.local');
GO

-- --- assertions -------------------------------------------------------------
DECLARE @failures      INT = 0;
DECLARE @seen          INT;
DECLARE @expected      INT;
DECLARE @total         INT;
DECLARE @targetId      INT;
DECLARE @blocked       BIT = 0;
DECLARE @denied        BIT = 0;
DECLARE @impersonating BIT = 0;
DECLARE @aliceOid      UNIQUEIDENTIFIER = '11111111-1111-1111-1111-111111111111';
DECLARE @bobOid        UNIQUEIDENTIFIER = '22222222-2222-2222-2222-222222222222';

SELECT @expected = COUNT(*) FROM dbo.Documents WHERE ProjectId = 1;
SELECT @total    = COUNT(*) FROM dbo.Documents;
SELECT @targetId = MIN(DocumentId) FROM dbo.Documents WHERE ProjectId = 1;

PRINT CONCAT('Fixture: ', @total, ' documents total, ', @expected, ' in project 1.');
PRINT '';

-- 1. Alice sees exactly her group's rows -------------------------------------
EXECUTE AS USER = 'rls_test_alice';
    SELECT @seen = COUNT(*) FROM dbo.Documents;
REVERT;

IF @seen = @expected
    PRINT CONCAT('PASS  1. Alice sees ', @seen, ' of ', @total, ' rows (only her group).');
ELSE
BEGIN
    SET @failures += 1;
    PRINT CONCAT('FAIL  1. Alice saw ', @seen, ' rows, expected ', @expected, '.');
END

-- 2. A user with no memberships sees nothing ---------------------------------
EXECUTE AS USER = 'rls_test_bob';
    SELECT @seen = COUNT(*) FROM dbo.Documents;
REVERT;

IF @seen = 0
    PRINT 'PASS  2. Bob has no memberships and sees 0 rows.';
ELSE
BEGIN
    SET @failures += 1;
    PRINT CONCAT('FAIL  2. Bob saw ', @seen, ' rows, expected 0.');
END

-- 3. Read access does not grant write access ---------------------------------
BEGIN TRY
    EXECUTE AS USER = 'rls_test_alice';
    SET @impersonating = 1;
    UPDATE dbo.Documents SET Title = N'tampered' WHERE DocumentId = @targetId;
    REVERT;
    SET @impersonating = 0;
END TRY
BEGIN CATCH
    IF @impersonating = 1
    BEGIN
        REVERT;
        SET @impersonating = 0;
    END
    SET @blocked = 1;
END CATCH

IF @blocked = 1
    PRINT 'PASS  3. BLOCK predicate stopped a write on a read-only row.';
ELSE
BEGIN
    SET @failures += 1;
    PRINT 'FAIL  3. Alice updated a row she should only be able to read.';
    UPDATE dbo.Documents SET Title = CONCAT(N'Document ', DocumentId) WHERE DocumentId = @targetId;
END

-- 4. The app role cannot read the entitlement tables directly -----------------
BEGIN TRY
    EXECUTE AS USER = 'rls_test_alice';
    SET @impersonating = 1;
    SELECT @seen = COUNT(*) FROM Security.GroupMembership;
    REVERT;
    SET @impersonating = 0;
END TRY
BEGIN CATCH
    IF @impersonating = 1
    BEGIN
        REVERT;
        SET @impersonating = 0;
    END
    SET @denied = 1;
END CATCH

IF @denied = 1
    PRINT 'PASS  4. Security schema is not directly readable by the app role.';
ELSE
BEGIN
    SET @failures += 1;
    PRINT 'FAIL  4. App role read Security.GroupMembership directly.';
END

-- 5. Removing the membership revokes access ----------------------------------
DELETE FROM Security.GroupMembership WHERE UserObjectId = @aliceOid;

EXECUTE AS USER = 'rls_test_alice';
    SELECT @seen = COUNT(*) FROM dbo.Documents;
REVERT;

IF @seen = 0
    PRINT 'PASS  5. Deleting the membership revoked access immediately.';
ELSE
BEGIN
    SET @failures += 1;
    PRINT CONCAT('FAIL  5. Alice still saw ', @seen, ' rows after removal.');
END

-- --- cleanup ----------------------------------------------------------------
DELETE FROM Security.GroupMembership WHERE UserObjectId IN (@aliceOid, @bobOid);
DELETE FROM Security.UserIdentity    WHERE UserObjectId IN (@aliceOid, @bobOid);

PRINT '';
IF @failures > 0
BEGIN
    DECLARE @msg NVARCHAR(200) = CONCAT('RLS TESTS FAILED: ', @failures, ' assertion(s).');
    RAISERROR(@msg, 16, 1);
END
ELSE
    PRINT 'RLS TESTS PASSED: 5 of 5 assertions green.';
GO

DROP USER IF EXISTS rls_test_alice;
DROP USER IF EXISTS rls_test_bob;
GO
