# Synthetic Household fixtures

This directory is the canonical home for committed Pryvance example, demo, seed, import, document, and integration-test material that represents Household data.

## Rule: synthetic from inception

Everything committed here must be invented from a blank page or generated from already-synthetic inputs. Never create a fixture by exporting, copying, redacting, perturbing, masking, or lightly editing real Household data.

That rule applies even when the resulting value would appear anonymous. Real financial records carry combinations of dates, amounts, merchants, identifiers, document structure, metadata, and relationships that can remain identifying after obvious fields are changed.

## Current state

This is intentionally a stub. Pryvance does not yet have an application implementation or stable import/seed formats, so there is no canonical household dataset to populate yet.

As implementation grows, build one internally consistent fictional Household here incrementally rather than creating unrelated one-off demo universes. Add only the material a real test, importer, demo, or documented example needs.

Expected future subdirectories may include concepts such as:

- `seed/` for structured application seed data;
- `imports/` for synthetic provider/file import fixtures;
- `documents/` for generated statements, receipts, tax, insurance, and property documents;
- `expected/` for deterministic normalized/extracted outcomes.

Do not create those directories until an implemented test or feature needs them.

## Safety conventions

- Use reserved example domains for email and network examples.
- Use RFC documentation address ranges for IPv4 examples.
- Use deliberately invalid placeholders when a checksum-valid identifier is unnecessary.
- When a test specifically requires a checksum-valid sensitive-shaped identifier, construct it inside the narrow test that needs it when practical rather than publishing a reusable realistic-looking value.
- Do not commit secrets, provider exports, recovery material, real logs, screenshots containing real data, database snapshots, or copied personal documents.

The repository-wide mechanical enforcement lives in `.github/workflows/sanitize.yml` and `.github/sanitize/scan_repo_specific.py`.
