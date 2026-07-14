# Codex Guidance: localHealthkitBridge

Read `claude.md` for the current codebase map and ingest-contract context.

## Role

This repo is the iOS HealthKit → Perception Engine bridge: the `HealthKitBridge` Swift package and the canonical bridge ↔ PE ingest contract (`docs/INGEST_CONTRACT.md`).

## Development Rules

- Treat `docs/INGEST_CONTRACT.md` as a cross-repo contract. Changes must be mirrored in all four PE runtimes (CPP, LSP, Scala, Manager TS PE) and in `RealityEngine_Machines/tests/integration/healthkit-ingest-contract.spec.ts`.
- Keep the package dependency-free and testable without HealthKit (Data-based anchor store, URLProtocol-mocked networking).
- Normalization tables live in the README; `SampleNormalizer` must match them exactly, retaining raw values in sample metadata.
- Prefer registry-derived PE base URLs over static ports in docs and examples.

## Bug Triage

- For ingest failures, separate auth (401), mapping resolution (400/207 `unmapped`), and PE-side ingest errors (`failed`).
- For missing sensor updates, check anchor state, background-delivery entitlements, and TTL expiry separately.
- For contract drift, compare the live `GET /status` `contract` block across engines before changing the client.

## Verification

Common commands:

```bash
swift build
swift test
```

Live contract parity (universe running, from RealityEngine_Machines):

```bash
RE_REGISTRY_URL=http://127.0.0.1:5999/re-registry.json npx playwright test tests/integration/healthkit-ingest-contract.spec.ts
```

## Artifact Hygiene

Do not commit `.build/`, Xcode user state, or device logs. Keep generated OpenAPI/doc artifacts separate from source changes unless explicitly requested.
