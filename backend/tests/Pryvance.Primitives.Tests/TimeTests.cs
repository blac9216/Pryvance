using System.Text.Json;
using Pryvance.Web.Shared;

namespace Pryvance.Primitives.Tests;

public sealed class TimeTests
{
    [Fact]
    public void FinancialDateRoundTripsWithoutAnInstantConversion()
    {
        var date = new FinancialDate(new DateOnly(2026, 3, 8));

        Assert.Equal("\"2026-03-08\"", JsonSerializer.Serialize(date));
        Assert.Equal(date, JsonSerializer.Deserialize<FinancialDate>("\"2026-03-08\""));
    }

    [Theory]
    [InlineData("\"2026-02-30\"")]
    [InlineData("\"03/08/2026\"")]
    [InlineData("\"2026-03-08T00:00:00Z\"")]
    public void InvalidFinancialDateJsonIsRejected(string json) =>
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<FinancialDate>(json));

    [Fact]
    public void UtcInstantRequiresZeroOffset()
    {
        var nonUtc = new DateTimeOffset(2026, 3, 8, 1, 30, 0, TimeSpan.FromHours(-5));

        Assert.Throws<ArgumentException>(() => new UtcInstant(nonUtc));
        Assert.Throws<JsonException>(() =>
            JsonSerializer.Deserialize<UtcInstant>("\"2026-03-08T01:30:00-05:00\""));
    }

    [Theory]
    [InlineData("\"2026-03-08Z\"")]
    [InlineData("\"12:00Z\"")]
    [InlineData("\"2026-03-08T06:30:00.Z\"")]
    public void IncompleteUtcInstantJsonIsRejected(string json) =>
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<UtcInstant>(json));

    [Theory]
    [InlineData("2026-03-08T06:30:00Z", "2026-03-08T06:30:00.0000000Z")]
    [InlineData("2026-03-08T06:30:00.1Z", "2026-03-08T06:30:00.1000000Z")]
    [InlineData("2026-03-08T06:30:00.12Z", "2026-03-08T06:30:00.1200000Z")]
    [InlineData("2026-03-08T06:30:00.123Z", "2026-03-08T06:30:00.1230000Z")]
    [InlineData("2026-03-08T06:30:00.1234Z", "2026-03-08T06:30:00.1234000Z")]
    [InlineData("2026-03-08T06:30:00.12345Z", "2026-03-08T06:30:00.1234500Z")]
    [InlineData("2026-03-08T06:30:00.123456Z", "2026-03-08T06:30:00.1234560Z")]
    [InlineData("2026-03-08T06:30:00.1234567Z", "2026-03-08T06:30:00.1234567Z")]
    public void CompleteUtcInstantJsonRoundTrips(string input, string serialized)
    {
        var instant = JsonSerializer.Deserialize<UtcInstant>($"\"{input}\"");

        Assert.Equal($"\"{serialized}\"", JsonSerializer.Serialize(instant));
    }

    [Fact]
    public void SourceTimestampRoundTripRetainsUtcInstantAndTimezoneMetadata()
    {
        var timestamp = new SourceTimestamp(
            new UtcInstant(new DateTimeOffset(2026, 3, 8, 6, 30, 0, TimeSpan.Zero)),
            new SourceTimeZoneId("America/New_York"));

        var json = JsonSerializer.Serialize(timestamp);
        var roundTrip = JsonSerializer.Deserialize<SourceTimestamp>(json);

        Assert.Equal(timestamp, roundTrip);
        Assert.Contains("2026-03-08T06:30:00.0000000Z", json);
        Assert.Contains("America/New_York", json);
    }
}
