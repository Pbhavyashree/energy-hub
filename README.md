![CI](https://github.com/Pbhavyashree/energy-hub/actions/workflows/ci.yml/badge.svg)

# energy-hub

An API-led integration layer over German day-ahead electricity prices, built
on MuleSoft and deployed on the Mule runtime Community Edition.

Two independent upstreams, one canonical model, one clean API.

---

## Status

In progress. Built in the open, one layer at a time.

| Component | State |
|---|---|
| **aWATTar system API** | Complete — spec-driven routing, canonical mapping, 5 MUnit tests |
| **ENTSO-E system API** | Complete — built against real captured responses, 6 MUnit tests |
| Process API | Next — source merging, cheapest-window logic, persistence |
| Experience API | Planned |
| Alerting | Planned |
| Containerised deployment | Planned |

What exists is finished rather than scaffolded: both modules have RAML
contracts enforced at runtime, test suites that run offline, and error
responses that match their specs.

---

## Why the layers are where they are

| Layer | Owns | Never contains |
|---|---|---|
| **System** | Upstream credentials and dialect, mapping to canonical types | Caching, aggregation, business rules |
| **Process** | Orchestration, source merging, price-window logic, persistence | Request shaping for a specific client |
| **Experience** | Response shaping for one consumer, field selection | Anything a second consumer would also need |

The test for whether a boundary is real: adding a third upstream should mean
writing one new system API and changing one route. If it forces a change in
the experience layer, the boundary leaked.

The canonical RAML library lives once, at `shared-specs/`, and is copied into
each module at build time. Per-module copies are generated and gitignored, so
the two system APIs cannot drift apart on the model they both speak.

---

## The canonical model

```json
{
  "startsAt": "2026-09-24T22:00:00Z",
  "endsAt": "2026-09-24T22:15:00Z",
  "resolutionMinutes": 15,
  "pricePerMWh": 196.99,
  "pricePerKWh": 0.19699,
  "currency": "EUR",
  "source": "ENTSOE"
}
```

`source` is deliberately part of the model. When the process layer merges
competing feeds or falls back to stored data, the consumer can see where a
number came from.

---

## Two upstreams, one auction

Both system APIs publish the same EPEX SPOT day-ahead auction, which makes
them a check on each other.

**aWATTar** serves plain JSON, hourly, no authentication.

**ENTSO-E** serves `Publication_MarketDocument` XML, quarter-hourly, and is
considerably less forgiving:

- prices carry no timestamps — each `Point` has a *position*, and the instant
  is `periodStart + (position − 1) × resolution`
- `curveType` is **A03**, so positions whose price repeats the previous one
  are omitted entirely and must be held forward
- a single response contains **two** `TimeSeries` covering identical
  intervals, one per auction sequence — and document order does not match
  sequence order, so taking the first gives you the wrong auction
- "no data published" arrives as HTTP **200** with an `Acknowledgement`
  document, not a 404

### Verified against an independent source

The rule for choosing between the two auction sequences came from a forum
thread, not official documentation — so it was checked rather than trusted:

```
ENTSO-E sequence 1, first four quarter-hours of 2026-09-25:
  196.99 + 184.40 + 175.79 + 170.59 = 727.77 ÷ 4 = 181.9425

aWATTar, same hour, hourly resolution:            181.94
```

An exact match. Sequence 2 opens at 192.55 and does not agree. That check is
now an assertion in the test suite rather than a one-off — and it only exists
because the second upstream was built first.

---

## Running it

Requires JDK 17 and Maven 3.9+. No Anypoint subscription and no Anypoint
Studio — these are plain Maven builds.

```bash
cd sys-api-awattar    # or sys-api-entsoe
mvn clean test        # no network required; every test mocks its upstream
mvn clean package     # produces target/*-mule-application.jar
```

Deploy to a standalone Mule CE runtime by copying the jar into its `apps/`
folder. The ENTSO-E module reads its security token from a system property, so
no credential ever enters the working tree:

```
bin\mule.bat -M-Dentsoe.token=YOUR_TOKEN
```

### The RAML is load-bearing

APIkit reads each spec at deploy time and enforces it before any flow code
runs:

```bash
$ curl -i 'localhost:8092/api/sys/awattar/v1/marketdata?from=not-a-date'
HTTP/1.1 400 Bad Request

{
  "code": "BAD_REQUEST",
  "message": "Invalid value 'not-a-date' for query parameter from ...",
  "correlationId": "e2a47750-b526-11f1-92a2-f4289dfe3c27",
  "occurredAt": "2026-09-20T19:10:04.143Z"
}
```

Add a resource to a spec without a matching flow and the application refuses
to deploy. A spec that can drift from the implementation is documentation, not
a contract.

---

## Built for Mule CE

Community Edition is what makes a permanently-running deployment possible
without a subscription, and it excludes several things most MuleSoft
tutorials assume. Working within those limits shaped the design:

| Not available in CE | What this project does instead |
|---|---|
| `ee:transform` (Transform Message) | `set-payload` with inline DataWeave importing modules from `src/main/resources/modules`. Better for testing — MUnit calls the functions directly. |
| Batch scope | Plain scheduler and `foreach` |
| MUnit coverage | The build gate is pass/fail rather than a percentage |
| API Manager policies | Rate limiting and auth belong in the flow or a reverse proxy |

---

## Design decisions

**Every test mocks its upstream.** The suites never touch the network, so
builds are deterministic and states that are otherwise hard to reach — an
auction that has not cleared yet, an upstream that is down — can be tested on
demand.

**Fixtures are real captured responses.** They started out synthetic, built
from the published schema, and were wrong about the namespace, the curve type,
the resolution and the number of TimeSeries. Every test passed against them
anyway, because fixture and code shared the same wrong assumptions.

**Tests assert on values, not just shape.** The most dangerous bug on this
project produced a perfectly well-formed response with every price silently
identical. Structural assertions all passed.

**Errors carry a correlation ID**, and upstream failures are distinguished:
502 for unreachable, 504 for too slow, 404 for "the upstream answered and had
nothing".

---

## What broke along the way

[`NOTES.md`](NOTES.md) is a running log of the failures and their causes —
a DataWeave type-inference quirk found by bisection, an upstream boundary
condition that fails silently, a non-repeatable stream that turned correct
code into a flat price curve, and the Enterprise-only features that shaped the
architecture.

It is kept as written rather than tidied up afterwards, including the wrong
turns.
