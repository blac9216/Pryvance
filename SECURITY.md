# Security Policy

Pryvance is designed to process highly sensitive household financial, identity, tax, insurance, property, document, credential, and recovery data. Security reports should therefore be handled privately and should contain the minimum sensitive information necessary to reproduce the issue.

## Supported versions

Pryvance is currently under active pre-release development. Until tagged supported releases exist, security fixes target the current `main` branch. This section should be replaced with an explicit supported-version matrix when stable releases begin.

## Reporting a vulnerability

**Do not open a public GitHub issue for a suspected vulnerability.**

Preferred reporting path:

1. Use GitHub's **Private vulnerability reporting** for the Pryvance repository when that option is available.
2. If private vulnerability reporting is not available, contact the repository maintainer privately using the contact methods published on the maintainer's GitHub profile and request a private channel for the report.

Do not include real Household records, credentials, access tokens, recovery secrets, full account/card/policy identifiers, tax identifiers, or unredacted financial documents in a report. Use synthetic or redacted reproduction data whenever possible.

A useful report includes:

- a concise description of the vulnerability and affected component;
- the conditions required to reproduce it;
- a minimal proof of concept using synthetic/redacted data;
- the security impact and affected trust boundary;
- the commit/version tested;
- any known mitigations or workarounds;
- whether you believe the issue is being actively exploited.

## What to report

Security reports are especially welcome for issues involving:

- authentication or authorization bypass;
- cross-user or Household-member privacy leakage;
- tax-filing-context disclosure;
- secret, credential, recovery-key, or token exposure;
- SQL injection, command injection, path traversal, SSRF, or unsafe deserialization;
- malicious file/document parsing or upload handling;
- unsafe AI/tool authorization or private-data leakage through AI/search/indexes;
- provider webhook spoofing or replay;
- cryptographic misuse or plaintext exposure of cloud archive/backup material;
- backup, restore, or object-integrity failures that can silently lose or substitute data;
- privilege escalation through jobs, workers, schedules, integrations, or administrative APIs;
- sensitive-data exposure through logs, errors, notifications, exports, caches, counts, autocomplete, or metadata.

The target trust model and threat priorities are documented in [`docs/explanation/security.md`](docs/explanation/security.md).

## Response process

The maintainer will try to:

1. acknowledge a credible report privately;
2. reproduce and assess severity without unnecessarily spreading exploit details;
3. coordinate a fix and regression coverage;
4. avoid publishing exploit details until a fix or reasonable mitigation is available;
5. credit reporters who want public credit, unless doing so would create additional risk.

Response times are best-effort while the project is pre-release and maintained without a formal security-response SLA.

## Safe-harbor intent

Good-faith security research that avoids privacy violations, data destruction, service disruption, social engineering, credential theft, and access to data beyond what is necessary to demonstrate the issue is welcome. Stop testing and report privately if you encounter real user data or secrets.

This policy does not authorize testing against systems, accounts, providers, or infrastructure you do not own or have permission to test.
