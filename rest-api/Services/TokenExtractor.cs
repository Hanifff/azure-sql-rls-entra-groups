using Microsoft.Azure.Functions.Worker.Http;

namespace RestApiServer.Services;

/// <summary>
/// Pulls the caller's Entra access token out of the request.
/// </summary>
public static class TokenExtractor
{
    /// <summary>
    /// APIM forwards the validated token in X-SQL-ACCESS-TOKEN. Authorization is
    /// the fallback for calling the Function App directly, which is useful when
    /// testing without the gateway in front.
    /// </summary>
    public static string? FromRequest(HttpRequestData request)
    {
        if (request.Headers.TryGetValues("X-SQL-ACCESS-TOKEN", out var forwarded))
        {
            var token = forwarded.FirstOrDefault();
            if (!string.IsNullOrEmpty(token)) return token;
        }

        if (request.Headers.TryGetValues("Authorization", out var authorization))
        {
            var header = authorization.FirstOrDefault();
            if (!string.IsNullOrEmpty(header) &&
                header.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            {
                return header[7..];
            }
        }

        return null;
    }
}
