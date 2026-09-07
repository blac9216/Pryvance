using Pryvance.Web.Modules.Platform;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.UseDefaultFiles();
app.UseStaticFiles();

app.MapPlatformModule();

app.MapFallbackToFile("index.html");

app.Run();
