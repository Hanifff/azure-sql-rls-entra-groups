namespace GraphqlServer.Services;

/// <summary>
/// Carries the caller's Entra token from the HTTP trigger to the data layer.
/// </summary>
/// <remarks>
/// HotChocolate resolves GraphQL fields on its own execution pipeline rather
/// than on the request thread, so the usual IHttpContextAccessor route does not
/// reach them. AsyncLocal follows the async flow instead, which does.
/// </remarks>
public interface ITokenAccessor
{
    string? GetAccessToken();
    void SetAccessToken(string? token);
}

/// <inheritdoc cref="ITokenAccessor"/>
public class ScopedTokenHolder : ITokenAccessor
{
    private static readonly AsyncLocal<string?> Current = new();

    public string? GetAccessToken() => Current.Value;

    public void SetAccessToken(string? token) => Current.Value = token;
}
