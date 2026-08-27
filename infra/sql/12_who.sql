-- ============================================================================
-- 12_who.sql
--
-- One user, in full: which groups they are in, which projects those groups
-- grant, and a sample of what they cannot reach. The mapping behind the
-- numbers in 08_show_access.sql.
--
-- {{USER}} is substituted by demo.sh. Accepts 'anna' or 'anna@contoso.com'.
-- ============================================================================
SET NOCOUNT ON;
SET ANSI_WARNINGS OFF;

DECLARE @user NVARCHAR(256) = N'{{USER}}';
DECLARE @oid  UNIQUEIDENTIFIER;
DECLARE @name NVARCHAR(256);

SELECT TOP 1
    @oid  = UserObjectId,
    @name = LEFT(UserPrincipalName, CHARINDEX('@', UserPrincipalName + '@') - 1)
FROM Security.UserIdentity
WHERE UserPrincipalName = @user
   OR LEFT(UserPrincipalName, CHARINDEX('@', UserPrincipalName + '@') - 1) = @user;

IF @oid IS NULL
BEGIN
    PRINT '';
    PRINT '  No such user: ' + @user;
    PRINT '  Known users:';
    SELECT LEFT(UserPrincipalName, CHARINDEX('@', UserPrincipalName + '@') - 1) AS [Known users]
    FROM Security.UserIdentity WHERE IsActive = 1 ORDER BY 1;
END
ELSE
BEGIN
    PRINT '';
    PRINT '============================================================';
    PRINT ' ' + @name;
    PRINT '============================================================';
    PRINT '';
    PRINT '--- which groups, and what each one grants ------------------';

    SELECT GroupObjectId, Access, ProjectId, ProjectName, Lines FROM (
        SELECT gm.GroupObjectId, 'WRITE' AS Access, pa.ProjectId, pa.ProjectName,
               (SELECT COUNT(*) FROM dbo.DocumentLine dl WHERE dl.ProjectId = pa.ProjectId) AS Lines
        FROM Security.GroupMembership AS gm
        JOIN dbo.ProjectAccess        AS pa ON pa.EntraIdWrite = gm.GroupObjectId
        WHERE gm.UserObjectId = @oid
        UNION ALL
        SELECT gm.GroupObjectId, 'READ', pa.ProjectId, pa.ProjectName,
               (SELECT COUNT(*) FROM dbo.DocumentLine dl WHERE dl.ProjectId = pa.ProjectId)
        FROM Security.GroupMembership AS gm
        JOIN dbo.ProjectAccess        AS pa ON pa.EntraIdRead = gm.GroupObjectId
        WHERE gm.UserObjectId = @oid
    ) AS x
    ORDER BY ProjectId, Access;

    IF NOT EXISTS (SELECT 1 FROM Security.GroupMembership WHERE UserObjectId = @oid)
        PRINT '  No group memberships at all. Every write is blocked.';

    PRINT '';
    PRINT '--- totals -------------------------------------------------';

    SELECT
        (SELECT COUNT(*) FROM Security.GroupMembership WHERE UserObjectId = @oid) AS [Groups],
        (SELECT COUNT(*) FROM dbo.ProjectAccess pa
          WHERE EXISTS (SELECT 1 FROM Security.GroupMembership gm
                         WHERE gm.UserObjectId = @oid AND gm.GroupObjectId = pa.EntraIdWrite)) AS [Projects writable],
        (SELECT COUNT(*) FROM dbo.ProjectAccess pa
          WHERE EXISTS (SELECT 1 FROM Security.GroupMembership gm
                         WHERE gm.UserObjectId = @oid AND gm.GroupObjectId = pa.EntraIdRead)) AS [Projects readable];

    PRINT '';
    PRINT '--- a sample of projects this user CANNOT write -------------';

    SELECT TOP 5 pa.ProjectId, pa.ProjectName, pa.EntraIdWrite AS [Write group they are not in]
    FROM dbo.ProjectAccess AS pa
    WHERE NOT EXISTS (
        SELECT 1 FROM Security.GroupMembership AS gm
        WHERE gm.UserObjectId = @oid AND gm.GroupObjectId = pa.EntraIdWrite
    )
    ORDER BY CASE WHEN pa.ProjectId IN (12345678, 98765432) THEN 0 ELSE 1 END, pa.ProjectId;

    PRINT '';
    PRINT '  An INSERT naming any project above is refused by the policy.';
    PRINT '';
END
GO
