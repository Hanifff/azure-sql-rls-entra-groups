using Microsoft.Data.SqlClient;
using RestApiServer.Models;

namespace RestApiServer.Services;

/// <summary>
/// Reads dbo.Documents over a connection authenticated with the caller's own
/// Entra token. No filtering happens here - every WHERE clause that matters is
/// applied by the RLS policy inside Azure SQL.
/// </summary>
public class SqlDataService
{
    private const int MaxRows = 200;

    private readonly string _connectionString;

    public SqlDataService(string connectionString)
    {
        _connectionString = connectionString;
    }

    private async Task<SqlConnection> OpenAsync(string? accessToken)
    {
        var connection = new SqlConnection(_connectionString);

        // This is the whole pattern: the user's token opens the connection, so
        // SQL authenticates the end user rather than a shared service account.
        if (!string.IsNullOrEmpty(accessToken))
        {
            connection.AccessToken = accessToken;
        }

        await connection.OpenAsync();
        return connection;
    }

    public async Task<List<Document>> GetDocumentsAsync(string? accessToken, int? projectId = null, int take = 50)
    {
        var documents = new List<Document>();

        await using var connection = await OpenAsync(accessToken);
        await using var command = new SqlCommand(
            @"SELECT TOP (@Take)
                     DocumentId, ProjectId, ProjectName, Title, Body,
                     ReadGroupId, WriteGroupId, CreatedAt
              FROM dbo.Documents
              WHERE (@ProjectId IS NULL OR ProjectId = @ProjectId)
              ORDER BY DocumentId;", connection);

        command.Parameters.AddWithValue("@Take", Math.Clamp(take, 1, MaxRows));
        command.Parameters.AddWithValue("@ProjectId", (object?)projectId ?? DBNull.Value);

        await using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            documents.Add(Map(reader));
        }

        return documents;
    }

    public async Task<Document?> GetDocumentByIdAsync(int documentId, string? accessToken)
    {
        await using var connection = await OpenAsync(accessToken);
        await using var command = new SqlCommand(
            @"SELECT DocumentId, ProjectId, ProjectName, Title, Body,
                     ReadGroupId, WriteGroupId, CreatedAt
              FROM dbo.Documents
              WHERE DocumentId = @DocumentId;", connection);

        command.Parameters.AddWithValue("@DocumentId", documentId);

        await using var reader = await command.ExecuteReaderAsync();
        return await reader.ReadAsync() ? Map(reader) : null;
    }

    /// <summary>
    /// What the database thinks of the caller. Reads dbo.vw_MyAccess, which
    /// reaches the entitlement tables through ownership chaining - callers have
    /// no direct permission on them.
    /// </summary>
    public async Task<CallerContext?> GetCallerContextAsync(string? accessToken)
    {
        await using var connection = await OpenAsync(accessToken);
        await using var command = new SqlCommand("SELECT * FROM dbo.vw_MyAccess;", connection);

        await using var reader = await command.ExecuteReaderAsync();
        if (!await reader.ReadAsync()) return null;

        return new CallerContext
        {
            DatabaseUser         = reader.GetString(reader.GetOrdinal("DatabaseUser")),
            DatabasePrincipalId  = reader.GetInt32(reader.GetOrdinal("DatabasePrincipalId")),
            UserObjectId         = reader.IsDBNull(reader.GetOrdinal("UserObjectId"))
                                       ? null : reader.GetGuid(reader.GetOrdinal("UserObjectId")),
            GroupMembershipCount = reader.GetInt32(reader.GetOrdinal("GroupMembershipCount")),
            VisibleDocumentCount = reader.GetInt32(reader.GetOrdinal("VisibleDocumentCount")),
            MembershipSyncedAt   = reader.IsDBNull(reader.GetOrdinal("MembershipSyncedAt"))
                                       ? null : reader.GetDateTime(reader.GetOrdinal("MembershipSyncedAt"))
        };
    }

    private static Document Map(SqlDataReader reader) => new()
    {
        DocumentId   = reader.GetInt32(0),
        ProjectId    = reader.GetInt32(1),
        ProjectName  = reader.GetString(2),
        Title        = reader.GetString(3),
        Body         = reader.IsDBNull(4) ? null : reader.GetString(4),
        ReadGroupId  = reader.GetGuid(5),
        WriteGroupId = reader.GetGuid(6),
        CreatedAt    = reader.GetDateTime(7)
    };
}
