-- ============================================================================
-- 08_show_access.sql
--
-- Who can do what, and why. Reads the entitlement tables directly rather than
-- impersonating, so the numbers are the same whether or not read filtering is
-- currently switched on.
--
-- Usernames are shown without their domain, so nothing tenant-specific appears
-- on a shared screen.
-- ============================================================================
SET NOCOUNT ON;
-- LEFT JOINs against users with no groups produce nulls the aggregates ignore.
SET ANSI_WARNINGS OFF;

PRINT '';
PRINT '=== Entitlement: what each user is allowed to reach ========';
PRINT '';

SELECT
    LEFT(ui.UserPrincipalName, CHARINDEX('@', ui.UserPrincipalName + '@') - 1) AS [User],
    COUNT(DISTINCT gm.GroupObjectId) AS [Groups],
    COUNT(DISTINCT paw.ProjectId)    AS [Projects writable],
    COUNT(DISTINCT par.ProjectId)    AS [Projects readable]
FROM Security.UserIdentity AS ui
LEFT JOIN Security.GroupMembership AS gm  ON gm.UserObjectId  = ui.UserObjectId
LEFT JOIN dbo.ProjectAccess        AS paw ON paw.EntraIdWrite = gm.GroupObjectId
LEFT JOIN dbo.ProjectAccess        AS par ON par.EntraIdRead  = gm.GroupObjectId
WHERE ui.IsActive = 1
GROUP BY ui.UserPrincipalName
ORDER BY [Groups] DESC;
GO

PRINT '';
PRINT '=== Rows each user may write ===============================';
PRINT '';

SELECT
    LEFT(ui.UserPrincipalName, CHARINDEX('@', ui.UserPrincipalName + '@') - 1) AS [User],
    COUNT(dl.DocumentLineId) AS [Lines writable]
FROM Security.UserIdentity AS ui
LEFT JOIN Security.GroupMembership AS gm ON gm.UserObjectId = ui.UserObjectId
LEFT JOIN dbo.ProjectAccess        AS pa ON pa.EntraIdWrite = gm.GroupObjectId
LEFT JOIN dbo.DocumentLine         AS dl ON dl.ProjectId    = pa.ProjectId
WHERE ui.IsActive = 1
GROUP BY ui.UserPrincipalName
ORDER BY [Lines writable] DESC;
GO

-- ----------------------------------------------------------------------------
-- What the two demo users actually see right now. This one does depend on the
-- read filtering setting, which is the point of showing it.
-- ----------------------------------------------------------------------------
PRINT '';
PRINT '=== What anna and bjorn see right now ======================';
PRINT '';

DECLARE @total INT, @anna INT, @bjorn INT, @readFiltered BIT;

SELECT @total = COUNT(*) FROM dbo.DocumentLine;
EXECUTE AS USER = 'anna';  SELECT @anna  = COUNT(*) FROM dbo.DocumentLine; REVERT;
EXECUTE AS USER = 'bjorn'; SELECT @bjorn = COUNT(*) FROM dbo.DocumentLine; REVERT;

SELECT @readFiltered = CASE WHEN EXISTS (
    SELECT 1 FROM sys.security_predicates AS sp
    JOIN sys.security_policies AS p ON p.object_id = sp.object_id
    WHERE p.name = 'ProjectLinePolicy' AND sp.predicate_type_desc = 'FILTER'
) THEN 1 ELSE 0 END;

SELECT
    CASE WHEN @readFiltered = 1 THEN 'ON' ELSE 'OFF (reads handled by table permissions)' END AS [Read filtering],
    @total AS [Rows in table],
    @anna  AS [anna sees],
    @bjorn AS [bjorn sees];

IF @readFiltered = 0
    PRINT '  Reads are open, so both see everything. Writes are still restricted.';
ELSE
    PRINT '  Reads are filtered, so each user sees only projects they belong to.';
PRINT '';
GO
