using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using GraphqlServer.Services;
using GraphqlServer.GraphQL;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();

var sqlConnectionString = Environment.GetEnvironmentVariable("SqlConnectionString")
    ?? throw new InvalidOperationException("SqlConnectionString app setting is required.");

builder.Services.AddHttpContextAccessor();
builder.Services.AddScoped<ITokenAccessor, ScopedTokenHolder>();
builder.Services.AddSingleton(new SqlDataService(sqlConnectionString));

// Configure GraphQL with HotChocolate
builder.Services
    .AddGraphQLServer()
    .AddQueryType<Query>()
    .AddFiltering()
    .AddSorting()
    .DisableIntrospection(false)  // Enable introspection for schema export
    .ModifyRequestOptions(opt => opt.IncludeExceptionDetails = true);

builder.Services
    .AddApplicationInsightsTelemetryWorkerService()
    .ConfigureFunctionsApplicationInsights();

var app = builder.Build();

app.Run();
