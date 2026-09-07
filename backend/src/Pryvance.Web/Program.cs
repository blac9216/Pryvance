using Pryvance.Web.Modules.Platform;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.UseDefaultFiles();
app.UseStaticFiles();

app.MapPlatformModule();

app.Map("/api/{**path}", () => Results.Problem(
    statusCode: StatusCodes.Status404NotFound,
    title: "Not Found"));

app.MapFallbackToFile("index.html");

app.Run();
