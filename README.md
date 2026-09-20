# energy-hub

An API-led integration layer over German day-ahead electricity prices and
grid generation data, built on MuleSoft and deployed on the Mule runtime
Community Edition.

Three public upstreams, one canonical model, one clean API.

---

## Status

In progress. Built in the open, one layer at a time.

| Component | State |
|---|---|
| **aWATTar system API** | Complete — spec-driven routing, canonical mapping, 5 MUnit tests, deployed and serving |
| ENTSO-E system API | Next — awaiting Transparency Platform API credentials |
| Process API | Planned — source merging, cheapest-window logic, persistence |
| Experience API | Planned |
| Alerting | Planned |
| Containerised deployment | Planned |

What exists is finished rather than scaffolded: the aWATTar module has a
RAML contract that is enforced at runtime, a test suite that runs offline,
and error responses that match the spec.

---

## Why the layers are where they are

| Layer | Owns | Never contains |
|---|---|---|
| **System** | Upstream credentials and dialect, mapping to canonical types | Caching, aggregation, business rules |
| **Process** | Orchestration, source merging, price-window logic, persistence | Request shaping for a specific client |
| **Experience** | Response shaping for one consumer, field selection | Anything a second consumer would also need |

The test for whether a boundary is real: adding a fourth upstream should
mean writing one new system API and changing one scatter-gather route. If
it forces a change in the experience layer, the boundary leaked.

---

## The canonical model

Every layer speaks the same types, defined once in RAML. System APIs are
responsible for translating their upstream's native format into them, so
nothing downstream sees an upstream's vocabulary.

```json
{
  "startsAt": "2026-09-17T22:00:00Z",
  "endsAt": "2026-09-17T23:00:00Z",
  "resolutionMinutes": 60,
  "pricePerMWh": 139.24,
  "pricePerKWh": 0.13924,
  "currency": "EUR",
  "source": "AWATTAR"
}
```

`source` is deliberately part of the model. When the process layer merges
competing feeds, or falls back to cached data, the consumer can see where
a number came from.

---

## Running it

Requires JDK 17 and Maven 3.9+. No Anypoint subscription and no Anypoint
Studio — this is a plain Maven build.

```bash
cd sys-api-awattar
mvn clean test          # 5 MUnit tests, no network required
mvn clean package       # produces target/*-mule-application.jar
```

Deploy to a standalone Mule CE runtime by copying the jar into its
`apps/` folder, then:

```bash
curl 'localhost:8092/api/sys/awattar/v1/marketdata'
```

### The RAML is load-bearing

APIkit reads the spec at deploy time and enforces it before any flow code
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

Add a resource to the RAML without a matching flow and the application
refuses to deploy. A spec that can drift from the implementation is
documentation, not a contract.

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

**Every test mocks the upstream.** The suite never touches the network, so
the build is deterministic and the "auction has not cleared yet" case —
otherwise only reproducible before 13:00 CET — can be tested on demand.

**Fixtures are captured responses, not hand-written JSON.** Invented test
data would have hidden both the millisecond timestamps and a silent
day-boundary clipping bug, where requesting a full day with an end bound of
23:59 returns 23 hourly points instead of 24.

**Errors carry a correlation ID.** Every response, success or failure, is
traceable to a log line.

**Empty is not an error.** An upstream returning no data for an uncleared
auction maps to an empty array with a 200, not a 502. The process layer
decides what to do about it.

---

## What broke along the way

[`NOTES.md`](NOTES.md) is a running log of the things that failed and what
the causes turned out to be — a DataWeave type-inference quirk found by
bisection, an upstream boundary condition that fails silently, and the
Enterprise-only features that shaped the architecture.

It is kept as written rather than tidied up afterwards.
