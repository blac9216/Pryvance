# ADR-0015: Preserve native money and derive reporting-currency values

Status: Proposed
Date: 2026-09-06

## Context

Pryvance must support USD as the Household's likely default while retaining EUR, JPY and other foreign-currency Accounts/transactions/Assets. Cross-currency card purchases and transfers can have an original economic amount, an actual account settlement amount, provider fees, and a market/reference FX rate that are all legitimately different facts.

Overwriting foreign source values with a converted USD value would destroy evidence and make historical reporting/provider reconciliation inaccurate. Using only a market reference rate would also misstate transactions where the bank/card's actual settlement amount is known.

## Decision Drivers

- Preserve exact native source/account values.
- Support configurable Household home/reporting currency and per-report override.
- Use actual settlement economics when known.
- Use sourced historical/current FX rates when conversion is required.
- Support foreign-currency balance valuation over time.
- Make conversion basis/provenance visible and auditable.

## Considered Options

1. **Native Money + actual FX/settlement facts + sourced reference rates + derived reporting values** — accurate and auditable; adds rate/provider/calculation metadata.
2. **Convert everything to USD at ingestion** — simple analytics; destroys native truth and makes future reporting currency changes inaccurate.
3. **Store native values but use one current FX rate for all reporting** — easy; distorts historical transactions and tax/period analysis.

## Decision

Pryvance will preserve every native Money observation and derive reporting-currency values separately. Household settings define a default/home reporting currency, and individual reports/calculations may override it.

When a linked actual settlement amount exists in the reporting currency, calculations prefer that observed economic cash impact where appropriate. Otherwise Pryvance uses a sourced FX Rate Observation for the relevant financial/effective date according to an explicit conversion policy. Current foreign-currency balances are revalued from current/latest sourced rates without mutating the native balance.

Cross-currency events may contain multiple native Account Entries and need not have one universal scalar event amount. Economically allocatable events may maintain a separate original/economic allocation basis.

## Consequences

- A EUR purchase settling on a USD card preserves both EUR original and USD card impact.
- A USD↔JPY transfer preserves both Account Entries and actual/reference FX evidence without becoming spending.
- Changing the default reporting currency does not rewrite history.
- FX rate providers remain replaceable adapters; OANDA or another source may be configured without changing domain semantics.
- Reporting/calculation outputs must expose conversion/rate basis and Coverage/staleness where material.
