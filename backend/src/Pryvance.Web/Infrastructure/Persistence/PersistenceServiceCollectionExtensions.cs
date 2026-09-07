using Microsoft.EntityFrameworkCore;

namespace Pryvance.Web.Infrastructure.Persistence;

public static class PersistenceServiceCollectionExtensions
{
    private const string ConnectionStringName = "Pryvance";

    public static IServiceCollection AddPryvancePersistence(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        var connectionString = configuration.GetConnectionString(ConnectionStringName)
            ?? throw new InvalidOperationException(
                $"Connection string 'ConnectionStrings:{ConnectionStringName}' is required.");

        services.AddDbContext<PryvanceDbContext>(options => options.UseNpgsql(connectionString));
        return services;
    }

    public static async Task InitializePryvancePersistenceAsync(this WebApplication app)
    {
        await using var scope = app.Services.CreateAsyncScope();
        var database = scope.ServiceProvider.GetRequiredService<PryvanceDbContext>().Database;
        await database.MigrateAsync();
        await database.ExecuteSqlRawAsync("SELECT 1");
    }
}
