-- ============================================================================
-- 09_toggle_read.sql
--
-- Switches read filtering on or off, live, so the difference can be shown in a
-- meeting rather than described.
--
-- Reads are open by default and handled by table permissions. Where they also
-- need restricting per project, this binds the read predicate to the same
-- policy. Both behaviours are available so the demo can flip in a second.
--
-- Usage: set @EnableReadFiltering below, then run.
-- ============================================================================
SET NOCOUNT ON;

DECLARE @EnableReadFiltering BIT = 1;   -- 1 = restrict reads, 0 = everyone reads

IF EXISTS (SELECT 1 FROM sys.security_policies WHERE name = 'ProjectLinePolicy')
    DROP SECURITY POLICY Security.ProjectLinePolicy;
GO

DECLARE @EnableReadFiltering BIT = 1;

IF @EnableReadFiltering = 1
BEGIN
    EXEC('
        CREATE SECURITY POLICY Security.ProjectLinePolicy
            ADD FILTER PREDICATE Security.fn_can_read_project(ProjectId)  ON dbo.DocumentLine,
            ADD BLOCK  PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine AFTER INSERT,
            ADD BLOCK  PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine BEFORE UPDATE,
            ADD BLOCK  PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine AFTER UPDATE,
            ADD BLOCK  PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine BEFORE DELETE
        WITH (STATE = ON, SCHEMABINDING = ON);');

    PRINT 'Read filtering ON. Users see only projects whose read group they are in.';
    PRINT 'Note: reads now pay the predicate cost per candidate row. Compare';
    PRINT 'a SELECT COUNT(*) before and after to see what that means.';
END
ELSE
BEGIN
    EXEC('
        CREATE SECURITY POLICY Security.ProjectLinePolicy
            ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine AFTER INSERT,
            ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine BEFORE UPDATE,
            ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine AFTER UPDATE,
            ADD BLOCK PREDICATE Security.fn_can_write_project(ProjectId) ON dbo.DocumentLine BEFORE DELETE
        WITH (STATE = ON, SCHEMABINDING = ON);');

    PRINT 'Read filtering OFF. Everyone reads every line, writes stay restricted.';
END
GO
