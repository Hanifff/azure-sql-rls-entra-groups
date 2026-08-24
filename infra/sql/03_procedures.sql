-- ============================================================================
-- 03_procedures.sql
-- The two entry points the sync job calls. Keeping the write logic in the
-- database means the job needs no schema knowledge and no ad-hoc SQL.
--
-- Idempotent.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Keeps Security.UserIdentity aligned with the Entra users that actually exist
-- as database principals.
--
-- Runs entirely inside SQL - no Microsoft Graph call needed - because for an
-- Entra database principal the SID *is* the object ID. Login-based principals
-- carry a longer SID with a trailing marker, so only the 16-byte contained
-- users are mapped here.
-- ----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE Security.usp_RefreshUserIdentity
AS
BEGIN
    SET NOCOUNT ON;

    MERGE Security.UserIdentity AS target
    USING (
        SELECT
            principal_id                     AS DatabasePrincipalId,
            CAST(sid AS UNIQUEIDENTIFIER)    AS UserObjectId,
            name                             AS UserPrincipalName
        FROM sys.database_principals
        WHERE type = 'E'                  -- EXTERNAL_USER (Entra user or app)
          AND DATALENGTH(sid) = 16        -- contained user; SID is the raw object ID
    ) AS source
        ON target.DatabasePrincipalId = source.DatabasePrincipalId

    WHEN MATCHED THEN
        UPDATE SET UserObjectId      = source.UserObjectId,
                   UserPrincipalName = source.UserPrincipalName,
                   SyncedAt          = SYSUTCDATETIME()

    WHEN NOT MATCHED BY TARGET THEN
        INSERT (DatabasePrincipalId, UserObjectId, UserPrincipalName)
        VALUES (source.DatabasePrincipalId, source.UserObjectId, source.UserPrincipalName);

    -- Drop entries whose database principal no longer exists at all. Done as a
    -- separate statement rather than MERGE's NOT MATCHED BY SOURCE so that
    -- identities registered by hand (the Entra admin, who connects as dbo and
    -- is therefore not an external principal) survive a refresh.
    DELETE ui
    FROM Security.UserIdentity AS ui
    WHERE NOT EXISTS (
        SELECT 1 FROM sys.database_principals AS dp
        WHERE dp.principal_id = ui.DatabasePrincipalId
    );

    SELECT COUNT(*) AS UserIdentityRows FROM Security.UserIdentity;
END
GO

-- ----------------------------------------------------------------------------
-- Replaces one user's group memberships in a single set-based statement.
--
-- @Groups is the complete current membership list for that user, so removals
-- are handled by the NOT MATCHED BY SOURCE branch - this is what makes
-- offboarding and group removal take effect without any separate cleanup job.
-- ----------------------------------------------------------------------------
IF TYPE_ID('Security.GroupIdList') IS NULL
    CREATE TYPE Security.GroupIdList AS TABLE (GroupObjectId UNIQUEIDENTIFIER PRIMARY KEY);
GO

CREATE OR ALTER PROCEDURE Security.usp_MergeGroupMembership
    @UserObjectId UNIQUEIDENTIFIER,
    @Groups       Security.GroupIdList READONLY
AS
BEGIN
    SET NOCOUNT ON;

    MERGE Security.GroupMembership AS target
    USING (SELECT GroupObjectId FROM @Groups) AS source
        ON  target.UserObjectId  = @UserObjectId
        AND target.GroupObjectId = source.GroupObjectId

    WHEN NOT MATCHED BY TARGET THEN
        INSERT (UserObjectId, GroupObjectId)
        VALUES (@UserObjectId, source.GroupObjectId)

    WHEN NOT MATCHED BY SOURCE AND target.UserObjectId = @UserObjectId THEN
        DELETE;

    SELECT @@ROWCOUNT AS RowsChanged;
END
GO

-- ----------------------------------------------------------------------------
-- Records the outcome of a sync run so staleness is observable.
-- ----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE Security.usp_RecordSyncRun
    @SyncName    NVARCHAR(64),
    @Status      NVARCHAR(32),
    @RowsChanged INT           = NULL,
    @DeltaLink   NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE Security.SyncState
       SET LastRunAt     = SYSUTCDATETIME(),
           LastRunStatus = @Status,
           RowsChanged   = @RowsChanged,
           DeltaLink     = COALESCE(@DeltaLink, DeltaLink)
     WHERE SyncName = @SyncName;

    IF @@ROWCOUNT = 0
        INSERT INTO Security.SyncState (SyncName, DeltaLink, LastRunAt, LastRunStatus, RowsChanged)
        VALUES (@SyncName, @DeltaLink, SYSUTCDATETIME(), @Status, @RowsChanged);
END
GO

PRINT 'Sync procedures ready.';
GO
