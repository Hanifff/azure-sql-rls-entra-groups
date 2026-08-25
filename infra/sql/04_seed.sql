-- ============================================================================
-- 04_seed.sql
--
-- Two layers of data.
--
-- The first is the customer's example from their diagram, so the demo opens on
-- something they recognise. Documents 21 and 42, projects 12345678 and 98765432.
--
-- The second is scale: enough projects and lines for the behaviour and the
-- numbers to mean something. Group IDs there are synthetic, because the
-- predicate only compares GUIDs in local tables and cannot tell a real directory
-- object from a generated one. Creating thousands of real Entra groups would
-- prove nothing extra.
--
-- Idempotent.
-- ============================================================================

DECLARE @ExtraProjects INT = {{PROJECT_COUNT}};   -- in addition to the two from the diagram
DECLARE @ExtraLines    INT = {{DOCUMENT_COUNT}};

IF EXISTS (SELECT 1 FROM sys.security_policies WHERE name = 'ProjectLinePolicy')
    ALTER SECURITY POLICY Security.ProjectLinePolicy WITH (STATE = OFF);
GO

DELETE FROM dbo.DocumentLine;
DELETE FROM dbo.ProjectAccess;
DELETE FROM dbo.Document;
DBCC CHECKIDENT ('dbo.DocumentLine', RESEED, 0) WITH NO_INFOMSGS;
GO

-- --- the customer's example, exactly as drawn --------------------------------
INSERT INTO dbo.Document (DocumentId, DocumentName) VALUES
    (21, N'NS_123'),
    (42, N'TEK17');

-- Real Entra group object IDs are substituted here by deploy.sh when it has
-- permission to create groups. Otherwise these stay synthetic and the demo
-- still works, it just has nothing real to resolve against.
INSERT INTO dbo.ProjectAccess (ProjectId, ProjectName, EntraIdWrite, EntraIdRead) VALUES
    (12345678, N'Project 12345678', '__ALPHA_WRITE__', '__ALPHA_READ__'),
    (98765432, N'Project 98765432', '__BETA_WRITE__',  '__BETA_READ__');

INSERT INTO dbo.DocumentLine (DocumentId, ProjectId, Comment) VALUES
    (21, 12345678, N'Connection made!'),
    (42, 98765432, N'Hello world');

PRINT '  Seeded the diagram example: 2 documents, 2 projects, 2 lines';
GO

-- --- scale -------------------------------------------------------------------
DECLARE @ExtraProjects INT = {{PROJECT_COUNT}};

;WITH Nums AS (
    SELECT TOP (@ExtraProjects)
           ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT INTO dbo.Document (DocumentId, DocumentName)
SELECT 1000 + n, CONCAT(N'DOC_', FORMAT(n, '0000')) FROM Nums;

-- Group IDs derived from the project number, so every run produces the same
-- values and the demo is repeatable.
;WITH Nums AS (
    SELECT TOP (@ExtraProjects)
           ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT INTO dbo.ProjectAccess (ProjectId, ProjectName, EntraIdWrite, EntraIdRead)
SELECT
    100000 + n,
    CONCAT(N'Project ', FORMAT(n, '0000')),
    CONVERT(UNIQUEIDENTIFIER, HASHBYTES('MD5', CONCAT('write:', n))),
    CONVERT(UNIQUEIDENTIFIER, HASHBYTES('MD5', CONCAT('read:',  n)))
FROM Nums;

PRINT CONCAT('  Seeded ', @ExtraProjects, ' more projects');
GO

DECLARE @ExtraLines    INT = {{DOCUMENT_COUNT}};
DECLARE @ExtraProjects INT = {{PROJECT_COUNT}};

;WITH Nums AS (
    SELECT TOP (@ExtraLines)
           ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT INTO dbo.DocumentLine (DocumentId, ProjectId, Comment)
SELECT
    p.DocumentId,
    p.ProjectId,
    CONCAT(N'Line ', n, N' on ', p.ProjectName)
FROM Nums
CROSS APPLY (
    -- Spread lines evenly over the seeded projects. Uses @ExtraProjects rather
    -- than a literal, or a smaller seed would reference projects that do not
    -- exist and silently insert nothing.
    SELECT pa.ProjectId, pa.ProjectName, 1000 + (((n - 1) % @ExtraProjects) + 1) AS DocumentId
    FROM dbo.ProjectAccess pa
    WHERE pa.ProjectId = 100000 + (((n - 1) % @ExtraProjects) + 1)
) AS p;

PRINT CONCAT('  Seeded ', @@ROWCOUNT, ' more lines');
GO

UPDATE STATISTICS dbo.DocumentLine;
UPDATE STATISTICS dbo.ProjectAccess;
GO

IF EXISTS (SELECT 1 FROM sys.security_policies WHERE name = 'ProjectLinePolicy')
    ALTER SECURITY POLICY Security.ProjectLinePolicy WITH (STATE = ON);
GO

PRINT 'Project model seeded, policy re-enabled.';
GO
