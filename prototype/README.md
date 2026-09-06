# Pryvance product prototype

`index.html` is the consolidated interactive product/UX prototype used while defining Pryvance.

It is intentionally stored outside `docs/`: the prototype is a product-design reference artifact, not an architectural source of truth and not part of the adopted Diátaxis design set. The durable architecture, domain rules, API contract, security model, roadmap, and ADRs under `docs/` remain authoritative when the prototype and implementation differ.

The HTML is self-contained for offline viewing. Its supporting JavaScript is embedded and the prototype does not require Google Fonts or other remote assets to render the packaged experience. Open the file in a modern browser; the small outer loader uses the browser `DecompressionStream` API to unpack the embedded prototype in memory.

Treat fictional names, balances, transactions, institutions, addresses, and documents in the prototype as sample data only.
