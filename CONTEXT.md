# CONTEXT.md — glossary

The canonical vocabulary of Pryvance. One entry per domain term; implementation details belong in the design set.

## Terms

**Household** — the collaboration boundary that groups people, shared obligations, shared accounts, and shared reporting. Not: family account, tenant.

**Party** — a person or financial entity that can own, fund, benefit from, owe, or receive value. Not: user, member account.

**Person** — a human party, including adults and children, whether or not that person has connected financial accounts. Not: user.

**Financial Entity** — a non-person party used to model an economic scope such as a rental property or future business. Not: category, account.

**Account** — a financial account whose ownership, visibility, source coverage, and activity are tracked independently. Not: wallet.

**Financial Event** — a normalized movement or economic event such as expense, income, transfer, contribution, distribution, reimbursement, settlement, refund, or investment activity. Not: bank row, purchase.

**Source Record** — immutable data as received from a provider, file import, document, email, or capture process before interpretation. Not: transaction.

**Allocation** — attribution of some or all of a financial event to a category, beneficiary, person, or financial entity. Not: split payment.

**Obligation** — an amount one party is responsible for settling with another party or shared scope. Not: debt account, transaction.

**Settlement** — a financial event that reduces or clears an obligation without creating new income or spending. Not: reimbursement income.

**Contribution** — value supplied by a party toward a household funding plan, including approved credits for qualifying personally funded shared expenses. Not: transfer.

**Household Funding Plan** — the rule set that determines shared funding targets, contribution methods, reserves, savings, and buffers for a period. Not: budget.

**Budget** — a time-versioned spending or saving target for categories and scopes. Not: funding plan.

**Evidence** — a source artifact or source record that supports a financial fact, match, balance, extraction, or interpretation. Not: attachment.

**Provenance** — metadata that records where a financial fact came from, how it was derived, confidence, and verification state. Not: audit log.

**Receipt** — evidence of a purchase that may contain merchant, payment, totals, and line-item facts. Not: transaction.

**Document** — immutable financial source material such as a W-2, statement, tax return, lease, invoice, or policy. Not: receipt.

**Review Item** — an unresolved uncertainty that requires user judgment before a derived result becomes trusted. Not: notification.

**Rule** — deterministic user- or system-defined matching logic that normalizes or classifies financial data. Not: AI prompt.

**Reporting Scope** — the selected party or household view used to constrain aggregates and analytics. Not: account filter.

**Visibility Policy** — the permissions that determine whether data may be viewed in detail, included in aggregates, or used in shared calculations. Not: account ownership.

**Coverage** — the known completeness of source data for a scope, account, date range, or fact family. Not: confidence.

**Known Net Worth** — net worth computed only from tracked data, explicitly marked when coverage is incomplete. Not: household net worth.
