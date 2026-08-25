-- ============================================================================
-- 10_project_model_schema.sql
--
-- The customer's model, as drawn:
--
--   Document        master list of documents
--   ProjectAccess   ProjectId -> the Entra groups that may read and write it
--                   (they already sync this from their IAM system)
--   DocumentLine    the protected table. Rows carry a ProjectId, not a group.
--   GroupMembership which users are in which groups. This is the piece that
--                   does not exist yet, and the reason the database cannot
--                   currently answer their question.
--
-- Note the shape difference from the other model in this repo: the group is
-- reached through the project, not stored on the row. So the predicate joins.
--
-- Idempotent.
-- ============================================================================

IF SCHEMA_ID('Security') IS NULL
    EXEC('CREATE SCHEMA Security');
GO

-- ----------------------------------------------------------------------------
-- Master documents. No row-level security here.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('dbo.Document', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Document (
        DocumentId   INT           NOT NULL CONSTRAINT PK_Document PRIMARY KEY,
        DocumentName NVARCHAR(128) NOT NULL
    );
    PRINT '  Created dbo.Document';
END
GO

-- ----------------------------------------------------------------------------
-- Project to group mapping. In their environment this is written by the IAM
-- sync. Here it is seeded, and the sync script updates it the same way.
--
-- Groups are stored as object IDs. If the source system supplies display names
-- instead, this column changes type and IS_MEMBER becomes an option; see
-- 11_project_model_policy.sql for what that would look like.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('dbo.ProjectAccess', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ProjectAccess (
        ProjectId      BIGINT           NOT NULL CONSTRAINT PK_ProjectAccess PRIMARY KEY,
        ProjectName    NVARCHAR(128)    NULL,
        EntraIdWrite   UNIQUEIDENTIFIER NOT NULL,
        EntraIdRead    UNIQUEIDENTIFIER NOT NULL,
        SyncedAt       DATETIME2(3)     NOT NULL
            CONSTRAINT DF_ProjectAccess_SyncedAt DEFAULT (SYSUTCDATETIME())
    );

    CREATE NONCLUSTERED INDEX IX_ProjectAccess_Write ON dbo.ProjectAccess (EntraIdWrite) INCLUDE (ProjectId);
    CREATE NONCLUSTERED INDEX IX_ProjectAccess_Read  ON dbo.ProjectAccess (EntraIdRead)  INCLUDE (ProjectId);
    PRINT '  Created dbo.ProjectAccess';
END
GO

-- ----------------------------------------------------------------------------
-- The protected table.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('dbo.DocumentLine', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DocumentLine (
        DocumentLineId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DocumentLine PRIMARY KEY,
        DocumentId     INT               NOT NULL,
        ProjectId      BIGINT            NOT NULL,
        Comment        NVARCHAR(1024)    NULL,
        CreatedAt      DATETIME2(3)      NOT NULL
            CONSTRAINT DF_DocumentLine_CreatedAt DEFAULT (SYSUTCDATETIME())
    );

    -- The predicate looks rows up by ProjectId, so this index carries it.
    CREATE NONCLUSTERED INDEX IX_DocumentLine_ProjectId ON dbo.DocumentLine (ProjectId);
    PRINT '  Created dbo.DocumentLine';
END
GO

-- ----------------------------------------------------------------------------
-- The missing table. One row per user-to-group edge.
--
-- Size is driven by (number of users x groups per user). It is not affected by
-- how many groups exist in the tenant, nor by how many rows DocumentLine holds.
-- Ten thousand users in 250 groups each is 2.5 million rows, roughly 150 MB.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('Security.GroupMembership', 'U') IS NULL
BEGIN
    CREATE TABLE Security.GroupMembership (
        UserObjectId  UNIQUEIDENTIFIER NOT NULL,
        GroupObjectId UNIQUEIDENTIFIER NOT NULL,
        SyncedAt      DATETIME2(3)     NOT NULL
            CONSTRAINT DF_GroupMembership_SyncedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_GroupMembership PRIMARY KEY CLUSTERED (UserObjectId, GroupObjectId)
    );

    -- Supports the join direction the predicate uses: group first, then user.
    CREATE NONCLUSTERED INDEX IX_GroupMembership_Group
        ON Security.GroupMembership (GroupObjectId, UserObjectId);

    PRINT '  Created Security.GroupMembership';
END
GO

-- ----------------------------------------------------------------------------
-- Maps the database principal on the connection to its Entra object ID.
-- Needed because an RLS predicate is SCHEMABINDING and cannot read
-- sys.database_principals directly.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('Security.UserIdentity', 'U') IS NULL
BEGIN
    CREATE TABLE Security.UserIdentity (
        DatabasePrincipalId INT              NOT NULL CONSTRAINT PK_UserIdentity PRIMARY KEY,
        UserObjectId        UNIQUEIDENTIFIER NOT NULL,
        UserPrincipalName   NVARCHAR(256)    NOT NULL,
        IsActive            BIT              NOT NULL CONSTRAINT DF_UserIdentity_IsActive DEFAULT (1),
        SyncedAt            DATETIME2(3)     NOT NULL CONSTRAINT DF_UserIdentity_SyncedAt DEFAULT (SYSUTCDATETIME())
    );

    CREATE UNIQUE NONCLUSTERED INDEX UX_UserIdentity_UserObjectId
        ON Security.UserIdentity (UserObjectId);

    PRINT '  Created Security.UserIdentity';
END
GO

PRINT 'Project model schema ready.';
GO
