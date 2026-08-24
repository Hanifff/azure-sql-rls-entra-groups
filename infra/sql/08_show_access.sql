-- ============================================================================
-- 08_show_access.sql
-- Demo aid: what each registered user can see, and why.
--
-- Run as the Entra admin. Because the admin connects as dbo it bypasses RLS,
-- so this reports the full picture rather than the caller's own slice.
-- ============================================================================
SET NOCOUNT ON;

PRINT '--- Access summary per user --------------------------------';

SELECT
    ui.UserPrincipalName                            AS [User],
    COUNT(DISTINCT m.GroupObjectId)                 AS [Groups],
    COUNT(DISTINCT dr.DocumentId)                   AS [Readable],
    COUNT(DISTINCT dw.DocumentId)                   AS [Writable]
FROM Security.UserIdentity AS ui
LEFT JOIN Security.GroupMembership AS m  ON m.UserObjectId = ui.UserObjectId
LEFT JOIN dbo.Documents AS dr            ON dr.ReadGroupId  = m.GroupObjectId
LEFT JOIN dbo.Documents AS dw            ON dw.WriteGroupId = m.GroupObjectId
GROUP BY ui.UserPrincipalName
ORDER BY [Readable] DESC;

PRINT '';
PRINT '--- Projects backed by real Entra groups -------------------';

SELECT
    p.ProjectId,
    p.ProjectName,
    p.ReadGroupId,
    p.WriteGroupId,
    (SELECT COUNT(*) FROM dbo.Documents d WHERE d.ProjectId = p.ProjectId) AS Documents
FROM dbo.Projects AS p
WHERE p.IsRealEntraGroup = 1
ORDER BY p.ProjectId;

PRINT '';
PRINT '--- Last membership sync -----------------------------------';

SELECT SyncName, LastRunAt, LastRunStatus, RowsChanged
FROM Security.SyncState;
GO
