# Mirror contract: HealthKit bridge → PIM → owner POD

Status: **decided 2026-09-25, implementation in progress.** The owner decided
D2, D2a, D2b and the API surface (see *Decisions*). *Settled* parts cite their
source. Parts still marked *proposed* are implementation detail that the PRs
implementing them may refine.

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

## 2. Which metrics: all of them, from a catalog

*Decided (D2b):* **every health metric** the bridge can read goes to the PIM, not
just the three families PE ingest uses.

PIM holds a **metric catalog**: data, not code. Each entry maps one HealthKit
type identifier to where and how PIM stores it:

| Field | Meaning |
|---|---|
| `metric` | the HealthKit type identifier (`HKQuantityTypeIdentifierHeartRate`, `HKCategoryTypeIdentifierSleepAnalysis`, `HKCorrelationTypeIdentifierBloodPressure`, …) |
| `domain` | `vital-signs` when PIM already has a vital-sign code for it; otherwise the new generic **`health-observations`** domain |
| `code`, `loinc`, `unit` | the PIM code, the LOINC code and the UCUM unit it is stored with |
| `category` | `vital-signs`, `activity`, `body`, `sleep`, `nutrition`, `respiratory`, `mindfulness`, … |
| `valueShape` | `scalar`, `components` (e.g. systolic/diastolic), or `interval` (sleep stages, workouts) |

- **The nine vital-sign metrics** (blood pressure, heart rate, body weight and
  height, BMI, respiratory rate, body temperature, oxygen saturation, blood
  glucose) land in the existing `vital-signs` domain, so they reconcile with
  Epic's.
- **Everything else** (steps, active and basal energy, exercise time,
  distance, sleep analysis, workouts, heart-rate variability, resting heart
  rate, body fat, mindful minutes, …) lands in **`health-observations`**. That is
  a generic FHIR-`Observation`-shaped domain with its own ShEx shape, so adding
  a metric is a catalog entry, not a schema change.
- A metric the catalog does not know is **reported, never dropped silently**.

Values are the **raw measurements** with their units. The `[0,1]` normalization
is a PE concern (`INGEST_CONTRACT.md`), so the mirror takes each `HKSample`
**before** normalization.

## 3. Identity, and why duplicates cannot occur

*Settled by PIM's existing reconciliation.* PIM already identifies a vital sign by
`code::effectiveDateTime` (`reconciliationKey`, used by the Epic import). The
mirror uses the **same key** for `vital-signs`, and `code::effectiveStart` for
`health-observations`. So a HealthKit reading and an Epic reading of the
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

## 4. The API surface (decided: preview and apply)

**Decided: a HealthKit import that mirrors the Epic one.** PIM already
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

(A no-new-routes fallback was considered and not chosen: it would duplicate
PIM's matching logic on the device and read the whole domain on every sync.)

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

## 7. Consent: approval per batch, and a dynamic approved-metric set

Two separate owner controls, both decided:

**(a) Per-batch approval (D2a).** Nothing is written without the owner approving
**that batch**. The bridge calls `preview`, shows the owner the candidates as
PHI-safe counts per metric (creates, unchanged, conflicts, excluded), and only
after the owner approves calls `apply` with PIM's `x-opencommons-owner-approved:
true` header. `apply` re-derives the batch from the same request body, as Epic's
does, so what is applied is what was previewed.

**(b) The approved-metric set, which changes at runtime (D2b).** The owner decides which
metrics may be mirrored at all, and **changes that at any time**. PIM stores the
set in the owner's POD and every path honors it:

| Route | Does |
|---|---|
| `GET /api/integrations/healthkit/metrics` | the catalog, each metric's state, and the set's `generation` |
| `POST /api/integrations/healthkit/metrics` | `{ action: "add" \| "lock" \| "remove", metrics: [...] }`. It requires the owner-approval header, bumps `generation`, and is recorded in pod activity |

The actions and states are **the same as the PE ingest scope** in
`INGEST_CONTRACT.md` (*Scope and resync*). That section was written expecting
"the Solid pod authorization workflow" to drive it with `source: "pim"`, and
this set is that workflow:

| State | Mirror (`preview`/`apply`) | Records already in the POD |
|---|---|---|
| `active` | mirrored | — |
| `locked` | held: `excluded`, `reason: "locked"` | kept |
| `removed`, or never added | `excluded`, `reason: "not-in-scope"` | **kept**. Deleting is a separate, explicit owner action |

- **Open until declared.** As with PE scope, until the owner first sets the
  approved set, the catalog defaults apply. After that, only `active` metrics
  mirror.
- **Honored everywhere, not just in PIM.** On each change PIM also posts the same
  `add`/`lock`/`remove` to every PE's `POST /api/integrations/healthkit/scope`
  (`source: "pim"`) when a PE is configured, so ingest follows the owner's set
  too. The bridge reads the set and **reads only approved metrics** from
  HealthKit. A metric that becomes approved triggers the bridge's HealthKit
  authorization request for it, and one that is removed stops being read.
- Every change carries the new `generation`, so a bridge holding a stale set is
  detectable, and PIM refuses a batch declared against an older generation
  (`409`).

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

## Decisions (owner, 2026-09-25)

- **D2: the mirror blocks the MVP.** `release-v0.1.0` is not cut until the mirror
  is built and its CI leg is green.
- **D2a: owner approval for each batch** (§7a).
- **D2b: every health metric goes to the PIM**, and the approved set can be
  **changed at runtime and is honored** everywhere (§2, §7b).
- **Surface: `healthkit/sync/preview` + `apply`** (§4).

## Build order

| Step | Repo | Depends on |
|---|---|---|
| Metric catalog; `health-observations` domain + ShEx; provenance on vital signs; approved-metric set in the POD (`/metrics`); bridge token; status counts HealthKit-sourced records | PIM | — |
| `healthkit/sync/preview` + `apply`, reusing `reconcile()` / `summarizeReconciliation()`; generation check; scope push to PEs | PIM | the above |
| `PIMClient`; read only approved metrics (authorization follows the set); `HKSample.uuid` + raw values; preview → owner approval → apply; mirror state from PIM's response | this repo | PIM routes |
| Mirror leg (§8) in the local lane | RealityEngine_CI | both |
