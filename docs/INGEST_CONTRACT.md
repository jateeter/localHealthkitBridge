# HealthKit Ingest Contract (canonical)

Last reviewed: 2026-07-13

This is the single source of truth for the bridge ↔ Perception Engine ingest
contract. All four PE runtimes (C++, Lisp, Scala, TypeScript Manager PE)
implement this surface; `RealityEngine_Machines/tests/integration/healthkit-ingest-contract.spec.ts`
enforces cross-engine parity against the live registry.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/integrations/healthkit/ingest` | Sample delivery (single or batch) |
| `GET` | `/api/integrations/healthkit/status` | Bridge config echo + token mode; used by the iOS app for last-sync display |

## Request body

Batch (preferred — the iOS bridge always sends batches):

```json
{
  "bridgeId": "healthkit-ios-bridge",
  "bridgeToken": "<token, when configured>",
  "anchorToken": "<opaque client sync cursor, optional>",
  "samples": [
    {
      "type": "HKCorrelationTypeIdentifierBloodPressure",
      "sourceName": "Apple Watch",
      "unit": "mm[Hg]",
      "values": [0.72, 0.48, 0.24, 0.99],
      "metadata": { "standard": "SpeziHealthKit", "fhirCode": "85354-9" }
    }
  ]
}
```

A single flat body (sample fields at the top level, no `samples[]`) is accepted
by the native runtimes for debugging, but the bridge must not rely on it.

Field rules:

- `type` — HK type identifier; required per sample.
- `values` — pre-normalized `[0,1]` vector per the family tables in the README.
  A scalar `value` is accepted as a 1-element fallback.
- `sourceName` — optional; enables the `healthkit:<type>:<sourceName>` mapping key.
- `metadata` — optional, informational (FHIR provenance); never validated.
- `anchorToken` — optional opaque string echoed back in the response so the
  client can confirm which sync cursor a response corresponds to.

## Authentication

Token mode is enabled by setting `HEALTHKIT_BRIDGE_TOKEN` in the PE
environment. When enabled, a request is authorized if **either**:

1. body `bridgeToken` (alias: `token`) equals the configured token, **or**
2. an `Authorization: Bearer <token>` header equals the configured token
   (scheme matched case-insensitively).

Wrong or missing credentials → `401 Unauthorized`. When no token is
configured, all ingest is accepted (dev mode). `GET /status` reports
`tokenConfigured` and advertises `contract.auth` as `"bridgeToken|bearer"`
when a token is set.

The iOS bridge sends the `Authorization: Bearer` header by default (keeps the
secret out of request bodies/logs); the body field remains supported for curl
and legacy clients.

## Mapping resolution

Per sample, first match wins:

1. explicit `sourceMappingId` / `mappingId` on the sample,
2. `healthkit:<type>:<sourceName>` (when `sourceName` non-empty),
3. `healthkit:<type>`.

Mappings come from the runtime's integrations config
(`INTEGRATIONS_CONFIG`, see `config/integrations.healthkit-spezi.example.json`
in each runtime repo). Default regions: blood pressure `[4320:4324]`,
exercise `[4330:4334]`, sleep `[4340:4344]`. Machines in
`RealityEngine_Machines/machines/domains/health-personal/` consume these
regions.

## Response

```json
{
  "success": true,
  "bridgeId": "healthkit-ios-bridge",
  "anchorToken": "<echoed if sent>",
  "resolved": [ { "resolved": true, "sensorId": "healthkit.blood-pressure", "type": "...", "sourceMappingId": "...", "values": [0.72, 0.48, 0.24, 0.99], "ttlMs": 3600000 } ],
  "unmapped": []
}
```

HTTP status: `200` all resolved · `207` partial · `400` all unmapped ·
`401` bad token.

## Discovering the PE

Prefer the runtime registry (`http://<host>:5999/re-registry.json`, field
`instances[].pe_url`) over hard-coded ports. Static defaults when running a
single engine by hand: C++ `5300`, Lisp `5600`, Scala `5100` (universe
allocation; a standalone Scala PE outside the universe defaults to its own
port — always confirm via the registry), TypeScript Manager PE `3004`.
