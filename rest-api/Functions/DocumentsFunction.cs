using System.Net;
using System.Text.Json;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;
using RestApiServer.Models;
using RestApiServer.Services;

namespace RestApiServer.Functions;

/// <summary>
/// REST endpoints over dbo.Documents. The caller's Entra token is forwarded to
/// Azure SQL, so which rows come back is decided by the RLS policy rather than
/// by anything in this class. There is deliberately no filtering here.
/// </summary>
public class DocumentsFunction
{
    private const int DefaultPageSize = 50;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true
    };

    private readonly ILogger<DocumentsFunction> _logger;
    private readonly SqlDataService _sqlService;

    public DocumentsFunction(ILogger<DocumentsFunction> logger, SqlDataService sqlService)
    {
        _logger = logger;
        _sqlService = sqlService;
    }

    /// <summary>GET /api/documents?projectId=&amp;take= - documents the caller may read.</summary>
    [Function("GetDocuments")]
    public Task<HttpResponseData> GetDocuments(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "documents")] HttpRequestData req)
        => Handle(req, async token =>
        {
            var query = ParseQuery(req.Url.Query);
            int? projectId = query.TryGetValue("projectId", out var p) && int.TryParse(p, out var pid) ? pid : null;
            var take = query.TryGetValue("take", out var t) && int.TryParse(t, out var n) ? n : DefaultPageSize;

            var documents = await _sqlService.GetDocumentsAsync(token, projectId, take);
            _logger.LogInformation("Returned {Count} documents", documents.Count);

            return Ok(req, documents, documents.Count);
        });

    /// <summary>GET /api/documents/{id} - 404 also means the RLS policy filtered it out.</summary>
    [Function("GetDocumentById")]
    public Task<HttpResponseData> GetDocumentById(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "documents/{id:int}")] HttpRequestData req,
        int id)
        => Handle(req, async token =>
        {
            var document = await _sqlService.GetDocumentByIdAsync(id, token);

            return document is null
                ? await Error(req, HttpStatusCode.NotFound,
                    $"Document {id} does not exist, or the RLS policy filtered it out.")
                : Ok(req, document, 1);
        });

    /// <summary>GET /api/my-access - how Azure SQL identified the caller.</summary>
    [Function("GetMyAccess")]
    public Task<HttpResponseData> GetMyAccess(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "my-access")] HttpRequestData req)
        => Handle(req, async token =>
        {
            var context = await _sqlService.GetCallerContextAsync(token);

            return context is null
                ? await Error(req, HttpStatusCode.NotFound,
                    "This caller has no row in Security.UserIdentity yet. Run the membership sync.")
                : Ok(req, context, 1);
        });

    /// <summary>GET /api/health - no auth required.</summary>
    [Function("HealthCheck")]
    public async Task<HttpResponseData> HealthCheck(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "health")] HttpRequestData req)
    {
        var response = req.CreateResponse(HttpStatusCode.OK);
        response.Headers.Add("Content-Type", "application/json");
        await response.WriteStringAsync(JsonSerializer.Serialize(
            new { status = "healthy", timestamp = DateTime.UtcNow, service = "rls-demo-rest-api" },
            JsonOptions));
        return response;
    }

    /// <summary>
    /// Every authenticated endpoint needs the same token check and the same
    /// error handling, so they share this wrapper.
    /// </summary>
    private async Task<HttpResponseData> Handle(
        HttpRequestData req,
        Func<string, Task<HttpResponseData>> handler)
    {
        var token = TokenExtractor.FromRequest(req);
        if (string.IsNullOrEmpty(token))
        {
            return await Error(req, HttpStatusCode.Unauthorized,
                "Bearer token required in the Authorization header.");
        }

        try
        {
            return await handler(token);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Request to {Path} failed", req.Url.AbsolutePath);
            return await Error(req, HttpStatusCode.InternalServerError, ex.Message);
        }
    }

    private static HttpResponseData Ok<T>(HttpRequestData req, T data, int count)
    {
        var response = req.CreateResponse(HttpStatusCode.OK);
        response.Headers.Add("Content-Type", "application/json");
        response.WriteString(JsonSerializer.Serialize(
            new ApiResponse<T> { Success = true, Data = data, Count = count }, JsonOptions));
        return response;
    }

    private static async Task<HttpResponseData> Error(
        HttpRequestData req, HttpStatusCode statusCode, string message)
    {
        var response = req.CreateResponse(statusCode);
        response.Headers.Add("Content-Type", "application/json");
        await response.WriteStringAsync(JsonSerializer.Serialize(
            new ApiResponse<object> { Success = false, Error = message }, JsonOptions));
        return response;
    }

    private static Dictionary<string, string> ParseQuery(string query)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        foreach (var pair in query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = pair.Split('=', 2);
            if (parts.Length == 2)
                result[Uri.UnescapeDataString(parts[0])] = Uri.UnescapeDataString(parts[1]);
        }

        return result;
    }
}
