using GraphqlServer.Models;
using GraphqlServer.Services;
using HotChocolate;

namespace GraphqlServer.GraphQL;

/// <summary>
/// Every field here runs against the caller's own database connection, so the
/// rows returned are whatever RLS decided the caller may see.
/// </summary>
public class Query
{
    [GraphQLDescription("Documents the signed-in user is entitled to read, filtered by RLS in Azure SQL.")]
    public async Task<List<Document>> GetDocuments(
        [Service] SqlDataService dataService,
        [Service] ITokenAccessor tokenAccessor,
        int? projectId = null,
        int take = 50)
    {
        var token = tokenAccessor.GetAccessToken();
        return await dataService.GetDocumentsAsync(token, projectId, take);
    }

    [GraphQLDescription("A single document by ID. Returns null if RLS filters it out.")]
    public async Task<Document?> GetDocument(
        int documentId,
        [Service] SqlDataService dataService,
        [Service] ITokenAccessor tokenAccessor)
    {
        var token = tokenAccessor.GetAccessToken();
        return await dataService.GetDocumentByIdAsync(documentId, token);
    }

    [GraphQLDescription("How Azure SQL sees the caller: database principal, Entra object ID, synced group count.")]
    public async Task<CallerContext?> GetMyAccess(
        [Service] SqlDataService dataService,
        [Service] ITokenAccessor tokenAccessor)
    {
        var token = tokenAccessor.GetAccessToken();
        return await dataService.GetCallerContextAsync(token);
    }
}
