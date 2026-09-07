using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Pryvance.Web.Shared;

[JsonConverter(typeof(UtcInstantJsonConverter))]
public readonly record struct UtcInstant
{
    private static readonly string[] Rfc3339UtcFormats =
    [
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'",
    ];

    public UtcInstant(DateTimeOffset value)
    {
        if (value.Offset != TimeSpan.Zero)
        {
            throw new ArgumentException("A UTC instant must have a zero offset.", nameof(value));
        }

        Value = value;
    }

    public DateTimeOffset Value { get; }

    public override string ToString() =>
        Value.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", CultureInfo.InvariantCulture);

    private sealed class UtcInstantJsonConverter : JsonConverter<UtcInstant>
    {
        public override UtcInstant Read(
            ref Utf8JsonReader reader,
            Type typeToConvert,
            JsonSerializerOptions options)
        {
            var text = reader.TokenType == JsonTokenType.String ? reader.GetString() : null;
            if (text is null ||
                !DateTimeOffset.TryParseExact(
                    text,
                    Rfc3339UtcFormats,
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                    out var value))
            {
                throw new JsonException("UTC instant must be an RFC 3339 timestamp ending in Z.");
            }

            return new UtcInstant(value);
        }

        public override void Write(Utf8JsonWriter writer, UtcInstant value, JsonSerializerOptions options) =>
            writer.WriteStringValue(value.ToString());
    }
}

[JsonConverter(typeof(SourceTimeZoneIdJsonConverter))]
public readonly record struct SourceTimeZoneId
{
    public SourceTimeZoneId(string value)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(value);
        if (value.Length > 255 || value.Any(char.IsControl))
        {
            throw new ArgumentException("Source timezone metadata is invalid.", nameof(value));
        }

        Value = value;
    }

    public string Value { get; }

    public override string ToString() => Value;

    private sealed class SourceTimeZoneIdJsonConverter : JsonConverter<SourceTimeZoneId>
    {
        public override SourceTimeZoneId Read(
            ref Utf8JsonReader reader,
            Type typeToConvert,
            JsonSerializerOptions options)
        {
            if (reader.TokenType != JsonTokenType.String)
            {
                throw new JsonException("Source timezone metadata must be a string.");
            }

            try
            {
                return new SourceTimeZoneId(reader.GetString()!);
            }
            catch (ArgumentException exception)
            {
                throw new JsonException("Source timezone metadata is invalid.", exception);
            }
        }

        public override void Write(Utf8JsonWriter writer, SourceTimeZoneId value, JsonSerializerOptions options) =>
            writer.WriteStringValue(value.Value);
    }
}

public readonly record struct SourceTimestamp(UtcInstant Instant, SourceTimeZoneId? SourceTimeZone);
