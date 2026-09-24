# Build notes

Running log of things that broke and what the cause turned out to be.
Kept as they were found, not cleaned up afterwards — the README's
"what actually went wrong" section is written from here.

---

## aWATTar: `end` filters on the interval's end, not its start

Requesting a full delivery day with `end` = 23:59 local returns **23**
points, not 24. The last interval of the day runs 23:00→00:00, and its
end timestamp falls past the boundary, so it is dropped.

Fix: pass the **following midnight** as `end`.

Kept the 23-point response as `awattar-clipped-range.json` and wrote a
regression test around it, because the failure is silent — the response
is well-formed, just short by one hour.

## aWATTar: no parameters means a rolling window, not today

`GET /v1/marketdata` with no bounds returns 24 hourly points starting at
the **current hour**, so it spans two calendar days. Useful, but not a
substitute for an explicit range, and a test that assumes midnight
alignment will fail depending on when it runs.

## aWATTar: an uncleared auction is 200 with an empty array

Asking for a day whose auction has not cleared (before ~13:00 CET for
tomorrow) returns HTTP 200 with `data: []`, not a 404. That is a normal
daily state, so the mapper returns `[]` and the process layer decides
whether to treat it as degraded.

---

## DataWeave: a declared return type breaks on an `Object`-typed parameter

```
fun toCanonical(doc: Object): Array<Object> = ...
```

fails with *"Expecting Type: `Array<Object>`, but got: `Any`"*. Indexing
into a bare `Object` yields `Any`, so the checker cannot prove the
declared return type.

Fix: drop the annotations on document-shaped parameters. Scalar
parameters (`millis: Number`) annotate fine and are worth keeping.

Found by bisecting — added each construct back one at a time. The error
was reported at line 1 and looked like a syntax problem, which sent the
first twenty minutes in the wrong direction.

## DataWeave: an inline expression mixing payload and computed values

```
#[sizeOf(payload filter ((p) -> p.pricePerKWh != round(...)))]
```

fails with *"Unable to infer a output media type as more than one is
being used: application/json, application/java"*. The payload is JSON,
the arithmetic is java, and a bare `#[...]` cannot choose.

Fix: prefix with an explicit directive —
`#[%dw 2.0 output application/java --- ...]`.

Expect this again in the ENTSO-E mapper, where XML input meets computed
timestamps.

---

## Mule CE: what is not available

Three Enterprise-only features shaped this design:

| Feature | Consequence here |
|---|---|
| `ee:transform` (Transform Message) | All mapping uses `set-payload` with inline DataWeave importing a module. Better for testing anyway — MUnit calls the functions directly. |
| Batch scope | The scheduled poll uses a plain scheduler and `foreach`. |
| MUnit coverage | The CI gate is pass/fail, not a percentage. `Coverage is a EE only feature and you've selected to run over CE`. |

API Manager policies are also Enterprise-only, so rate limiting and auth
have to live in the flow or in a reverse proxy.

## Mule: the launcher script does not run under Git Bash

`./bin/mule` fails with *"Unable to locate any of the following
binaries: .../wrapper-mingw64_nt-10.0-26200-x86-64"*. The script derives
the wrapper name from `uname`, which reports `MINGW64_NT` under Git
Bash, and the distribution ships Windows and Linux wrappers but no MINGW
one.

Fix: run `bin\mule.bat` from PowerShell.

Also worth knowing: the only Windows wrapper in the 4.6.0 distribution is
`wrapper-windows-x86-32.exe`. A 32-bit wrapper launching a 64-bit JVM
works, but caps the heap that can be requested.

## Built without Anypoint Studio

The Studio download page returned *"Oops, something went wrong"* across
two days, so the project is a plain Maven build: `mule-application`
packaging, the `mule-maven-plugin` as a build extension, and the
standalone CE runtime for deployment.

This turned out to suit the target anyway — Studio's most-used feature is
the Transform Message component, which CE does not have. `mvn clean
package` produces the deployable jar; dropping it in the runtime's
`apps/` folder is the same step the Docker deployment will use.

---

# ENTSO-E system API (in progress)

## Mule YAML properties must be quoted strings

`entsoe.timeoutMs: 20000` in `config.yaml` stops the application deploying:

```
YAML configuration properties only supports string values, make sure to
wrap the value with " so you force the value to be an string.
```

Every value needs quoting, numbers included. The `${...}` placeholders still
resolve where they are used, so `port: "8091"` works fine as a listener port.

## `some` lives in dw::core::Arrays, not core

`declared some ($.position == slot)` fails with *"Unable to resolve reference
of: `some`"*, and then reports a second error for `$`, because the lambda's
parameter cannot resolve either once the function does not. One cause, two
errors. Either import it, or use `sizeOf(... filter ...) == 0`.

## ENTSO-E timestamps carry no seconds

The guide documents `timeInterval` as `yyyy-MM-ddTHH:mmZ`. DataWeave will not
coerce that to `DateTime` directly, hence `normaliseInstant` in the mapper,
which tolerates both forms.

## A44 uses curveType A01

Per the user guide, so every position should be present and the sparse
expansion in the mapper is insurance rather than the expected path. The flow
logs a WARN if any other curve type appears, so a silent change upstream
becomes visible.

## Reading the payload more than once silently truncates it — OPEN

**The most dangerous bug on the project so far, and not yet fixed.**

The flow inspected the response three times: is it an Acknowledgement, what
curveType does it use, then the mapping. The payload is a non-repeatable
stream, so each traversal consumed more of it. By the third, only the final
`<Point>` remained.

The result was a well-formed response: 24 intervals, correct timestamps,
internally consistent per-kWh conversion — and every price set to 155.60, the
last point in the document. No error. No warning. A flat 24-hour price curve
that no schema check would catch, and the alerting layer would simply never
fire.

What proved it: a probe that read the file and traversed it **once** in a
single expression returned all 24 points. The same navigation applied to
`payload` after an earlier traversal returned 1 — position 24.

How it was nearly missed: every assertion about structure passed. Only the
assertions on actual values failed.

Three wrong hypotheses were chased first — a `$` binding in a nested lambda,
type annotations on document-shaped parameters, and the XML reader collapsing
repeated siblings. Each was plausible, each was tested in the playground
where the code worked fine, and each was wrong because the playground never
reproduced the repeated-traversal conditions. The lesson is to measure inside
the failing environment early rather than reason from symptoms.

### Where it stands

Attempted fix: serialise the body once with `write(payload,
'application/xml')` and parse from that string at each use. That throws:

```
Trying to output non-whitespace characters outside main element tree
(in prolog or epilog), while writing Xml
```

Caused by the explanatory `<!-- -->` comment blocks in the fixtures, which
DataWeave treats as prolog content and refuses to re-emit. Comments were moved
to `samples/README.md` and the fixtures cleaned, but the suite is still red:
4 errors, 1 failure.

### Start here next session

1. Get the current error message — it may no longer be the prolog one.
2. If `write` is still the problem, try materialising differently rather than
   round-tripping through XML text: read the response as a string before any
   parsing, or restructure the flow so the document is traversed exactly once
   and the three answers come out of a single expression.
3. Check whether the real HTTP response behaves the same way. The Mule HTTP
   connector uses repeatable streams by default, so production may differ from
   the MUnit mock, which uses `readUrl`. If so, the test is stricter than
   reality — still worth fixing, but the priority changes.

The aWATTar module is unaffected and stays green; CI only builds that module
so far.

---

# What real ENTSO-E data looked like

Credentials arrived 2026-09-24. Captured DE-LU day-ahead prices for delivery
day 2026-09-25 and compared against the synthetic fixture the mapper had been
built on.

Four of five structural assumptions were wrong.

| Assumed (from the archived user guide) | Actual |
|---|---|
| namespace `...publicationdocument:7:0` | **`:7:3`** |
| `curveType` A01 — every position present | **A03** — sparse, repeated values omitted |
| `PT60M`, 24 points | **`PT15M`**, 96 positions |
| one `TimeSeries` | **two** |
| `timeInterval` timestamps without seconds | confirmed correct |

The acknowledgement document's namespace (`...acknowledgementdocument:7:0`)
and reason code 999 were right.

## Every namespaced selector would have returned nothing

With `7:0` declared against a `7:3` document, `pub#TimeSeries` and everything
below it resolves to null. No error — an empty result. This is the second
time on this project that a wrong assumption produced silence rather than a
failure.

## Two TimeSeries, and document order is not sequence order

A44 for DE-LU returns two series covering identical intervals at identical
resolution, distinguished only by
`classificationSequence_AttributeInstanceComponent.position`:

- **sequence 1** — the primary day-ahead auction (EPEX SPOT)
- **sequence 2** — the separate EXAA auction held at 10:15 CET

Flattening both gives two prices for every interval. And the trap: in the
captured response the **first** TimeSeries in document order carries sequence
**2**, so `TimeSeries[0]` picks EXAA. The filter must be on the classification
field.

## Verified against an independent publisher

The sequence explanation came from a GitHub issue thread, not official
documentation, so it was checked rather than trusted:

```
ENTSO-E sequence 1, first four quarter-hours of 2026-09-25:
  196.99 + 184.40 + 175.79 + 170.59 = 727.77 ÷ 4 = 181.9425

aWATTar, same hour, hourly resolution:            181.94
```

An exact match. Sequence 2 opens at 192.55 and does not agree. aWATTar
publishes the same EPEX auction, so this confirms both the auction choice and
the position arithmetic against a source that shares no code with this
project.

That check only existed because the second upstream was built first. It is
now an assertion in the test suite rather than a one-off.

## A03 confirmed in the data

The captured sequence-2 series omits positions 7 and 10 — those intervals
repeat the preceding price. The sparse expansion written as insurance against
a documented A01 turns out to be the real code path.

## Consequence for the process layer

**The two upstreams are now at different resolutions.** ENTSO-E publishes
quarter-hourly, aWATTar hourly, and an aWATTar hour is the mean of four
ENTSO-E quarters.

`mergeSources` as sketched matches points on `startsAt` equality, which would
align only one quarter in four and treat the other three as gaps to fill.
That design needs revisiting before the process API is built — either
downsample ENTSO-E to hourly, upsample aWATTar, or keep both resolutions and
let the consumer choose.

## Lesson

Synthetic fixtures are worth building to get logic moving, and worth
distrusting completely. Every test written against the synthetic document
passed while the mapper would have failed against production — the fixture
and the code shared the same wrong assumptions, so they agreed with each
other and not with reality.
