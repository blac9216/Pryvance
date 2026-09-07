namespace Pryvance.Web.Modules.Platform;

public static class PlatformModule
{
    public static IEndpointRouteBuilder MapPlatformModule(this IEndpointRouteBuilder endpoints)
    {
        endpoints.MapGroup("/api/v1")
            .MapGet("/health", () => Results.Ok(new
            {
                status = "ok",
                version = "1.0.0"
            }));

        return endpoints;
    }
}
