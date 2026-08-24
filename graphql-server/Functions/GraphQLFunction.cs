using System.Text.Json;
using GraphqlServer.Services;
using HotChocolate.Execution;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;

namespace GraphqlServer.Functions;

/// <summary>
/// Single GraphQL endpoint. GET without a query returns the GraphiQL explorer,
/// GET with one executes it, POST is the normal path.
/// </summary>
public class GraphQLFunction
{
    private static readonly JsonSerializerOptions JsonOptions =
        new() { PropertyNameCaseInsensitive = true };

    private readonly IRequestExecutorResolver _executorResolver;
    private readonly ITokenAccessor _tokenAccessor;

    public GraphQLFunction(IRequestExecutorResolver executorResolver, ITokenAccessor tokenAccessor)
    {
        _executorResolver = executorResolver;
        _tokenAccessor = tokenAccessor;
    }

    [Function("graphql")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", "post", Route = "graphql")] HttpRequest req)
    {
        // The token is stashed only so the data layer can open the SQL
        // connection as the caller. No group lookup happens here; membership is
        // resolved inside the database against the synced entitlement tables.
        _tokenAccessor.SetAccessToken(TokenExtractor.FromHeaders(req.Headers));

        var executor = await _executorResolver.GetRequestExecutorAsync();

        if (HttpMethods.IsGet(req.Method))
        {
            var query = req.Query["query"].ToString();

            if (string.IsNullOrEmpty(query))
            {
                return new ContentResult
                {
                    Content = GraphiQlPage,
                    ContentType = "text/html",
                    StatusCode = StatusCodes.Status200OK
                };
            }

            var operationName = req.Query["operationName"].ToString();
            var getRequest = OperationRequestBuilder.New()
                .SetDocument(query)
                .SetOperationName(string.IsNullOrEmpty(operationName) ? null : operationName)
                .Build();

            return Json(await executor.ExecuteAsync(getRequest));
        }

        using var reader = new StreamReader(req.Body);
        var body = await reader.ReadToEndAsync();

        var parsed = JsonSerializer.Deserialize<GraphQLRequest>(body, JsonOptions);
        if (parsed is null || string.IsNullOrEmpty(parsed.Query))
        {
            return new BadRequestObjectResult(
                new { errors = new[] { new { message = "Invalid GraphQL request." } } });
        }

        var builder = OperationRequestBuilder.New().SetDocument(parsed.Query);

        if (!string.IsNullOrEmpty(parsed.OperationName))
            builder.SetOperationName(parsed.OperationName);

        if (parsed.Variables is not null)
            builder.SetVariableValues(parsed.Variables);

        return Json(await executor.ExecuteAsync(builder.Build()));
    }

    private static ContentResult Json(IExecutionResult result) => new()
    {
        Content = result.ToJson(),
        ContentType = "application/json",
        StatusCode = StatusCodes.Status200OK
    };

    private const string GraphiQlPage = """
        <!DOCTYPE html>
        <html>
        <head>
          <title>GraphQL explorer</title>
          <link rel="stylesheet" href="https://unpkg.com/graphiql/graphiql.min.css" />
        </head>
        <body style="margin:0">
          <div id="graphiql" style="height:100vh"></div>
          <script crossorigin src="https://unpkg.com/react/umd/react.production.min.js"></script>
          <script crossorigin src="https://unpkg.com/react-dom/umd/react-dom.production.min.js"></script>
          <script crossorigin src="https://unpkg.com/graphiql/graphiql.min.js"></script>
          <script>
            const fetcher = GraphiQL.createFetcher({ url: window.location.href });
            ReactDOM.render(
              React.createElement(GraphiQL, { fetcher }),
              document.getElementById('graphiql'));
          </script>
        </body>
        </html>
        """;
}

public class GraphQLRequest
{
    public string? Query { get; set; }
    public string? OperationName { get; set; }
    public Dictionary<string, object?>? Variables { get; set; }
}
