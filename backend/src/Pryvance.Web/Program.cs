using Pryvance.Web.Infrastructure.Persistence;
using Pryvance.Web.Modules.Platform;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddPryvancePersistence(builder.Configuration);

var app = builder.Build();

await app.InitializePryvancePersistenceAsync();

app.UseDefaultFiles();
app.UseStaticFiles();

app.MapPlatformModule();

app.Map("/api/{**path}", () => Results.Problem(
    statusCode: StatusCodes.Status404NotFound,
    title: "Not Found"));

app.MapFallbackToFile("index.html");

app.Run();
