using System.Text.Json;
using Pryvance.Web.Shared;

namespace Pryvance.Primitives.Tests;

public sealed class MoneyTests
{
    [Fact]
    public void DecimalArithmeticRetainsPrecision()
    {
        var value = new Money(0.1m + 0.2m, "USD");

        Assert.Equal(0.3m, value.Amount);
    }

    [Fact]
    public void JsonUsesDecimalStringAndCurrencyShape()
    {
        var json = JsonSerializer.Serialize(new Money(187.43m, "USD"));

        Assert.Equal("{\"amount\":\"187.43\",\"currency\":\"USD\"}", json);
        Assert.Equal(new Money(187.43m, "USD"), JsonSerializer.Deserialize<Money>(json));
    }

    [Theory]
    [InlineData("usd")]
    [InlineData("US")]
    [InlineData("US1")]
    [InlineData("ZZZ")]
    public void InvalidCurrencyIsRejected(string currency) =>
        Assert.Throws<ArgumentException>(() => new Money(1m, currency));

    [Theory]
    [InlineData("{\"amount\":0.1,\"currency\":\"USD\"}")]
    [InlineData("{\"amount\":\"1e2\",\"currency\":\"USD\"}")]
    [InlineData("{\"amount\":\"1.00\",\"currency\":\"usd\"}")]
    public void InvalidJsonIsRejected(string json) =>
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<Money>(json));
}
