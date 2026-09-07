using Microsoft.EntityFrameworkCore;

namespace Pryvance.Web.Infrastructure.Persistence;

public sealed class PryvanceDbContext(DbContextOptions<PryvanceDbContext> options)
    : DbContext(options);
