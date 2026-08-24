namespace GraphqlServer.Models;

/// <summary>
/// A row in dbo.Documents. ReadGroupId/WriteGroupId are Entra group object IDs;
/// they are returned so the demo can show which group granted access.
/// </summary>
public class Document
{
    public int DocumentId { get; set; }
    public int ProjectId { get; set; }
    public string ProjectName { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public string? Body { get; set; }
    public Guid ReadGroupId { get; set; }
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
