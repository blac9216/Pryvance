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

    [Theory]
    [InlineData("0.00000000000000000000000000001")]
    [InlineData("1234567890123456789012345678.91")]
    [InlineData("79228162514264337593543950336")]
    public void InexactOrOverflowingDecimalStringsAreRejected(string amount) =>
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<Money>(
            $"{{\"amount\":\"{amount}\",\"currency\":\"USD\"}}"));

    [Theory]
    [InlineData("79228162514264337593543950335", "79228162514264337593543950335")]
    [InlineData("-79228162514264337593543950335", "-79228162514264337593543950335")]
    [InlineData("0.0000000000000000000000000001", "0.0000000000000000000000000001")]
    [InlineData("1.23000000000000000000000000000", "1.2300000000000000000000000000")]
    public void ExactDecimalBoundariesAndTrailingZerosRoundTrip(string amount, string serializedAmount)
    {
        var money = JsonSerializer.Deserialize<Money>(
            $"{{\"amount\":\"{amount}\",\"currency\":\"USD\"}}");

        Assert.Equal($"{{\"amount\":\"{serializedAmount}\",\"currency\":\"USD\"}}", JsonSerializer.Serialize(money));
    }
}
