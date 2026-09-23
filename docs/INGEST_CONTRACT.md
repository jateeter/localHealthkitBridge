# HealthKit Ingest Contract (canonical)

Last reviewed: 2026-09-23

This is the single source of truth for the bridge ↔ Perception Engine ingest
contract. All four PE runtimes (C++, Lisp, Scala, TypeScript Manager PE)
implement this surface; `RealityEngine_Machines/tests/integration/healthkit-ingest-contract.spec.ts`
enforces cross-engine parity against the live registry.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/integrations/healthkit/ingest` | Sample delivery (single or batch) |
| `GET` | `/api/integrations/healthkit/status` | Bridge config echo + token mode + scope state and pending resync requests; used by the iOS app for last-sync display |
| `POST` | `/api/integrations/healthkit/scope` | Authorization change: add / lock / remove types (Swift bridge, OpenCommons PIM) |
| `POST` | `/api/integrations/healthkit/resync` | Consumer request to re-send types (localAIStack), fulfilled by an ingest carrying `resyncId` |

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
      "sourceMappingId": "healthkit:HKCorrelationTypeIdentifierBloodPressure",
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
- `sourceMappingId` / `mappingId` — optional explicit mapping id; when present,
  it is the highest-priority registry lookup and must resolve.
- `metadata` — optional, informational (FHIR provenance); never validated.
- `anchorToken` — optional opaque string echoed back in the response so the
  client can confirm which sync cursor a response corresponds to.
- `resyncId` — optional; set when the batch answers a resync request. See
  *Scope and resync*.

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
exercise `[4330:4334]`, sleep `[4340:4344]`.

> **Lane names and payloads disagree, and the corpus is the one to fix.**
> `region-allocation.json` calls `[4320:4324]` `healthkit-heart-rate`, but the
> bridge writes a blood-pressure family there — systolic, diastolic, pulse,
> confidence — of which only position 2 is a heart-rate quantity. It calls
> `[4330:4334]` `healthkit-steps`, but the bridge writes an exercise family —
> active energy, exercise minutes, steps, confidence — of which only position 2
> is a step count. The regions and arity agree; the names describe one axis of
> four. `docs/lane-semantics.json` records what each position actually carries.
>
> A fourth lane, `healthkit-activity` `[4300:4304]`, is declared with
> `readers=[FallSensorMotionPreaggregator]` and `writers=[]`, and **the bridge
> has no family that targets it** — a machine reads a lane nothing writes. That
> is left unannotated rather than given invented semantics: this repo cannot say
> what a lane means when it does not write it. Either the bridge gains an
> activity family or the lane should be withdrawn, and that is a corpus
> decision. See jateeter/RealityEngine_Machines#59 and #9.

## Lane semantics and payload schema

`docs/lane-semantics.json` supplies what the ingress guardrails need per lane
position: source unit, source range, canonical UCUM, scale type, conversion
policy and a staleness ceiling. Every value the bridge writes is normalised to
`[0,1]` against a declared range with the raw reading kept in metadata, so the
canonical unit of every position is UCUM `1` and `conversionPolicy` is
`prohibited` — rescaling an already-normalised value is not a unit conversion,
it is a second normalisation against a range the consumer cannot see.

`schemas/healthkit-ingest.schema.json` makes this contract checkable rather than
prose plus one spec test.

**Determinism class: `measured`.** A HealthKit sample is a reading taken by a
device, not a value produced by a model — exogenous but reproducible under
replay. `ARBITER_CONTRACT.md` §4.3a ranks `measured`(2) below
`deterministic`(3) and above `generated`(1). Classifying it upward would let a
reading outrank a machine determination; downward would let a generated
assessment outrank a reading. Machines in
`RealityEngine_Machines/machines/domains/health-personal/` consume these
regions — `HealthKitVitalsMonitor.json` (gte, input `[4320:4324]`, output
`[4304:4308]`) classifies bridge BP readings into
NOMINAL/HYPERTENSIVE/CRISIS.

## Scope and resync

*Added 2026-09-23 (localAIStack HEALTH_INTEGRATION_ROADMAP T8).* The data scope,
meaning which HealthKit types flow, is not fixed. It changes through an
authorization workflow tied to the owner's Solid pod (OpenCommons PIM). That
workflow is **not built yet**, but the engines must already follow scope changes,
so the PE is the scope authority and every consumer reads scope from it. Held
3-of-3 across C++, LSP and Scala; the TypeScript PE conforms.

Two directions, deliberately separate:

- **Scope** runs from the producer to the PE. It is an authorization change.
- **Resync** runs from a consumer, through the PE, to the producer. It is a
  request to re-send data, not an authorization action.

### `POST /api/integrations/healthkit/scope`

```json
{ "bridgeId": "healthkit-ios-bridge", "action": "add", "types": ["HKCategoryTypeIdentifierSleepAnalysis"], "source": "pim", "reason": "owner granted" }
```

Authenticated like ingest. Schema: `schemas/healthkit-scope.schema.json`.

**Open until declared.** A bridge that has never sent a scope message behaves
exactly as before, and every mapped type is accepted. Its first scope message
switches it to **explicit scope**, after which only `active` types are ingested.

| `action` | Resulting type state | Effect on ingest | Effect on held values |
|---|---|---|---|
| `add` | `active` | accepted | none |
| `lock` | `locked` | refused, `reason: "locked"` | none; existing values stand |
| `remove` | `removed` | refused, `reason: "not-in-scope"` | the sensor sources the type wrote are removed from the PE: **absent, not zero** |

In explicit scope, a type that has never been added is also refused
`not-in-scope`. A refused sample is reported in `unmapped[]` with its `reason`,
and the ingest status codes apply unchanged (`207` partial, `400` all refused).

> **Provisional.** The Solid pod authorization workflow will define its own
> meaning for add/lock/remove, which is expected to differ from the above. The
> actions are a table so they can be changed in one place per runtime.

Response `200`:
`{ "success": true, "bridgeId", "action", "generation", "applied": [ { "type", "state", "previous" } ] }`.
`previous` is `null` for a type seen for the first time. `generation` increases by
one on every accepted scope change. `400` for an unknown action or empty `types`;
`401` for bad credentials. Every change broadcasts
`{ "type": "healthkit.scope.changed", "bridgeId", "action", "types", "generation" }`.

### `POST /api/integrations/healthkit/resync`

```json
{ "bridgeId": "healthkit-ios-bridge", "types": ["HKCategoryTypeIdentifierSleepAnalysis"], "requestedBy": "localAIStack", "reason": "health machine re-registered" }
```

Authenticated like ingest. Schema: `schemas/healthkit-resync.schema.json`.
`types` absent or empty means every type the bridge has in scope (under open scope,
every type the PE has seen from that bridge). A `locked` or `removed` type cannot
be resynced and is returned in `refused[]`.

Response `202`:
`{ "success": true, "request": { "id", "bridgeId", "types", "requestedBy", "requestedAt", "state": "pending" }, "refused": [ { "type", "reason" } ] }`.
When every requested type is refused, the response is `409` with the same body
and `success: false`. A resync changes no scope and no generation.

**Fulfilment.** The producer finds pending requests on `/status`. It re-reads and
sends an ingest batch carrying `resyncId: <request id>`. The PE marks the request
`fulfilled` (`fulfilledAt`) and echoes `resyncId` in the ingest response. The
values it resolves replace what was held for those types. Requests are kept per
bridge, newest last, capped at 32.

### Scope on `GET /status`

```json
"scope": {
  "declared": true,
  "generation": 3,
  "types": { "HKCategoryTypeIdentifierSleepAnalysis": { "state": "active", "source": "pim", "updatedAt": 1790000000000 } },
  "resyncRequests": [ { "id": "...", "types": [...], "requestedBy": "localAIStack", "requestedAt": 0, "state": "pending", "fulfilledAt": null } ]
}
```

`declared: false` with an empty `types` map means open scope.

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
