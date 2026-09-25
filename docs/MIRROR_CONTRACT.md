# Mirror contract: HealthKit bridge → PIM Pod (SCS)

Status: **proposed, 2026-09-25.** Parts marked *settled* restate decisions made
elsewhere and cite them. Parts marked *proposed* await the owner's decision
(see *Decisions open*). Nothing here is implemented yet.

This is the single source of truth for **how** device-side HealthKit data
reaches the authoritative POD. **Whether** that is the rule is decided once, in
`RealityEngine_CI/docs/MVP_ROADMAP.md` G4. This file does not restate it; it
specifies the mechanics G4 left open (its D2).

It is separate from `INGEST_CONTRACT.md`. Ingest sends normalized 4-vectors to
the Perception Engine for the perceptual space. The mirror sends the underlying
observations to the owner's POD for durable ownership. Both stay, and neither
depends on the other.

---

## 1. Parties

| Party | Role | Implementation |
|---|---|---|
| **Bridge app** (this repo, iPhone) | **writer**, the only one. A Solid *mirror participant*, not an embedded server | `SolidAuthSwift` (Solid-OIDC + DPoP) and `SolidResourcesSwift`, per `MOBILE_SOLID_PHASE0_COMPATIBILITY.md`. Phases PM-3 (sign-in) and PM-4 (CRUD) are not built yet |
| **Solid Community Server** | holds the **authoritative POD** | the CSS instance PIM already uses (`SOLID_ISSUER_URL`, `SOLID_STORAGE_IRI`) |
| **PIM** (`OpenCommons-Health---Personal-Information-Management`) | **reader** and owner-facing reviewer. It never writes into `healthkit/` | `@inrupt/solid-client`; `GET /api/pod/healthkit/status` already counts `healthkit/observations/` |

*Settled* (G4, and the Phase 0 compatibility model): the device writes, the SCS POD
is authoritative, and PIM owns the server.

## 2. Resource layout

*Settled* (Phase 0 path conventions), under `<storage>/health-pim/`:

```text
healthkit/observations/    one resource per mirrored sample
healthkit/blood-pressure/  reserved (Phase 0); unused while BP mirrors as an observation
healthkit/workouts/        exercise samples (see D2b)
healthkit/sleep/           sleep samples (see D2b)
provenance/                one PROV record per mirrored resource
consents/                  owner mirror consent (see D2a)
sync/manifests/            one manifest per device
sync/conflicts/            one record per unresolved conflict
audit/                     append-only mirror events
```

## 3. Resource identity (proposed)

- **One resource per HealthKit sample**, named by the sample's HealthKit UUID:
  `healthkit/observations/<HKSample.uuid>.ttl`. HealthKit keeps a sample's
  UUID stable for its lifetime, so re-syncing the same sample addresses the same
  resource. That makes the mirror **idempotent by construction** without a
  lookup.
- **Gap:** the bridge's ingest payload (`Models.swift`) carries no sample UUID;
  normalization drops it. The mirror path must take identity from the
  `HKSample` itself, before normalization. The PE ingest contract is unchanged.

## 4. Representation (proposed)

- **RDF (Turtle) `SolidDataset`s**, because that is what PIM reads and writes
  (`podClient.saveDataset`). A FHIR JSON blob would be invisible to PIM's
  dataset readers.
- Each resource is a FHIR `Observation` in RDF: code, effective time, value(s)
  with UCUM units, and `derivedFrom` the HealthKit type identifier. It carries the
  **raw measured values**, not the bridge's `[0,1]` normalization, which is a PE
  concern (`INGEST_CONTRACT.md`).
- **Coverage gap to settle (D2b).** PIM's `acceptedObservationCodes` are
  `heart-rate`, `body-weight`, `body-height`, `blood-pressure`,
  `body-temperature`, `oxygen-saturation` and `blood-glucose`. Of the bridge's
  three families, only **blood pressure** (LOINC `85354-9`, with pulse →
  `heart-rate`) has a PIM code. **Exercise** (`55411-3`) and **sleep**
  (`93832-4`) have none today.

## 5. When a sample is mirrored (proposed)

**Nothing mirrors without owner consent.** *Settled* by the Phase 0 privacy
constraint: "owner approval is required before identifiable HealthKit-derived
resources are mirrored".

The consent model is D2a. The proposal: a **standing, per-family consent**
recorded as a resource in `consents/` (who, which families, since when, revoked
when). Samples of a consented family queue for mirroring as they are read. A
revoked consent stops new mirrors and **does not delete** what is already in the
POD; deleting is a separate owner action.

## 6. State machine

*Settled*: the states exist in `MobilePodModel` (`pendingMirror`, `mirrored`,
`conflict`), and `pendingMirror` is "a real intermediate state, not a display
detail" (ROADMAP). *Proposed*: the transitions.

```text
 local ──(consented family)──▶ pendingMirror ──PUT ok──▶ mirrored
                                   │
                                   └─412 / differs──▶ conflict ──(adopt SCS)──▶ mirrored
```

| Step | Request | Outcome |
|---|---|---|
| first mirror | `PUT …/<uuid>.ttl` with `If-None-Match: *` | `201` → `mirrored`, record the returned `ETag` |
| resource already exists | `412 Precondition Failed` | `GET` it. If its content equals the local sample → `mirrored` (a retry that already landed). Otherwise → `conflict` |
| local sample changed after mirroring (HealthKit edits or deletes it) | `PUT` with `If-Match: <recorded ETag>` | `2xx` → `mirrored`; `412` → `conflict` |
| network or auth failure | none | stays `pendingMirror` and retries with backoff. **Never** reported as mirrored |

**A device write is not durable until it is `mirrored`.** Nothing downstream
reads the device copy as authoritative.

## 7. Conflict resolution

*Settled* (G4): "where the two disagree, the SCS POD is correct", and resolution
is toward the SCS copy. *Proposed* mechanics:

1. The device **adopts the POD's version** as its record of that sample, and
   never overwrites a POD resource it has not observed (every update is `If-Match`).
2. It writes `sync/conflicts/<uuid>.ttl` with both content hashes, both
   timestamps and the device id, so nothing is silently discarded.
3. PIM surfaces open conflicts through its existing reconciliation model
   (`src/reconciliation.ts`: `action: "conflict"`, `status: "changed"`) for owner
   review. Owner-chosen outcomes are written by PIM to the POD, and the device
   picks them up on its next read.

## 8. Manifest, provenance and audit (proposed)

- `sync/manifests/<device-id>.ttl`: last successful mirror time, counts by
  state, and the HealthKit anchor the mirror has reached. PIM's status endpoint
  reads it to report pending and conflict counts alongside `observationCount`.
- `provenance/<uuid>.ttl`: PROV `wasGeneratedBy` the bridge app, the HealthKit
  source name, and the consent it was mirrored under.
- `audit/`: an append-only event per mirror, conflict and consent change.
  Counts and ids only, **never values**, the same privacy line as the Patient
  tab.

## 9. Security

*Settled* (Phase 0):
- Plain HTTP is development-only. **HTTPS, or an owner-local tunnel, is
  required before PHI mirrors anywhere beyond local review.**
- Tokens, refresh tokens and DPoP keys never appear in UI, logs, manifests or
  audit records.

## 10. Verification: the mirror leg

G4 asks for "a mirror leg in the local lane, so the authority rule is enforced
by a test rather than by agreement". It is proposed as a CI local-lane stage,
beside `healthkit-bridge`, against a local CSS:

1. **Happy path.** Mirror the simulator's seeded samples, then assert:
   `observations/` holds one resource per sample UUID; PIM's status endpoint
   reports that count; and re-running mirrors nothing new (idempotence).
2. **Conflict.** Pre-create one sample's resource in the POD with different
   content, then mirror, and assert: the POD resource is **unchanged** (SCS
   wins), the device reports `conflict`, and `sync/conflicts/<uuid>.ttl` exists.
3. **No consent, no mirror.** With the family's consent revoked, a new sample
   produces no POD write.

## Decisions open

- **D2 (MVP_ROADMAP):** does the mirror **block the MVP**, or ship as a stated
  limitation ("authority is by agreement, not enforced by a test")? Building it
  needs PM-3 and PM-4 first.
- **D2a, consent:** standing per-family consent (proposed) or per-batch owner
  approval.
- **D2b, coverage:** blood pressure only for MVP, or add PIM codes (or
  containers) for exercise and sleep.

## Build order, once decided

| Step | Repo | Depends on |
|---|---|---|
| PM-3: live Solid-OIDC sign-in from the Pod tab | this repo | — |
| PM-4: container and resource CRUD against local CSS | this repo | PM-3 |
| Mirror writer: §3–§8, `HKSample.uuid`, If-None-Match/If-Match, manifest | this repo | PM-4, D2a, D2b |
| Status endpoint reads the manifest; conflicts appear in the reconciliation view | PIM | mirror writer |
| Mirror leg (§10) in the local lane | RealityEngine_CI | both |
