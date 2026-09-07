# Future feature opportunities

Kind: explanation

This document preserves long-range product opportunities that are intentionally **outside the approved target architecture and delivery roadmap**. It exists so future planning can reconstruct why an idea fit Pryvance, what present-day capabilities it depended on, and where the architectural boundary was expected to sit.

Nothing here is a release commitment. Before promoting any item into the target architecture, re-run market, legal/regulatory, provider/API, privacy, security, and feasibility research; interrogate the owner; then update the durable design set and roadmap through the normal planning/design process.

## Product filter

Pryvance is most differentiated when a feature becomes materially better because the system already has the Household's reconciled financial truth, Evidence/Provenance, selective sharing, records, planning data, ownership graph, and durable history.

A useful long-range framing is a **private household financial operating system** or **private digital family office for a household**: a system that can explain not only what the Household owns, owes, earns, spends, insures, plans, and files, but also what evidence supports those conclusions and who is allowed to see or disclose it.

Prefer future features that compound that data advantage. Prefer integrations over expanding Pryvance into a regulated or operationally distinct business such as banking, brokerage execution, payroll processing, full business accounting, or maintaining a first-party tax-compliance engine.

## Promotion rules

Before implementing any opportunity below:

1. Revalidate the user problem and competing products.
2. Revalidate all named vendors and API capabilities; vendor examples in this document are observations, not permanent dependencies.
3. Decide whether the feature belongs in Pryvance's canonical domain or should remain an External Connection/provider capability.
4. Define Coverage, Evidence/Provenance, authorization, Audit, recovery, and Calculation Run behavior before analytics depends on the new data family.
5. Prefer a provider-neutral interface when multiple interchangeable external services could supply the capability.
6. Do not let a future feature weaken the current rule that uncertain or incomplete financial data is represented explicitly rather than silently inferred.

---

## 1. Provider-neutral tax preparation and filing

### Intent

Extend the planned Tax workspace from evidence organization/accountant export into an experience where a Household can prepare and, where supported, file a return from Pryvance while delegating tax-law calculation, return generation, regulatory compliance, and e-file transmission to an external tax provider.

The desired user experience is **"do taxes in Pryvance; use a filing provider as the compliance engine"**, not "export data and start over in a tax website."

### Why it fits

The approved architecture already intends to know much of the high-value source material required for an individual return:

- Tax Filing Context and filing-specific authorization;
- W-2/1099/1098-style Documents and Extracted Facts;
- payroll and withholding history;
- investment transactions, Tax Lots, dividends and interest;
- mortgage/property evidence;
- rental income/expense organization;
- receipts and supporting Documents;
- dependents/People and Household relationships;
- prior returns and other retained Records.

Pryvance can therefore own **financial truth, evidence quality, completeness, authorization, and disclosure**, while the filing provider owns the volatile tax-law/compliance layer.

### Core architectural boundary

Pryvance should own:

- taxpayer/Household identity facts already present in the authorized Tax Filing Context;
- canonical tax-relevant financial facts and their Evidence/Provenance;
- document/fact completeness and reconciliation;
- user-confirmed answers that are useful beyond a single provider session;
- an explicit disclosure preview showing exactly what will be sent to the provider;
- provider connection/session state;
- Audit of every disclosure and filing action;
- returned filing artifacts, acknowledgements, and final return Documents as immutable Evidence.

The filing provider should own:

- current-year federal/state tax-law rules;
- tax calculation and form-selection logic;
- provider-specific eligibility constraints;
- authoritative return generation;
- e-file schemas/business rules and transmission;
- IRS/state acceptance/rejection handling that legally belongs to the transmitter/provider;
- provider-required identity, signature, consent, payment/refund, or compliance screens.

Pryvance should **not** become the authoritative tax calculation engine merely to make the UI look native.

### Capability-based provider abstraction

Model a generic `TaxFilingProvider` rather than permanent vendor-specific domain concepts. A provider adapter should advertise capabilities rather than being assumed to support a fixed full workflow.

Illustrative capabilities:

- `tax-facts-import`
- `document-upload`
- `provider-hosted-interview`
- `embedded-interview`
- `calculation`
- `return-preview`
- `federal-efile`
- `state-efile`
- `extension-filing`
- `amendments`
- `filing-status`
- `filed-return-download`

Illustrative operations:

```text
CreateFilingSession
SendTaxFacts
SendDocuments
GetRequirements
SubmitRequirementAnswer
Calculate
GetReturnPreview
Submit
GetFilingStatus
GetFiledArtifacts
```

Do not force every provider into every operation. The application flow should branch from advertised capabilities.

### Provider classes observed during 2026 research

These names are examples only and **must be revalidated before implementation**.

- TurboTax and H&R Block exposed partner/import paths oriented around bringing supported tax data into their tax-preparation experiences. At research time, no public general-purpose API was verified that allowed Pryvance to headlessly drive the entire preparation, calculation, signature, and e-file lifecycle.
- April and Column Tax represented the more useful architectural class: tax platforms marketed for embedded/API-driven tax preparation and filing.

The durable distinction is therefore not vendor name; it is **import-only/hand-off provider versus embedded full-lifecycle provider**.

A future TurboTax/H&R Block-style adapter could still be useful if it can prefill supported information and transfer the user to the provider for completion. An April/Column-style adapter could support a substantially more native Pryvance flow.

### Canonical facts versus provider questions

Do not create a canonical Pryvance model for every question any tax vendor might ask. That would pull provider/tax-law churn into the domain.

Pryvance should canonicalize facts it independently knows, for example:

- wages;
- federal/state/local withholding;
- retirement and HSA contributions;
- interest/dividend income;
- capital transactions and known cost basis;
- mortgage interest;
- property taxes;
- rental income/expenses;
- charitable/supporting contributions;
- dependents and filing participants.

Provider-specific questions that remain unanswered should return as session-scoped `Provider Requirement` records containing the prompt/type/allowed responses/sensitivity/required status/provider reference. Pryvance may render and collect those answers without pretending the underlying tax semantics are part of its stable domain.

### Privacy model

Before sending any information, the user should be able to review an explicit disclosure manifest for the Tax Filing Context: facts, Documents, participants, destinations, purpose, and excluded private records. Sharing for tax filing must not broaden ordinary Household visibility.

This feature should be one of the strongest demonstrations of purpose-aware authorization: Pryvance can disclose exactly what is needed for a filing without exposing unrelated private financial activity.

### Regulatory/maintenance rationale

At research time, IRS Modernized e-File used tax-year/versioned XML schemas, business rules, and Assurance Testing System requirements, with multiple schema/business-rule versions potentially active during a year. State returns add their own structures/rules. That volatility is the primary reason Pryvance should delegate authoritative calculation/transmission rather than own a native e-file engine.

Revalidate against current IRS/state requirements before implementation.

### Likely dependencies

- Phase 1 identity, authorization, Audit, Evidence/Provenance;
- Phase 5 Records/extraction/payroll;
- Phase 6 investments/Tax Lots;
- Phase 7 property/rental accounting;
- Phase 9 Tax Filing Context/workspace;
- External Connection/provider infrastructure;
- durable Jobs for provider sync/status polling/webhooks;
- final-return archival through the Stored Object/Records lifecycle.

### Major open questions

- Which providers permit third-party/self-hosted consumer applications and under what commercial/contractual conditions?
- Can a fully local/self-hosted Pryvance installation satisfy provider OAuth/webhook/callback requirements without a Pryvance-operated relay service?
- Which identity/signature/payment screens must legally remain provider-hosted?
- What data minimization or deletion obligations apply after a provider session completes?
- How should Pryvance distinguish provider-calculated estimates from accepted filed-return facts?

---

## 2. Continuous tax intelligence

### Intent

Turn tax from a once-a-year workspace into an evidence-backed, continuously updated planning surface.

Potential capabilities:

- projected federal/state liability and refund/balance-due range;
- withholding adequacy and remaining-pay-period adjustment guidance;
- estimated quarterly-payment planning;
- realized/unrealized gain awareness;
- tax-loss/tax-gain harvesting candidates;
- Roth-conversion scenarios;
- deduction/support discovery;
- rental tax projection;
- threshold-aware planning where material (for example IRMAA/ACA/RMD-related planning if legally and factually supportable at implementation time).

### Why it fits

Unlike a standalone planner, Pryvance can eventually derive projections from reconciled transactions, payroll, investment facts, property records, and retained tax Documents. Recommendations can link directly to source Evidence and expose missing Coverage rather than asking the Household to re-enter an approximate parallel model.

### Likely shape

Use Calculation Runs and explicit tax-year assumptions. Separate:

- observed facts;
- provider/current-law reference inputs;
- user Scenario assumptions;
- derived estimate;
- confidence/data-sufficiency status.

Never present a planning estimate as a prepared or valid tax return. A filing-provider integration may optionally supply the tax calculation/rules engine, but the planning interface should remain provider-neutral where possible.

### Dependencies

Phase 3 forecasting, Phase 5 payroll/Records, Phase 6 investments, Phase 7 property, Phase 9 tax workspace, Phase 10 scenarios/AI.

### Open questions

- Buy or build the tax-estimation rules layer?
- How frequently can rules safely update without making historical Calculation Runs irreproducible?
- Which recommendations cross from financial analysis into regulated tax advice, and what product wording/guardrails are required?

---

## 3. Household financial close

### Intent

Create a monthly/quarterly/yearly workflow that answers: **"Are the Household's books actually complete and trustworthy through this date?"**

Potential close checklist:

- required Account statements received;
- statement periods reconciled;
- unexplained differences resolved or explicitly waived;
- unknown/uncertain transactions reviewed;
- expected Accounts/Assets/Liabilities have fresh observations;
- receipts/supporting Documents attached for configured material categories;
- payroll/deposit/investment contribution reconciliation complete;
- property/rental classifications reviewed;
- investment holdings/balances reconciled where source evidence supports it;
- backup/Recovery Point verified;
- Coverage gaps acknowledged;
- period marked closed with an immutable summary/manifest.

### Why it fits

This compounds Pryvance's strongest architectural choices: reconciliation, Coverage, Review Items, Evidence, Audit, and recovery. Consumer finance products commonly show dashboards; fewer treat financial completeness as a first-class state that can be proved.

### Likely shape

A `Financial Close` is a period-specific workflow/manifest, not a destructive accounting lock. Later evidence may refine historical truth; any reopening/amendment should be auditable.

### Dependencies

Phases 1-8 provide progressively richer close checks. A useful first close could exist after ledger/import/reconciliation and expand as new data families arrive.

### Open questions

- Which checks are mandatory versus Household-configurable?
- Does "closed" freeze a Calculation Run snapshot only, or also create a dedicated Evidence manifest?
- How should late-arriving corrected provider data amend a previously closed period?

---

## 4. Retirement and lifetime financial planning

### Intent

Extend short-range budgeting/forecasting into lifetime planning across retirement, education, legacy, and major life goals.

Potential capabilities:

- retirement-income timeline;
- Social Security/pension assumptions;
- retirement account drawdown ordering;
- RMD projections;
- Roth conversion scenarios;
- tax-aware withdrawal planning;
- Monte Carlo/probabilistic outcomes where assumptions justify it;
- college/529 funding;
- major Asset purchase/sale scenarios;
- legacy/estate outcome projections.

### Why it fits

Pryvance will already know actual Household balances, contributions, ownership, cash flows, tax lots, goals, liabilities, and spending history. Lifetime plans should therefore start from observed/reconciled state instead of a second manually maintained model.

### Likely shape

Extend the Scenario/Calculation Run model; do not mutate observed state. Every result must disclose assumptions, methodology, horizon, stale/missing inputs, and sensitivity.

### Dependencies

Phase 3 planning/forecasting, Phase 6 investments/net worth, Phase 7 property/liabilities, continuous tax intelligence, Phase 10 Scenario engine.

### Open questions

- Simulation methodology and validation standard;
- market/inflation return assumption sources;
- tax-engine dependency;
- handling future dependents/education/healthcare scenarios without false precision.

---

## 5. Estate and household continuity workspace

### Intent

Use Pryvance's long-lived Household record to support continuity when a Household member is unavailable, incapacitated, or deceased.

Potential capabilities:

- will/trust/POA/healthcare-directive inventory;
- executor/trustee/guardian/beneficiary relationships;
- account/Asset/Liability/insurance inventory package;
- emergency contacts/instructions;
- location of originals and professional contacts;
- beneficiary review reminders;
- controlled emergency/death access or time-delayed handoff;
- "if something happens to me" continuity package;
- estate settlement checklist and evidence bundle.

### Why it fits

People, children/dependents, Financial Entities, Assets, Accounts, liabilities, insurance, beneficiaries, and Documents already exist or are planned. This feature turns that structured Household model into operational continuity rather than creating another document silo.

### Likely shape

Treat legal Documents as Evidence/Records; do not interpret Pryvance as the legal instrument itself. Access delegation must be distinct from ordinary Household sharing and designed with extremely strong authorization, notification, revocation, and Audit semantics.

### Dependencies

Multi-user/privacy hardening, Records vault, insurance, Assets/entities, alerts/schedules.

### Open questions

- What proof/event activates emergency or post-death access?
- Can a self-hosted product implement reliable delayed access without a trusted external service?
- How are recovery secrets and infrastructure instructions safely handed to successors?
- Which features create legal-document or fiduciary obligations that should remain out of scope?

---

## 6. Equity compensation

### Intent

Support compensation forms that are poorly represented by ordinary cash-flow and brokerage views.

Potential capabilities:

- RSUs;
- ESPP;
- ISOs/NSOs;
- grants and vesting schedules;
- exercise/sale events;
- withholding;
- cost basis and holding periods;
- concentration exposure;
- projected vest income;
- tax consequences and Scenario analysis.

### Why it fits

Equity compensation connects payroll, investments, Tax Lots, tax planning, net worth, and future cash-flow forecasting. Pryvance can reconcile employer/payroll/brokerage evidence across those boundaries instead of treating a vest/sale as unrelated transactions.

### Dependencies

Payroll, investments/Tax Lots, Documents/extraction, tax intelligence, Scenario engine.

### Open questions

- Canonical grant/award model versus provider-specific facts;
- reliable brokerage/employer data sources;
- handling complex option tax rules without owning a tax engine;
- valuation treatment for private-company equity.

---

## 7. Debt optimization

### Intent

Move beyond Liability reporting into evidence-backed decision support.

Potential capabilities:

- snowball/avalanche payoff scenarios;
- mortgage prepayment versus investing;
- refinance break-even;
- student-loan scenarios;
- HELOC utilization/paydown;
- interest-cost projections;
- liquidity/reserve constraints;
- debt payoff integrated with Household goals and retirement scenarios.

### Why it fits

Pryvance already intends liabilities, commitments, cash forecasts, investments, rates, and goals. Optimization can therefore evaluate Household-wide tradeoffs instead of treating debt in isolation.

### Likely shape

Scenario-only; no automatic debt movement. Use Calculation Runs with clearly stated rate/return assumptions.

### Dependencies

Phase 3 planning, Phase 6 investments, Phase 7 liabilities/property, advanced scenarios.

### Open questions

- Whether to use expected investment-return assumptions at all in prescriptive comparisons;
- treatment of variable rates/refinance costs/taxes;
- whether recommendations should optimize mathematically or offer transparent option comparisons only.

---

## 8. Insurance adequacy and household risk planning

### Intent

Extend the planned insurance inventory from "what policies exist" to "what risks are covered or materially exposed."

Potential capabilities:

- life-insurance needs analysis;
- disability-income coverage comparison;
- umbrella/liability coverage review;
- property/auto coverage inventory gaps;
- beneficiary inconsistency alerts;
- premium/coverage tradeoff scenarios;
- policy expiration/renewal/review workflows.

### Why it fits

Pryvance will know Household income, dependents, liabilities, Assets, reserves, existing policies, and long-range goals. Adequacy analysis can therefore use the Household's actual economic context.

### Boundaries

Keep this analytical and evidence-backed. Do not turn Pryvance into an insurance-sales/commission platform by default. Projections/needs calculations must expose assumptions and must not conflate death benefit with current net worth.

### Dependencies

Phase 8 insurance plus planning/net worth/dependents/continuity features.

### Open questions

- Appropriate calculation standards by policy/risk type;
- regulatory/advice wording;
- whether carrier quotation/comparison belongs via optional providers.

---

## 9. Financial packages and evidence bundles

### Intent

Generate purpose-specific, audited packages from the records Pryvance already maintains.

Examples:

- accountant/CPA package;
- tax filing package;
- mortgage/loan application package;
- proof-of-net-worth package;
- annual Household financial report;
- insurance/estate continuity packet;
- rental/property package;
- selected Evidence package for an advisor or attorney.

### Why it fits

This is a relatively low incremental-cost capability once Pryvance has structured facts, Documents, authorization, and export manifests. Its value comes from selecting coherent, purpose-authorized evidence rather than exporting a data dump.

### Likely shape

Generalize the planned accountant export into a reusable `Export Context`/package mechanism only if multiple use cases prove the abstraction. Every package should include:

- purpose;
- requester/authorized audience;
- included facts/Documents;
- provenance/evidence index where useful;
- generated summary version/calculation basis;
- known missing Coverage;
- Audit record;
- expiration/revocation semantics for any hosted/shared artifact.

### Dependencies

Records vault, authorization/privacy, Audit, search, tax export.

### Open questions

- Static ZIP/PDF versus temporary secure share links;
- watermarking/redaction;
- retention/revocation of generated packages;
- whether machine-readable standardized formats are useful for specific professional workflows.

---

## 10. Employer benefits intelligence

### Intent

Treat compensation and benefits as a connected Household financial system rather than a net-pay deposit.

Potential capabilities:

- HSA/FSA balances, contributions, reimbursements, and eligibility context;
- 401(k)/403(b) contribution and employer-match optimization;
- benefit deductions/contributions reconciliation;
- open-enrollment comparison workspace;
- employer health-plan premium/out-of-pocket scenario comparison;
- dependent-care benefits;
- benefit-election reminders and annual limits;
- total-compensation reporting.

### Why it fits

Payroll extraction is already planned, and many benefits connect directly to taxes, investments, Household funding, insurance, and dependents. This reuses otherwise under-exploited payroll facts.

### Dependencies

Payroll, Documents/extraction, retirement/investments, insurance, dependents, continuous tax intelligence.

### Open questions

- Plan-document extraction reliability;
- current-law limit/reference-data source;
- how much healthcare-cost modelling belongs in a financial product;
- whether employer portals provide reusable integration surfaces.

---

## 11. Tax transcript and external tax-record reconciliation

### Intent

Import authoritative or near-authoritative external tax records and compare them with Pryvance's own evidence.

Potential capabilities:

- IRS transcript/history import through an authorized provider or user-supplied files;
- prior filing-status/return-fact history;
- wage/income transcript comparison;
- "what the tax authority/provider knows versus what Pryvance records show" reconciliation;
- missing-form detection;
- prior-year basis/return evidence enrichment;
- automatic archival of official acknowledgements/returns.

### Why it fits

This is another form of reconciliation: independent external evidence can strengthen or expose gaps in the Household record without overwriting original sources.

### Likely shape

Preserve transcript/provider records as immutable Evidence. Extracted facts remain source-linked and may disagree with brokerage/payroll/Pryvance totals until reviewed. Never silently promote external tax data to universal financial truth when timing or reporting basis differs.

### Dependencies

Tax workspace, External Connections, Records/extraction, Evidence/Provenance, provider-neutral tax infrastructure.

### Open questions

- Current IRS/provider authorization paths and retention limits;
- identity/consent requirements;
- exact transcript data coverage/history;
- whether direct government APIs are available or provider mediation is required at implementation time.

---

## Suggested future sequencing

This is **not** a roadmap. It only records dependency logic if these ideas are later approved.

### Tier A — natural extensions of already-planned data

These should have relatively high leverage because the target architecture already supplies most prerequisites:

1. Household financial close.
2. Financial packages/evidence bundles.
3. Employer benefits intelligence.
4. Continuous tax intelligence.

### Tier B — larger analytical/product surfaces

5. Debt optimization.
6. Equity compensation.
7. Retirement/lifetime planning.
8. Insurance adequacy/risk planning.

### Tier C — integration/security-heavy extensions

9. Tax transcript reconciliation.
10. Provider-neutral tax preparation and filing.
11. Estate/household continuity workspace, especially any delayed/emergency-access mechanism.

The ordering may change substantially based on user demand, provider availability, implementation experience, or architecture learned from the current roadmap.

## Explicit non-goals unless separately approved

The following are adjacent but should not be inferred from the opportunities above:

- first-party banking or custody;
- brokerage/trade execution;
- lending/loan origination;
- payroll processing;
- full general-ledger/business accounting suite;
- first-party tax-return calculation/e-file engine;
- acting as a tax preparer, financial adviser, insurance broker, attorney, or fiduciary merely because Pryvance can organize or analyze related data;
- non-U.S. tax filing architecture without a separate design/research cycle.

Integration with providers in these areas may be valuable; taking on the regulated operating role is a separate decision.

## Research snapshot — September 2026

The research that produced this document found strong products in individual slices of the intended space—budgeting/collaboration, wealth/entity tracking, long-range planning, self-hosting, records/estate organization, and embedded tax—but no single product was identified as combining Pryvance's intended local-first/privacy model with reconciled financial truth, evidence/provenance, selective Household sharing, records/payroll, recursive ownership/property, insurance, tax organization, and AI.

This observation is **time-sensitive**. It is context for why the opportunities looked strategically coherent in 2026, not a permanent market claim.

For tax specifically, the important durable observation was architectural rather than vendor-specific: some tax products expose only data-import/hand-off integration, while embedded tax platforms may expose calculation and filing lifecycle APIs. Pryvance should model the capabilities it needs and allow adapters to implement a subset.

At implementation time, re-check current official IRS/state requirements and the current partner/developer documentation for every candidate provider before making a design decision.
