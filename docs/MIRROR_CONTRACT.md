# Mirror contract: HealthKit bridge → PIM → owner POD

Status: **proposed, 2026-09-25.** *Settled* parts cite their source. *Proposed*
parts await the decisions listed at the end. Nothing here is implemented yet.

This is the single source of truth for **how** device-side HealthKit data
reaches the authoritative POD. **Whether** that is the rule is decided once, in
`RealityEngine_CI/docs/MVP_ROADMAP.md` G4. This file specifies the mechanics G4
left open (its D2).

It is separate from `INGEST_CONTRACT.md`. Ingest sends normalized 4-vectors to
the Perception Engine for the perceptual space. The mirror sends the underlying
readings to the owner's POD for durable ownership. Both stay, and neither
depends on the other.

---

## 1. The data path: the bridge talks to PIM, and PIM owns the POD

*Settled (owner, 2026-09-25).* The bridge does **not** speak Solid. It calls the
OpenCommons Health PIM's HTTP API, and PIM uses the facilities it already has:

```text
iPhone bridge app ──HTTP──▶ PIM  ──(PIM's own Solid session)──▶ SCS POD
                            ├─ repositories + ShEx validation per domain
                            ├─ reconciliation (create / unchanged / update / conflict)
                            ├─ pod activity + audit
                            └─ owner-approval header convention
```

| Party | Role |
|---|---|
| **Bridge app** (this repo) | client of PIM's API. Holds no Solid session, tokens, or pod URLs |
| **PIM** (`OpenCommons-Health---Personal-Information-Management`) | the **only writer** to the POD. It already authenticates to the Solid server server-side (`HealthPIM.isAuthenticated`) and every domain write goes through it |
| **Solid Community Server** | holds the **authoritative POD** (G4) |

**Consequence:** the Solid-in-app phases PM-3 (sign-in) and PM-4 (CRUD) in
`MOBILE_SOLID_PHASE0_COMPATIBILITY.md` are **not on the mirror path**. The Pod
tab shows PIM's status instead of holding its own session.

## 2. What maps today, with no PIM change

The PIM domain is **`vital-signs`**: `POST /api/resources/vital-signs`, validated
by `vitalSigns.shex`. It accepts `blood-pressure` (with `{systolic, diastolic}`)
and `heart-rate`, among others.

| Bridge family | HealthKit source | PIM `vital-signs` entity |
|---|---|---|
| Blood pressure | `HKCorrelationTypeIdentifierBloodPressure` (systolic + diastolic) | `{ code: "blood-pressure", value: { systolic, diastolic }, unit: "mmHg", effectiveDateTime, loincCode: 85354-9 }` |
| Pulse | the family's heart-rate component | `{ code: "heart-rate", value: <bpm>, unit: "/min", effectiveDateTime, loincCode: 8867-4 }` |
| Exercise | workout, steps, active energy, exercise time | **no vital-sign code** (D2b) |
| Sleep | `HKCategoryTypeIdentifierSleepAnalysis` | **no vital-sign code** (D2b) |

- Values are the **raw measurements** with their units. The `[0,1]`
  normalization is a PE concern (`INGEST_CONTRACT.md`), so the mirror takes each
  `HKSample` **before** normalization.
- `effectiveDateTime` is the sample's `startDate` in ISO 8601.

## 3. Identity, and why duplicates cannot occur

*Settled by PIM's existing reconciliation.* PIM already identifies a vital sign by
`code::effectiveDateTime` (`reconciliationKey`, used by the Epic import). The
mirror uses the **same key**. So a HealthKit reading and an Epic reading of the
same measurement at the same instant **reconcile** rather than duplicate, and
re-sending a sample is a no-op.

| PIM finds, for the key | Outcome | Bridge mirror state |
|---|---|---|
| no record | create | `mirrored` |
| one record, same normalized values | unchanged | `mirrored` (a retry that already landed) |
| one record, **different** values | **conflict: the POD wins** (G4). The device does **not** overwrite it | `conflict` |
| more than one record | conflict (ambiguous) | `conflict` |

The device never updates a POD record. **Resolution is toward the SCS copy**
(G4, and the bridge ROADMAP), and a conflict is surfaced in PIM's existing
reconciliation view for the owner. `MobilePodModel`'s states map one to one:
`pendingMirror` (queued, or not yet acknowledged by PIM), `mirrored`, `conflict`.

**A device reading is not durable until PIM reports it `mirrored`.** Nothing
downstream reads the device copy as authoritative.

## 4. The API surface (proposed)

**Recommended: a HealthKit import that mirrors the Epic one.** PIM already
imports an external source this way (`/api/integrations/epic/sync/preview` and
`…/sync/apply`), built from `reconcile()` and `summarizeReconciliation()`. The
same shape for HealthKit:

| Route | Does |
|---|---|
| `POST /api/integrations/healthkit/sync/preview` | the bridge submits a batch of samples; PIM maps them (§2), reconciles them (§3), and returns the candidates and summary. Nothing is written |
| `POST /api/integrations/healthkit/sync/apply` | writes `create`s, skips `unchanged`, holds `conflict`s for review. **Requires `x-opencommons-owner-approved: true`**, PIM's existing owner-approval header (`src/privacy.ts`) |
| `GET /api/pod/healthkit/status` | *exists*; extended per §5 |

This keeps the mapping and matching in **one place, PIM**, beside the Epic code
it reuses. The bridge sends readings and records the outcome per sample.

**Works today without new routes:** the bridge can `GET /api/resources/vital-signs`,
apply the same key itself, and `POST` only the new readings. That is acceptable
for a first slice, but it duplicates PIM's matching logic on the device and reads
the whole domain on every sync. So it is the fallback, not the target.

## 5. PIM changes needed (proposed)

1. **Provenance.** `VitalSign` has no source or identifier, so a HealthKit reading
   is indistinguishable from an Epic or manual one. Add an optional
   `source: { system: "healthkit", identifier: <HKSample.uuid>, device? }`, with
   the matching ShEx and RDF triple. The UUID is carried for audit; matching stays
   on §3's key.
2. **The HealthKit status surface counts the wrong place.** `/api/pod/healthkit/status`
   counts `health-pim/healthkit/observations/`, but this path writes to the
   `vital-signs` domain, so it would report 0. It should count vital signs whose
   `source.system` is `healthkit`, and report pending and conflict counts from
   the last sync.
3. **Client authentication for HealthKit writes.** PIM's API authenticates to
   the Solid server but **not its own clients**, which is fine on loopback.
   Accepting writes from an iPhone means listening beyond loopback, so the
   HealthKit routes need a bridge token (a `PIM_HEALTHKIT_BRIDGE_TOKEN`, checked
   the way the PE checks `HEALTHKIT_BRIDGE_TOKEN`).
4. **HTTPS** beyond local review. This is the Phase 0 constraint, now applying
   to the bridge→PIM hop.

## 6. Bridge changes (proposed)

- A `PIMClient` beside `IngestClient`, configured with the PIM base URL and bridge
  token, with batching and backoff like ingest. Tokens are never logged.
- It captures `HKSample.uuid`, `startDate` and raw values before normalization.
  The ingest payload carries no sample identity today (`Models.swift`), and
  ingest is **unchanged**.
- It records per-sample mirror state from PIM's response. A network or auth
  failure leaves `pendingMirror` and is never reported as mirrored.

## 7. Consent

*Settled* (Phase 0 privacy constraint): nothing identifiable mirrors without
owner approval. *Proposed*: `apply` requires PIM's existing owner-approval
header. Whether the app sends it per batch after an explicit tap, or from a
standing per-family consent the owner grants once, is **D2a**.

## 8. Verification: the mirror leg

G4 asks for "a mirror leg in the local lane, so the authority rule is enforced
by a test rather than by agreement". It is proposed as a CI local-lane stage
beside `healthkit-bridge`, against PIM and a local CSS:

1. **Happy path.** Mirror the simulator's seeded blood-pressure samples. Assert
   one `vital-signs` record per reading with `source.system = healthkit`, that
   the status endpoint counts them, and that re-running creates nothing
   (idempotence through §3's key).
2. **Conflict.** Pre-create a record with the same key and different values,
   then mirror. Assert the POD record is **unchanged** (the SCS wins), the bridge
   reports `conflict`, and PIM's reconciliation view lists it.
3. **No approval, no write.** `apply` without the owner-approval header is
   refused (403), and nothing is written.

## Decisions open

- **D2 (MVP_ROADMAP):** does the mirror block `release-v0.1.0`, or ship as a
  stated limitation? The PIM data path makes it much smaller than an in-app
  Solid client would have been.
- **D2a, consent:** per-batch owner approval, or a standing per-family consent.
- **D2b, coverage:** blood pressure and pulse only (they map to existing PIM
  codes), or add PIM codes or domains for exercise (LOINC 55411-3) and sleep
  (93832-4).
- **§4 surface:** the recommended Epic-style `sync/preview` + `sync/apply`, or
  the no-new-routes fallback for a first slice.

## Build order

| Step | Repo | Depends on |
|---|---|---|
| Provenance field; status counts HealthKit-sourced vitals; bridge token on HealthKit routes | PIM | — |
| `healthkit/sync/preview` + `apply`, reusing `reconcile()` / `summarizeReconciliation()` | PIM | provenance; §4 decision |
| `PIMClient`, `HKSample.uuid` capture, mirror state from PIM's response | this repo | PIM routes (or the fallback) |
| Mirror leg (§8) in the local lane | RealityEngine_CI | both |
