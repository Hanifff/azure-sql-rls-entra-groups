-- ============================================================================
-- 01_schema.sql
-- Business table + the two entitlement tables the RLS predicate reads.
--
-- Model (matches the customer's description):
--   every row carries a ReadGroupId and a WriteGroupId, each one the object ID
--   of a Microsoft Entra security group. A user may read the row if they are a
--   member of ReadGroupId, and change it if they are a member of WriteGroupId.
--
-- Group membership is NOT resolved from the token and NOT sent by the API.
-- It is synced into Security.GroupMembership by a background job (see
-- group-sync/). The database only ever reads local tables.
--
-- Idempotent.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Security schema: entitlement data only. No business data lives here.
-- ----------------------------------------------------------------------------
IF SCHEMA_ID('Security') IS NULL
    EXEC('CREATE SCHEMA Security');
GO

-- ----------------------------------------------------------------------------
-- Maps the database principal on the current connection to its Entra object ID.
--
-- Needed because the RLS predicate is SCHEMABINDING and therefore cannot query
-- sys.database_principals directly. Populated by the sync job.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('Security.UserIdentity', 'U') IS NULL
BEGIN
    CREATE TABLE Security.UserIdentity (
        DatabasePrincipalId INT              NOT NULL,
        UserObjectId        UNIQUEIDENTIFIER NOT NULL,
        UserPrincipalName   NVARCHAR(256)    NOT NULL,
        IsActive            BIT              NOT NULL
            CONSTRAINT DF_UserIdentity_IsActive DEFAULT (1),
        SyncedAt            DATETIME2(3)     NOT NULL
            CONSTRAINT DF_UserIdentity_SyncedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_UserIdentity PRIMARY KEY CLUSTERED (DatabasePrincipalId)
    );

    CREATE UNIQUE NONCLUSTERED INDEX UX_UserIdentity_UserObjectId
        ON Security.UserIdentity (UserObjectId);

    PRINT '  Created Security.UserIdentity';
END
GO

-- ----------------------------------------------------------------------------
-- The entitlement table. One row per user-to-group edge, synced from Graph.
--
-- The clustered PK is what makes the RLS predicate a seek instead of a scan -
-- this index IS the performance design.
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

    PRINT '  Created Security.GroupMembership';
END
GO

-- Lets the sync job answer "who is in this group" cheaply during offboarding.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('Security.GroupMembership')
                 AND name = 'IX_GroupMembership_GroupObjectId')
BEGIN
    CREATE NONCLUSTERED INDEX IX_GroupMembership_GroupObjectId
        ON Security.GroupMembership (GroupObjectId) INCLUDE (UserObjectId);
END
GO

-- ----------------------------------------------------------------------------
-- Records each sync run so staleness is observable rather than guessed.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('Security.SyncState', 'U') IS NULL
BEGIN
    CREATE TABLE Security.SyncState (
        SyncName       NVARCHAR(64)   NOT NULL,
        DeltaLink      NVARCHAR(MAX)  NULL,
        LastRunAt      DATETIME2(3)   NULL,
        LastRunStatus  NVARCHAR(32)   NULL,
        RowsChanged    INT            NULL,
        CONSTRAINT PK_SyncState PRIMARY KEY CLUSTERED (SyncName)
    );

    INSERT INTO Security.SyncState (SyncName) VALUES (N'EntraGroupMembership');
    PRINT '  Created Security.SyncState';
END
GO

-- ----------------------------------------------------------------------------
-- Business table. Rows belong to a project; the project's Entra groups decide
-- who may read and who may write.
-- ----------------------------------------------------------------------------
IF OBJECT_ID('dbo.Documents', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Documents (
        DocumentId    INT IDENTITY(1,1) NOT NULL,
        ProjectId     INT               NOT NULL,
        ProjectName   NVARCHAR(128)     NOT NULL,
        Title         NVARCHAR(256)     NOT NULL,
        Body          NVARCHAR(1024)    NULL,
        ReadGroupId   UNIQUEIDENTIFIER  NOT NULL,
        WriteGroupId  UNIQUEIDENTIFIER  NOT NULL,
        CreatedAt     DATETIME2(3)      NOT NULL
            CONSTRAINT DF_Documents_CreatedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_Documents PRIMARY KEY CLUSTERED (DocumentId)
    );

    PRINT '  Created dbo.Documents';
END
GO

-- Supports the FILTER predicate lookup.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('dbo.Documents')
                 AND name = 'IX_Documents_ReadGroupId')
BEGIN
    CREATE NONCLUSTERED INDEX IX_Documents_ReadGroupId
        ON dbo.Documents (ReadGroupId) INCLUDE (ProjectId, Title);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('dbo.Documents')
                 AND name = 'IX_Documents_WriteGroupId')
BEGIN
    CREATE NONCLUSTERED INDEX IX_Documents_WriteGroupId
        ON dbo.Documents (WriteGroupId);
END
GO

PRINT 'Schema ready.';
GO
