# localHealthkitBridge Guidance

Last reviewed: 2026-07-13

See `/Users/johnt/workspace/GitHub/claude.md` for the integrated application map. Update both this file and the root map when the ingest contract, package layout, or PE integration responsibilities change.

## Role

This repo contains the iOS HealthKit → Perception Engine bridge: a Swift package (`HealthKitBridge`) plus the canonical bridge ↔ PE ingest contract that all four PE runtimes (C++, Lisp, Scala, TypeScript Manager PE) implement.

## Codebase Map

- `Package.swift`: SPM package, iOS 16+ / macOS 13+, no external dependencies.
- `Sources/HealthKitBridge/BridgeConfiguration.swift`: PE base URL, bridgeId/token, retry policy.
- `Sources/HealthKitBridge/HealthKitManager.swift`: authorization, anchored object queries, background delivery.
- `Sources/HealthKitBridge/SampleNormalizer.swift`: README family tables → pre-normalized `[0,1]` 4-vectors.
- `Sources/HealthKitBridge/IngestClient.swift`: batch POST, Bearer auth, exponential backoff, anchorToken round-trip.
- `Sources/HealthKitBridge/AnchorStore.swift`: per-type anchor persistence (UserDefaults, Data-based for testability).
- `Sources/HealthKitBridge/BridgeCoordinator.swift`: wiring of the above.
- `Sources/HealthKitBridge/Models.swift`: payload/response types mirroring the ingest contract.
- `Tests/HealthKitBridgeTests/`: unit coverage.
- `docs/INGEST_CONTRACT.md`: canonical ingest contract — single source of truth.
- `ROADMAP.md`: M0–M6 plan to v0.1.0.

## Key Commands

```bash
swift build
swift test
PE_BASE_URL=... [HEALTHKIT_BRIDGE_TOKEN=...] ./scripts/e2e_simulator.sh   # test-batch leg
PE_BASE_URL=... [HEALTHKIT_BRIDGE_TOKEN=...] ./scripts/e2e_seeded.sh      # seeded XCUITest leg
DEVELOPMENT_TEAM=... [PE_BASE_URL=http://<lan-ip>:...] ./scripts/e2e_device.sh  # physical device leg (M5)
```

## Contract Rules

- `docs/INGEST_CONTRACT.md` is the single source of truth for `POST /api/integrations/healthkit/ingest` and `GET /api/integrations/healthkit/status`. Changes must be mirrored in RealityEngine_CPP, RealityEngine_LSP, RealityEngine_Scala, and the Manager TS PE, and covered by `RealityEngine_Machines/tests/integration/healthkit-ingest-contract.spec.ts`.
- Auth: body `bridgeToken` (alias `token`) OR `Authorization: Bearer` — either channel must match `HEALTHKIT_BRIDGE_TOKEN` when configured. The iOS bridge sends Bearer by default.
- Samples carry pre-normalized 4-element `values`; scalar `value` is a legacy fallback normalized server-side.
- Prefer the runtime registry (`re-registry.json`, `instances[].pe_url`) over static ports. All PEs default to a 7680-dimension vector (`VECTOR_DIMENSION`); the Manager TS PE also grows on demand, so the canonical health regions [4320:4344] fit out of the box.
