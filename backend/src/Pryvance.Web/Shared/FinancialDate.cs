using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Pryvance.Web.Shared;

[JsonConverter(typeof(FinancialDateJsonConverter))]
public readonly record struct FinancialDate(DateOnly Value)
{
    public override string ToString() => Value.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    private sealed class FinancialDateJsonConverter : JsonConverter<FinancialDate>
    {
        public override FinancialDate Read(
            ref Utf8JsonReader reader,
            Type typeToConvert,
            JsonSerializerOptions options)
        {
            if (reader.TokenType != JsonTokenType.String ||
                !DateOnly.TryParseExact(
                    reader.GetString(),
                    "yyyy-MM-dd",
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.None,
                    out var value))
            {
                throw new JsonException("Financial date must use YYYY-MM-DD.");
            }

            return new FinancialDate(value);
        }

        public override void Write(Utf8JsonWriter writer, FinancialDate value, JsonSerializerOptions options) =>
            writer.WriteStringValue(value.ToString());
    }
}
