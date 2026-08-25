namespace RestApiServer.Models;

/// <summary>
/// A row in dbo.DocumentLine. The row carries a ProjectId; the Entra group that
/// governs writing it is reached through dbo.ProjectAccess. WriteGroupId is
/// returned so the demo can show which group granted access.
/// </summary>
public class DocumentLine
{
    public int DocumentLineId { get; set; }
    public int DocumentId { get; set; }
    public long ProjectId { get; set; }
    public string DocumentName { get; set; } = string.Empty;
    public string? Comment { get; set; }
    public Guid WriteGroupId { get; set; }
    public DateTime CreatedAt { get; set; }
}

/// <summary>
/// What the database reports about the caller, used to prove that RLS is acting
/// on the end user's identity rather than a service account.
/// </summary>
public class CallerContext
{
    public string DatabaseUser { get; set; } = string.Empty;
    public int DatabasePrincipalId { get; set; }
    public Guid? UserObjectId { get; set; }
    public int GroupMembershipCount { get; set; }
    public int VisibleDocumentCount { get; set; }
    public DateTime? MembershipSyncedAt { get; set; }
}

public class ApiResponse<T>
{
    public bool Success { get; set; }
    public T? Data { get; set; }
    public string? Error { get; set; }
    public int Count { get; set; }
}
