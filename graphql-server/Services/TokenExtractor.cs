using Microsoft.AspNetCore.Http;

namespace GraphqlServer.Services;

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
    public static string? FromHeaders(IHeaderDictionary headers)
    {
        var forwarded = headers["X-SQL-ACCESS-TOKEN"].FirstOrDefault();
        if (!string.IsNullOrEmpty(forwarded)) return forwarded;

        var authorization = headers["Authorization"].FirstOrDefault();
        if (!string.IsNullOrEmpty(authorization) &&
            authorization.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
        {
            return authorization[7..];
        }

        return null;
    }
}
