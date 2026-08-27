-- ============================================================================
-- 13_compare_modes.sql
--
-- Read and write, both users, both read-filtering modes, in one table.
--
-- Switches read filtering on and off itself and restores whatever was set
-- before, so it can be run at any point in a demo without leaving state behind.
-- ============================================================================
SET NOCOUNT ON;
SET ANSI_WARNINGS OFF;

DECLARE @wasFiltered BIT = CASE WHEN EXISTS (
    SELECT 1 FROM sys.security_predicates AS sp
    JOIN sys.security_policies AS p ON p.object_id = sp.object_id
    WHERE p.name = 'ProjectLinePolicy' AND sp.predicate_type_desc = 'FILTER'
) THEN 1 ELSE 0 END;

DECLARE @results TABLE (
    Mode        VARCHAR(20),
    UserName    VARCHAR(20),
    RowsVisible INT,
    CanWriteOwn VARCHAR(3),
    CanWriteOther VARCHAR(3),
    SortOrder   INT
);

DECLARE @mode INT = 0;

WHILE @mode <= 1
BEGIN
    -- Rebind the policy for this pass.
    IF EXISTS (SELECT 1 FROM sys.security_policies WHERE name = 'ProjectLinePolicy')
        DROP SECURITY POLICY Security.ProjectLinePolicy;

    IF @mode = 0
        CREATE SECURITY POLICY Security.ProjectLinePolicy
            ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine AFTER INSERT,
            ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine BEFORE UPDATE,
            ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine AFTER UPDATE,
            ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine BEFORE DELETE
        WITH (STATE = ON, SCHEMABINDING = ON);
    ELSE
        CREATE SECURITY POLICY Security.ProjectLinePolicy
            ADD FILTER PREDICATE Security.fn_can_read_project(ProjectId)  ON dbo.DocumentLine,
            ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine AFTER INSERT,
            ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine BEFORE UPDATE,
            ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine AFTER UPDATE,
            ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine BEFORE DELETE
        WITH (STATE = ON, SCHEMABINDING = ON);

    DECLARE @modeName VARCHAR(20) = CASE WHEN @mode = 0 THEN 'read OFF' ELSE 'read ON' END;
    DECLARE @u INT = 0;

    WHILE @u <= 1
    BEGIN
        DECLARE @who VARCHAR(20) = CASE WHEN @u = 0 THEN 'anna' ELSE 'bjorn' END;
        DECLARE @seen INT, @own VARCHAR(3), @other VARCHAR(3), @imp BIT = 0;

        -- Rows visible
        IF @who = 'anna' BEGIN EXECUTE AS USER = 'anna';  SELECT @seen = COUNT(*) FROM dbo.DocumentLine; REVERT; END
        ELSE             BEGIN EXECUTE AS USER = 'bjorn'; SELECT @seen = COUNT(*) FROM dbo.DocumentLine; REVERT; END

        -- Write to the project they may hold (12345678)
        SET @own = 'yes';
        BEGIN TRY
            IF @who = 'anna' BEGIN EXECUTE AS USER = 'anna'; SET @imp = 1; END
            ELSE             BEGIN EXECUTE AS USER = 'bjorn'; SET @imp = 1; END
            INSERT INTO dbo.DocumentLine (DocumentId, ProjectId, Comment)
            VALUES (21, 12345678, N'demo:probe');
            REVERT; SET @imp = 0;
        END TRY
        BEGIN CATCH
            IF @imp = 1 BEGIN REVERT; SET @imp = 0; END
            SET @own = 'no';
        END CATCH

        -- Write to a project neither holds (98765432)
        SET @other = 'yes';
        BEGIN TRY
            IF @who = 'anna' BEGIN EXECUTE AS USER = 'anna'; SET @imp = 1; END
            ELSE             BEGIN EXECUTE AS USER = 'bjorn'; SET @imp = 1; END
            INSERT INTO dbo.DocumentLine (DocumentId, ProjectId, Comment)
            VALUES (42, 98765432, N'demo:probe');
            REVERT; SET @imp = 0;
        END TRY
        BEGIN CATCH
            IF @imp = 1 BEGIN REVERT; SET @imp = 0; END
            SET @other = 'no';
        END CATCH

        INSERT INTO @results VALUES (@modeName, @who, @seen, @own, @other, @mode * 2 + @u);

        DELETE FROM dbo.DocumentLine WHERE Comment LIKE N'demo:%';
        SET @u = @u + 1;
    END

    SET @mode = @mode + 1;
END

-- Put the policy back the way it was found.
IF EXISTS (SELECT 1 FROM sys.security_policies WHERE name = 'ProjectLinePolicy')
    DROP SECURITY POLICY Security.ProjectLinePolicy;

IF @wasFiltered = 1
    CREATE SECURITY POLICY Security.ProjectLinePolicy
        ADD FILTER PREDICATE Security.fn_can_read_project(ProjectId)  ON dbo.DocumentLine,
        ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine AFTER INSERT,
        ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine BEFORE UPDATE,
        ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine AFTER UPDATE,
        ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine BEFORE DELETE
    WITH (STATE = ON, SCHEMABINDING = ON);
ELSE
    CREATE SECURITY POLICY Security.ProjectLinePolicy
        ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine AFTER INSERT,
        ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine BEFORE UPDATE,
        ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine AFTER UPDATE,
        ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine BEFORE DELETE
    WITH (STATE = ON, SCHEMABINDING = ON);

PRINT '';
PRINT '============================================================';
PRINT ' Read and write, side by side';
PRINT '============================================================';
PRINT '';

SELECT
    Mode                AS [Read filtering],
    UserName            AS [User],
    RowsVisible         AS [Rows visible],
    CanWriteOwn         AS [Write 12345678],
    CanWriteOther       AS [Write 98765432]
FROM @results
ORDER BY SortOrder;

PRINT '';
PRINT '  Read filtering changes the left column only. The two write columns are';
PRINT '  identical in both modes, because reads and writes are separate';
PRINT '  predicates and separate decisions.';
PRINT '';
PRINT '  anna holds project 12345678 and nothing else, so she writes there and';
PRINT '  nowhere else, whether or not she can see the other rows.';
PRINT '';
PRINT '  Policy restored to the mode it was in before this ran.';
PRINT '';
GO
