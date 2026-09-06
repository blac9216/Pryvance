# Pryvance product prototype

`pryvance-prototype.html` is the consolidated interactive product/UX prototype used while defining Pryvance.

## Repository location

Keep this directory at the repository root as `prototype/`, separate from `docs/`:

```text
prototype/
├── README.md
└── pryvance-prototype.html
```

The prototype is a product-design reference artifact, not an architectural source of truth and not part of the adopted Diátaxis design set. The durable architecture, domain rules, API contract, security model, roadmap, glossary, and ADRs under `docs/` and `CONTEXT.md` remain authoritative when the prototype and implementation differ.

## Viewing

Open `pryvance-prototype.html` in a modern browser. The original companion `support.js` has been embedded, so the prototype is distributed as one HTML file. The exported design runtime may load React/ReactDOM runtime libraries from its CDN when opened, so network access can be required for initial rendering.

Fictional names, balances, transactions, institutions, addresses, documents, and other financial data in the prototype are sample data only.
