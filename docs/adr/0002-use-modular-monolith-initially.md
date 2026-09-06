# ADR-0002: Use a modular monolith for the initial application

Status: Proposed
Date: 2026-09-05

## Context

Pryvance needs a React UI, ASP.NET Core application logic, PostgreSQL persistence, background synchronization, receipt/document processing, and AI orchestration. It will initially serve one household from a self-hosted Docker deployment. Splitting these concerns into separate services immediately would add deployment, networking, observability, and schema-coordination overhead before scale or fault-isolation needs are known.

## Decision Drivers

- Minimize self-hosting and operational complexity.
- Preserve clear domain boundaries for future extraction.
- Keep development fast for a single primary maintainer.
- Avoid premature distributed-system failure modes.
- Allow React and REST API to ship as one easy-to-run application.

## Considered Options

1. **Modular ASP.NET Core monolith serving React plus background jobs** — simplest deployment while retaining internal boundaries; some workloads share a process.
2. **Separate frontend, API, and worker containers from day one** — cleaner runtime isolation; additional deployment and coordination cost with little current benefit.
3. **Microservices by domain** — maximum independent deployment; excessive complexity for the expected scale and maintainer count.

## Decision

Pryvance will begin as a modular ASP.NET Core monolith that serves the React build and hosts application/background-job modules, with PostgreSQL and private file storage as separate persistence dependencies.

## Consequences

- Initial Docker Compose can remain small: application, PostgreSQL, and persistent storage.
- Module boundaries must be enforced in code because process boundaries do not enforce them.
- Background processing may later move to a separate worker without changing the domain contracts.
- A reverse proxy is optional rather than required for the initial local/Tailscale deployment.
