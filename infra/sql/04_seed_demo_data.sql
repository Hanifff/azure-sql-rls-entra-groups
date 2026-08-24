-- ============================================================================
-- 03_seed_demo_data.sql
-- Representative demo data. Deliberately NOT 100,000 real Entra groups.
--
-- Scale here is chosen to be honest about two different things:
--
--   * the IDENTITY path is proven with a small number of REAL Entra groups
--     (wired up in 04_register_demo_users.sql), because that is what exercises
--     token pass-through, and
--   * the SCALE path is proven with synthetic group IDs, because the RLS
--     predicate cannot tell the difference - it only ever compares GUIDs in
--     local tables. Creating thousands of real directory objects would prove
--     nothing extra and would pollute the tenant.
--
-- Shape: each project owns two Entra groups, one for read and one for write.
--        Documents belong to a project and inherit its two group IDs.
--
-- Idempotent: truncates and reseeds.
-- ============================================================================

DECLARE @ProjectCount  INT = {{PROJECT_COUNT}};   -- two groups each: read and write
DECLARE @DocumentCount INT = {{DOCUMENT_COUNT}};

-- Seed with the policy off. The dbo bypass in the predicate would also allow
-- this, but turning the policy off makes the seed independent of that logic.
IF EXISTS (SELECT 1 FROM sys.security_policies WHERE name = 'DocumentAccessPolicy')
    ALTER SECURITY POLICY Security.DocumentAccessPolicy WITH (STATE = OFF);
GO

-- ----------------------------------------------------------------------------
-- Demo scaffolding: the project -> Entra group mapping.
-- Not part of the security design; the RLS predicate never reads this table.
-- It exists so the demo can explain where a row's group IDs came from.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('dbo.Projects', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Projects (
        ProjectId        INT              NOT NULL CONSTRAINT PK_Projects PRIMARY KEY,
        ProjectName      NVARCHAR(128)    NOT NULL,
        ReadGroupId      UNIQUEIDENTIFIER NOT NULL,
        WriteGroupId     UNIQUEIDENTIFIER NOT NULL,
        IsRealEntraGroup BIT              NOT NULL CONSTRAINT DF_Projects_IsReal DEFAULT (0)
    );
END
GO

DECLARE @ProjectCount  INT = {{PROJECT_COUNT}};
DECLARE @DocumentCount INT = {{DOCUMENT_COUNT}};

DELETE FROM dbo.Documents;
DELETE FROM dbo.Projects;
DBCC CHECKIDENT ('dbo.Documents', RESEED, 0) WITH NO_INFOMSGS;

-- Group IDs are derived from the project ID so every run produces the same
-- GUIDs - makes the demo repeatable and the docs quotable.
;WITH Nums AS (
    SELECT TOP (@ProjectCount)
           ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT INTO dbo.Projects (ProjectId, ProjectName, ReadGroupId, WriteGroupId)
SELECT
    n,
    CONCAT(N'Project ', FORMAT(n, '0000')),
    CONVERT(UNIQUEIDENTIFIER, HASHBYTES('MD5', CONCAT('read:',  n))),
    CONVERT(UNIQUEIDENTIFIER, HASHBYTES('MD5', CONCAT('write:', n)))
FROM Nums;

PRINT CONCAT('  Seeded ', @@ROWCOUNT, ' projects (', @ProjectCount * 2, ' distinct group IDs)');
GO

DECLARE @DocumentCount INT = {{DOCUMENT_COUNT}};

;WITH Nums AS (
    SELECT TOP (@DocumentCount)
           ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT INTO dbo.Documents (ProjectId, ProjectName, Title, Body, ReadGroupId, WriteGroupId)
SELECT
    p.ProjectId,
    p.ProjectName,
    CONCAT(N'Document ', n),
    CONCAT(N'Representative payload for document ', n, N' in ', p.ProjectName, N'.'),
    p.ReadGroupId,
    p.WriteGroupId
FROM Nums
CROSS APPLY (
    SELECT * FROM dbo.Projects
    WHERE ProjectId = ((n - 1) % (SELECT COUNT(*) FROM dbo.Projects)) + 1
) AS p;

PRINT CONCAT('  Seeded ', @@ROWCOUNT, ' documents');
GO

UPDATE STATISTICS dbo.Documents;
UPDATE STATISTICS dbo.Projects;
GO

IF EXISTS (SELECT 1 FROM sys.security_policies WHERE name = 'DocumentAccessPolicy')
    ALTER SECURITY POLICY Security.DocumentAccessPolicy WITH (STATE = ON);
GO

PRINT 'Demo data seeded, policy re-enabled.';
GO
