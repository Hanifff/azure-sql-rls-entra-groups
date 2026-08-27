-- ============================================================================
-- 10_demo_setup.sql
--
-- Puts the database into a known state for a live demo, and creates two named
-- users so the story is easy to follow:
--
--   anna   in the write group of project 12345678 only
--   bjorn  in no write groups at all
--
-- Both are WITHOUT LOGIN principals, so nothing in Entra is touched and the
-- demo works the same in any tenant.
--
-- Run 11_demo_run.sql afterwards to walk through the story.
-- Safe to re-run: it resets everything first.
-- ============================================================================
SET NOCOUNT ON;

IF DATABASE_PRINCIPAL_ID('anna')  IS NOT NULL DROP USER anna;
IF DATABASE_PRINCIPAL_ID('bjorn') IS NOT NULL DROP USER bjorn;
GO

CREATE USER anna  WITHOUT LOGIN;
CREATE USER bjorn WITHOUT LOGIN;
ALTER ROLE rls_app_user ADD MEMBER anna;
ALTER ROLE rls_app_user ADD MEMBER bjorn;
GO

DECLARE @annaOid  UNIQUEIDENTIFIER = '0a0a0a0a-0000-0000-0000-00000000000a';
DECLARE @bjornOid UNIQUEIDENTIFIER = '0b0b0b0b-0000-0000-0000-00000000000b';
DECLARE @p1Write  UNIQUEIDENTIFIER = (SELECT EntraIdWrite FROM dbo.ProjectAccess WHERE ProjectId = 12345678);
DECLARE @p1Read   UNIQUEIDENTIFIER = (SELECT EntraIdRead  FROM dbo.ProjectAccess WHERE ProjectId = 12345678);

DELETE FROM Security.GroupMembership WHERE UserObjectId IN (@annaOid, @bjornOid);
DELETE FROM Security.UserIdentity    WHERE UserObjectId IN (@annaOid, @bjornOid);

INSERT INTO Security.UserIdentity (DatabasePrincipalId, UserObjectId, UserPrincipalName) VALUES
    (DATABASE_PRINCIPAL_ID('anna'),  @annaOid,  N'anna@contoso.com'),
    (DATABASE_PRINCIPAL_ID('bjorn'), @bjornOid, N'bjorn@contoso.com');

-- These two rows are the entire difference between the two users. The read row
-- is inert until read filtering is switched on with 09_toggle_read.sql; without
-- it, enabling read filtering would show anna zero rows rather than her project.
INSERT INTO Security.GroupMembership (UserObjectId, GroupObjectId) VALUES
    (@annaOid, @p1Write),
    (@annaOid, @p1Read);

-- Remove anything left behind by an earlier demo run.
DELETE FROM dbo.DocumentLine WHERE Comment LIKE N'demo:%';
GO

PRINT '';
PRINT 'Demo ready.';
PRINT '';

SELECT
    ui.UserPrincipalName                 AS [User],
    COUNT(gm.GroupObjectId)              AS [Group rows],
    CASE WHEN COUNT(gm.GroupObjectId) = 0
         THEN N'writes nothing, sees nothing if read filtering is on'
         ELSE N'writes project 12345678, sees only it if read filtering is on'
    END                                  AS [Expected]
FROM Security.UserIdentity AS ui
LEFT JOIN Security.GroupMembership AS gm ON gm.UserObjectId = ui.UserObjectId
WHERE ui.UserPrincipalName IN (N'anna@contoso.com', N'bjorn@contoso.com')
GROUP BY ui.UserPrincipalName;
GO
