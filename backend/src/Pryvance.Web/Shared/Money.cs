using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Pryvance.Web.Shared;

[JsonConverter(typeof(MoneyJsonConverter))]
public readonly record struct Money
{
    private static readonly HashSet<string> CurrencyCodes = CultureInfo
        .GetCultures(CultureTypes.SpecificCultures)
        .Select(culture => new RegionInfo(culture.Name).ISOCurrencySymbol)
        .ToHashSet(StringComparer.Ordinal);

    public Money(decimal amount, string currency)
    {
        Amount = amount;
        Currency = ValidateCurrency(currency);
    }

    public decimal Amount { get; }

    public string Currency { get; }

    private static string ValidateCurrency(string currency)
    {
        ArgumentNullException.ThrowIfNull(currency);

        if (currency.Length != 3 ||
            currency.Any(character => character is < 'A' or > 'Z') ||
            !CurrencyCodes.Contains(currency))
        {
            throw new ArgumentException(
                "Currency must be a three-letter uppercase ISO currency code.",
                nameof(currency));
        }

        return currency;
    }

    private sealed class MoneyJsonConverter : JsonConverter<Money>
    {
        public override Money Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        {
            if (reader.TokenType != JsonTokenType.StartObject)
            {
                throw new JsonException("Money must be a JSON object.");
            }

            string? amountText = null;
            string? currency = null;

            while (reader.Read() && reader.TokenType != JsonTokenType.EndObject)
            {
                if (reader.TokenType != JsonTokenType.PropertyName)
                {
                    throw new JsonException("Invalid Money JSON.");
                }

                var propertyName = reader.GetString();
                if (!reader.Read() || reader.TokenType != JsonTokenType.String)
                {
                    throw new JsonException($"Money property '{propertyName}' must be a string.");
                }

                switch (propertyName)
                {
                    case "amount" when amountText is null:
                        amountText = reader.GetString();
                        break;
                    case "currency" when currency is null:
                        currency = reader.GetString();
                        break;
                    default:
                        throw new JsonException($"Unknown or duplicate Money property '{propertyName}'.");
                }
            }

            const NumberStyles allowedAmountStyles =
                NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint;

            if (amountText is null ||
                !decimal.TryParse(amountText, allowedAmountStyles, CultureInfo.InvariantCulture, out var amount) ||
                NormalizeDecimal(amountText) !=
                    NormalizeDecimal(amount.ToString(CultureInfo.InvariantCulture)))
            {
                throw new JsonException("Money amount must be an invariant decimal string.");
            }

            try
            {
                return new Money(amount, currency ?? throw new JsonException("Money currency is required."));
            }
            catch (ArgumentException exception)
            {
                throw new JsonException("Money currency is invalid.", exception);
            }
        }

        private static string NormalizeDecimal(string text)
        {
            var isNegative = text.StartsWith('-');
            var unsignedText = text.TrimStart('+', '-');
            var decimalPoint = unsignedText.IndexOf('.');
            var scale = decimalPoint < 0 ? 0 : unsignedText.Length - decimalPoint - 1;
            var digits = unsignedText.Replace(".", string.Empty, StringComparison.Ordinal)
                .TrimStart('0');

            while (scale > 0 && digits.EndsWith('0'))
            {
                digits = digits[..^1];
                scale--;
            }

            return digits.Length == 0 ? "0" : $"{(isNegative ? "-" : string.Empty)}{digits}:{scale}";
        }

        public override void Write(Utf8JsonWriter writer, Money value, JsonSerializerOptions options)
        {
            if (value.Currency is null)
            {
                throw new JsonException("Money currency is required.");
            }

            writer.WriteStartObject();
            writer.WriteString("amount", value.Amount.ToString(CultureInfo.InvariantCulture));
            writer.WriteString("currency", value.Currency);
            writer.WriteEndObject();
        }
    }
}
