# Mobile PIM UX Parity Contract

This document records the HealthKitBridge iPhone UX decisions for GitHub issues
#12 through #17. The goal is to keep the mobile Patient Monitor equivalent to
the OpenCommons Health browser PIM without changing the validated HealthKit →
Perception Engine ingest contract.

## Scope

The mobile app remains an owner-controlled companion to the localhost/docker
OpenCommons Health PIM and Solid Community Server. It surfaces:

- Patient Monitor source status for HealthKit, Epic, and Solid Pod.
- Eleven OpenCommons Health PIM domains.
- Second-level semantic spider graphs aligned to the browser PIM semantic-domain
  contract.
- Durable local staging for manually added data until Solid resource CRUD is
  wired through the mobile Solid package adapter.
- Legal and disclosure document links served by the configured local PIM stack.

No tokens, DPoP keys, refresh tokens, raw PHI, or full Pod resource bodies are
shown in the mobile status UI.

## Implemented issue mapping

| Issue | Mobile behavior |
| --- | --- |
| #12 | Patient Monitor exposes a top-right hamburger-style owner menu. SwiftUI `Menu` starts closed by default and exposes refresh, Terms, and Data Disclosure actions. |
| #13 | Patient Monitor includes a bottom Daily Plan section with a weekday selector, hourly timeline ticks, and planned activity markers. The first default activity is the morning medication regimen. |
| #14 | Mobile semantic graph nodes mirror the PIM contract. Vitals are Blood pressure, Heart rate, Temperature, Oxygen saturation, Body weight, and BMI. HealthKit-only Activity, Sleep, and Provenance remain source/mirror metadata, not PIM Vitals nodes. |
| #15 | Mobile Pod defaults now point to the local OpenCommons owner Pod contract (`css.localhost` / `jateeter`) rather than the placeholder `alice` Pod. The app can refresh `/healthz` from the configured local PIM base URL and reflect browser-confirmed owner Pod access. |
| #16 | Add flow now stages a durable owner-approved draft in `UserDefaults` and increments the mirror/audit queue. The button is labeled `Stage for owner review` so it does not imply direct Pod write-through before Solid resource CRUD is connected. |
| #17 | Patient and Pod screens expose Terms and Data / Information Disclosure links resolved from the configured local PIM base URL. |

## Semantic graph contract

The iPhone app mirrors the browser PIM contract by value in
`App/Sources/MobilePodModel.swift`. The mobile model includes:

- Domain IDs matching the 11 browser PIM domains.
- Element IDs and display names matching the browser PIM semantic contract.
- FHIR element names.
- Coding system display/URL/code/display where applicable:
  - LOINC: `http://loinc.org`
  - RxNorm: `http://www.nlm.nih.gov/research/umls/rxnorm`
  - SNOMED CT: `http://snomed.info/sct`
  - CVX: `http://hl7.org/fhir/sid/cvx`

Run:

```bash
scripts/validate_mobile_pim_parity.py
```

to guard against the known parity regressions.

## Local PIM/CSS status binding

The default mobile configuration is:

- Local PIM base URL: `http://localhost:18080`
- CSS issuer URL: `http://css.localhost:13000/`
- Owner storage IRI: `http://css.localhost:13000/jateeter/`

For a physical iPhone, replace the Local PIM base URL with the notebook LAN
address, for example `http://192.168.1.194:18080`. The app reads the PIM
`/healthz` response and treats `ok: true` plus `podAccess: true` as the browser
PIM’s owner-Pod status reflection.

## Add-flow MVP semantics

The mobile Add modal does not claim direct Solid Pod write-through. It stages a
metadata envelope containing:

- Domain and semantic element ID.
- FHIR element.
- Coding-system metadata.
- Owner-entered value and note.
- Local staging timestamp.

This creates a durable owner-review queue visible in the Patient Monitor and
Pod mirror state. Direct SolidResourcesSwift CRUD can replace the local staged
queue in a later phase without changing the visible UX contract.
