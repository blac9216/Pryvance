# Wealth, records, insurance, property, and tax

Kind: explanation

This document defines the target-state model for long-lived financial records and wealth analysis. The same evidence/provenance principles used by the ledger apply to investments, property, insurance, payroll, and tax.

## Wealth composition

Known Net Worth is derived from canonical economic items reachable through effective ownership relationships:

- cash and financial Accounts;
- investment positions;
- Assets such as real estate;
- economically realizable Insurance Policy values;
- liabilities such as mortgages, loans, and policy loans;
- manually observed assets/liabilities where Coverage is explicit.

A Person's net worth may include indirect ownership through a Financial Entity. Example:

```text
Alex -> 100% Rental LLC
Rental LLC -> 100% 123 Main Street
Rental LLC -> checking account
Rental LLC -> mortgage liability
```

Alex's attributable wealth includes the net economic value of the LLC's underlying items. The property is not counted again if it also appears directly in a property dashboard. Aggregation traverses canonical item IDs and ownership paths, detects cycles, and deduplicates the same economic item.

Partial ownership applies proportionally:

```text
Alex 60% -> Family LLC <- 40% Jordan
Family LLC -> Asset / Account / Liability
```

Ownership relationships are effective-dated so historical net-worth attribution can be reconstructed.

## Assets and valuations

Asset is separate from Financial Entity. An Asset may have:

- type;
- name/description;
- owner relationships;
- Economic Scope;
- acquisition/disposition facts;
- valuation observations;
- linked Evidence/Documents;
- liabilities;
- Coverage.

Valuation Observation records amount, currency, effective date, source, methodology/type, and Provenance. A manual estimate, appraisal, provider valuation, property-tax assessment, and market estimate can coexist rather than overwrite one another.

Reports select an appropriate valuation policy and expose source/staleness.

## Investment accounts and instruments

Investment Accounts participate in the normal Account/ownership/visibility model while adding investment-specific facts.

### Security / Instrument

Canonical identity independent of provider naming. Fields may include:

- name;
- ticker where applicable;
- identifiers such as CUSIP/ISIN when available;
- asset class/subclass;
- currency;
- exchange/market metadata;
- status/reference source.

Provider-specific symbols map to the canonical Security.

### Investment transactions

Supported target-state activity includes:

- contribution;
- employer contribution;
- buy;
- sell;
- dividend;
- interest;
- fee;
- distribution;
- rollover;
- transfer;
- reinvestment;
- supported corporate actions/adjustments.

Investment cash movement remains linked to Financial Events/Account Entries so a checking-to-IRA contribution does not become Household spending.

### Position and valuation snapshots

A Position Snapshot records Security, quantity, market value, source, and as-of time. Price Observations record price/currency/source separately so a valuation can be reproduced.

Provider balance/holding feeds, statements, and manual observations may overlap. Reconciliation chooses an authoritative/selected observation without deleting alternatives.

### Cost basis and tax lots

Tax Lot and cost-basis data are modeled when known. Coverage may be:

- complete;
- partial;
- unavailable;
- statement-derived;
- provider-derived;
- manually verified.

Pryvance does not infer unknown basis as zero.

### Performance analytics

Every investment-performance result exposes methodology and data sufficiency. Potential methods include:

- simple gain/loss;
- income return;
- money-weighted return / XIRR;
- time-weighted return when required valuation/cash-flow coverage exists.

If history is incomplete, the result is marked partial/unavailable instead of publishing a misleading precise return.

## Retirement and beneficiary accounts

Ownership and beneficiary are separate. This supports:

- 401(k)/IRA/Roth IRA owned by a Person;
- HSA investment accounts;
- 529/custodial accounts where owner and beneficiary differ;
- joint taxable brokerage;
- future trust-owned investment accounts.

Household/Person analytics respect Visibility Policy. A spouse can share only balance/contribution facts while holdings remain private if desired.

## Insurance policies

Insurance Policy is a first-class Household record even when it contributes no current asset value.

General facts include:

- policy type;
- owner Party;
- insured Party/Parties;
- beneficiaries;
- carrier;
- masked policy identifier;
- issue/effective dates;
- status;
- premium schedule/history;
- coverage amounts;
- linked External Connection where available;
- Documents and extracted facts.

Target policy classes may include whole/permanent life, term life, disability, long-term care, property, auto, umbrella, and other Household-relevant coverage.

### Permanent/whole-life value

Permanent policies may additionally track:

- current cash value;
- cash surrender value;
- death benefit;
- premiums/cost basis where known;
- dividend option/history;
- paid-up additions;
- policy loan balance and interest;
- guaranteed/non-guaranteed values;
- surrender charges where applicable.

Cash surrender/economically realizable value may contribute to Known Net Worth under the selected valuation policy. Death benefit is coverage, not a current asset.

Policy loans are modeled as liabilities/economic offsets and must not be hidden by showing gross cash value alone.

### Policy illustrations

Policy Illustration is immutable evidence plus structured projected values by policy year/date. It records illustration date, assumptions/version, guaranteed vs non-guaranteed series, and source Document.

Pryvance can compare actual observations with prior illustrations, for example actual cash value versus projected cash value at the same policy year. Projections never become observed wealth.

### Insurance discovery

A recurring payment to an insurance Merchant with no linked Policy may generate a Review/suggestion to add or associate a Policy. Classification alone does not invent policy terms.

## Property and rental assets

Real Estate Property is an Asset specialization, not automatically a Financial Entity.

Property facts may include:

- address/location;
- ownership;
- acquisition/disposition;
- valuation observations;
- leases;
- mortgages/liabilities;
- insurance policies;
- property tax;
- HOA/management facts;
- Documents and Evidence;
- rental Economic Scope.

A Financial Entity such as an LLC may own the Property. One entity may own multiple Properties.

## Rental accounting projection

Rental reporting is a projection over the shared ledger and Asset model. It does not maintain a separate transaction universe.

Relevant classifications include:

- rental income;
- operating expenses;
- management fees;
- utilities;
- insurance;
- taxes;
- HOA;
- repairs;
- owner-funded costs/contributions;
- capital-improvement candidates;
- security-deposit liability movements;
- mortgage principal;
- mortgage interest;
- escrow components where known.

Security deposits remain liabilities unless an actual event changes their treatment. Mortgage principal reduces liability rather than becoming expense. Repair/capital and other tax-sensitive treatment remains reviewable.

## Mortgage and liability evidence

Mortgage statements may produce structured facts for:

- opening/closing principal;
- principal paid;
- interest paid;
- escrow paid;
- taxes/insurance disbursements where available;
- payment due/status;
- rate/term metadata.

These facts can reconcile with checking Account Entries and improve property cash-flow and tax reporting.

## Records vault

The Records subsystem stores source evidence for the full Household financial history.

Document types may include:

- tax forms and returns;
- pay stubs;
- bank/brokerage/retirement statements;
- mortgage statements;
- insurance policies/statements/illustrations;
- leases;
- invoices;
- property-tax bills;
- closing documents;
- appraisal/valuation evidence;
- receipts;
- other financial records.

Original Stored Objects are immutable and content-hashed. Structured extracted facts are separate records.

## Extracted facts and multiple evidence

Extracted Fact records a semantic field/value plus:

- source evidence;
- page/field/location where applicable;
- extractor/parser/model version;
- confidence;
- verification state;
- effective date;
- knowledge date.

More than one source may support the same fact. Example: annual mortgage interest may be supported by a 1098 and the sum of monthly statements. Pryvance preserves both and can reconcile differences.

## Payroll intelligence

Payroll is a structured record family because it connects cash flow, retirement, tax, and Household funding.

Pay-stub extraction may include:

- employer;
- pay period/pay date;
- gross pay;
- taxable wage bases where available;
- federal/state/local withholding;
- payroll taxes;
- pre/post-tax deductions;
- employee retirement contributions;
- employer match/contributions;
- benefit deductions/contributions;
- net pay.

Net pay can match/reconcile to a checking deposit. Retirement contributions can reconcile to investment activity/statement evidence. W-2 values provide year-end evidence that may refine earlier payroll totals.

## Tax Filing Context

A Tax Filing Context is year-specific and defines filing collaboration/visibility independent of normal Household account sharing.

### Joint

Participants intend to prepare a joint return. Authorized preparer(s) can access required tax documents/facts assigned to either participant within that filing context, even if ordinary account/transaction visibility is narrower.

This grant is limited to tax preparation context and does not make the person's unrelated spending globally visible.

### Individual

Each Person's tax evidence remains private unless otherwise shared. Selected extracted facts may still be authorized for Household calculation use—for example annual wages used to reconcile shared-funding fairness—without exposing the W-2 or field detail to the other Person.

## Tax workspace capabilities

The target Tax workspace is an evidence/organization/analysis companion, not tax-return preparation or e-filing software.

Capabilities include:

- expected-document checklist by filing context;
- missing-document alerts;
- known-form extraction for selected forms;
- historical document comparison;
- tax-year receipt/document search;
- potential itemization/support discovery;
- rental Schedule-E-style organization;
- investment/interest/dividend evidence organization;
- payroll/W-2 reconciliation;
- candidate tax classifications requiring verification;
- evidence-linked AI questions;
- accountant/tax-preparer export package.

## Accountant export

A filing-context export may produce a ZIP/package containing only authorized tax materials such as:

- source tax Documents;
- selected receipts/supporting documents;
- generated summaries;
- evidence/provenance index;
- missing/incomplete-data report;
- optional CSV/JSON machine-readable facts.

Exports are audited and governed by Tax Filing Context access. Private non-tax records are not included merely because they exist in the Household database.

## AI tax companion

AI may help answer questions grounded in authorized records, such as locating documents, summarizing amounts, or explaining where evidence came from. The model receives redacted/minimum context by default and cannot make final tax-treatment decisions or claim the workspace has prepared a valid return.

Example product behavior:

- accountant asks for a prior-year property-tax amount;
- Pryvance finds the relevant Document/fact and returns the value with evidence;
- user asks what records support an itemized-expense category;
- Pryvance groups candidates and links to receipts;
- missing evidence remains explicitly missing rather than inferred.

## Retention and deletion

Default retention for original Records is indefinite.

Settings may define explicit retention by document class/age. Deletion requires an authorization check and warning because:

- source evidence/provenance may weaken;
- extracted facts may become unsupported depending on policy;
- historical encrypted backups may still contain the deleted object until those recovery points expire.

Deletion from the live system therefore does not claim immediate erasure from all retained backups.
