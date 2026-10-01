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

---

# The stream bug — RESOLVED 2026-09-24

The "reading the payload more than once silently truncates it" entry above is
closed. Recording the fix and the two wrong turns, because the wrong turns
cost more than the fix.

## The fix

Take the response body as **text**, not XML:

```xml
<http:request ... outputMimeType="text/plain" outputEncoding="UTF-8">
```

Then materialise it once and parse that string independently at each check:

```xml
<set-variable variableName="rawXml" value="#[payload as String]"/>
...
read(vars.rawXml, 'application/xml')
```

Nothing parses the body on arrival, so there is no stream to exhaust.

## What did not work

**`write(payload, 'application/xml')`** — the obvious way to serialise the
body once. DataWeave's XML writer refuses the value that `readUrl` and the
HTTP connector produce:

```
Trying to output non-whitespace characters outside main element tree
(in prolog or epilog), while writing Xml
```

This was first blamed on the explanatory `<!-- -->` comments in the synthetic
fixtures, which sat before the root element. The comments were removed and the
error persisted, and it persisted again with real captures that never had
comments. The writer simply will not round-trip that value. Do not try this
again.

## Why it took so long

Four hypotheses were tested before the right one, and three were wrong:

1. `$` binding inside a nested lambda — plausible, since a similar error had
   just been hit with `some`. Fixed it; nothing changed.
2. Type annotations on document-shaped parameters — plausible, since that bug
   was real elsewhere in this project. Removed them; nothing changed.
3. The XML reader collapsing repeated siblings — plausible, since a probe
   reported one `<Point>` instead of 24. Wrong reading of the evidence: the
   probe had traversed the payload earlier in the same expression.

Each hypothesis was tested in the DataWeave playground, where the code worked
correctly every time — because the playground never reproduced the condition
that mattered, which was repeated traversal of a live stream.

The probe that settled it ran **inside Mule** and compared five navigations
over the same document. All five returned 1. That ruled out navigation and
pointed at the document itself, and a variant that read the file fresh in a
single expression returned 24.

**Measure inside the failing environment early.** Reasoning from symptoms in a
working environment produced three confident, wrong answers in a row.

## Why it mattered

The symptom was not a crash. It was 96 well-formed intervals, correct
timestamps, internally consistent per-kWh conversion, and every price equal to
the last `<Point>` in the document — a flat price curve that no schema
validation would reject and that would have made the alerting layer
permanently silent.

Only assertions on actual values caught it. Every structural assertion passed
throughout.

---

# The Host header, and why the same request got two different answers

First live call through the ENTSO-E flow returned HTTP 400, while the
identical request sent by hand returned 200.

## Narrowing it

The same URL worked from curl, so the difference had to be inside the flow.
Cheap probes first, each ruling something out:

| Probe | Result | Rules out |
|---|---|---|
| curl with the exact params the flow should send | **200** | the parameters |
| curl with a wrong token | 401 | — |
| curl with an empty token | 401 | — |
| curl with no token at all | 401 | the token entirely — every token fault is 401, and we were getting 400 |

A temporary logger in the flow then printed what it actually computed:

```
zone=DE_LU  eic=10Y1001A1001A82H
rawStart="2026-09-25T00:00:00+02:00"
fmtStart=202609242200  fmtEnd=202609252200  tokenLen=36
```

All correct. Right EIC, right timestamp format, token fully resolved. The
flow was building exactly the request that worked from curl, and still got a
400.

## The wire log

At that point the only remaining difference was *how* the request went out,
which needs the HTTP wire logger:

```xml
<AsyncLogger name="org.mule.service.http.impl.service.HttpMessageLogger" level="DEBUG"/>
```

in `conf/log4j2.xml`. It prints the outbound request line and every header.
The URL was character-for-character identical to the working curl. The
headers were not:

```
Host: web-api.tp.entsoe.eu:443      <- Mule
Host: web-api.tp.entsoe.eu          <- curl
User-Agent: AHC/1.0
```

And the response body — JSON, where the API itself returns XML, which was
itself a clue that a gateway and not the API was answering:

```json
{"uuAppErrorMap":{"uu-gateway-router/invalidRequestHeaders":{
  "message":"Request contains inconsistent Forwarded/Host headers
             resulting in invalid request URL.",
  "cause":{"ERR_INVALID_URL":{"message":"Invalid URL"}}}}}
```

## Cause and fix

Mule's HTTP requester always builds the Host header as `host:port`, so an
HTTPS call on 443 sends `web-api.tp.entsoe.eu:443`. That is legal, and
ENTSO-E's gateway rejects it. curl omits the port for a default-port URL and
is accepted.

Fix — override the header explicitly on the request:

```xml
<http:headers><![CDATA[#[{
    "Host": p('entsoe.host')
}]]]></http:headers>
```

There is a comment in the flow saying not to remove it.

## Worth remembering

Nothing about the request *as the flow computed it* was wrong. Every value
checked out. Tools that report what your code intends will never show this
class of failure — only a log of the bytes actually leaving the process.

Also: the response's content type was the tell. An API that returns XML
answering with JSON means something in front of it is doing the talking.

## Housekeeping

The wire log writes full URIs, so the security token ends up in plain text in
`logs/`. Turn the logger off and delete those logs when finished, and rotate
the token if it was exposed.

---

# Process API

Three applications now run together: two system APIs and the orchestration
layer over them.

## The resolution decision, and what it bought

ENTSO-E publishes quarter-hourly, aWATTar hourly, and an aWATTar hour is the
mean of four ENTSO-E quarters. Three ways to handle that:

| Option | Why not |
|---|---|
| Downsample ENTSO-E to hourly | Throws away the 15-minute detail, which is exactly where negative-price spikes live. The alerting layer would miss the events it exists for. |
| Upsample aWATTar to quarter-hourly | Fabricates detail: asserts each quarter equals the hourly mean, which is demonstrably false. |
| **Never merge across resolutions** | Chosen. |

ENTSO-E is primary at its native resolution; aWATTar answers only when
ENTSO-E gave nothing, and the response is marked `degraded`. Every point
already carries `source` and `resolutionMinutes`, so a mixed-resolution world
is expressed rather than hidden.

The first real response justified it:

```json
{ "startsAt": "2026-09-25T09:30:00Z",
  "endsAt":   "2026-09-25T13:30:00Z",
  "intervals": 16, "resolutionMinutes": 15,
  "meanPricePerKWh": 0.05044, "savingVsDayMean": 0.714 }
```

09:30Z is **11:30 Berlin** — a window starting at half past the hour, which
is only expressible at quarter-hourly resolution. Downsampling would have
returned a different, slightly worse answer and no way to tell.

`cheapestWindow` therefore works in INTERVALS, not hours: four hours is 16
intervals at PT15M and 4 at PT60M, with no special case. Mixed resolutions
return null rather than an average — refusing to guess is a feature, and
there is a test for it.

## The cross-check became monitoring

The manual check used to decide which ENTSO-E auction sequence to select is
now a runtime comparison. Both feeds publish the same EPEX auction, so every
aWATTar hour must equal the mean of the four ENTSO-E quarters inside it:

```
Cross-check OK: 24 hours agree with their quarter-hours
Series selected source=ENTSOE resolution=15 points=96 degraded=false
```

A divergence means one feed is stale or the wrong sequence is being picked.
It logs a WARN and does not fail the request, because the primary series is
still usable. aWATTar is fetched even when ENTSO-E succeeds purely so this
check can run — the cheapest monitoring available, since it needs no extra
dependency.

## Four small things that cost a build each

**Mule's XSD enforces child order inside `http:request`.** `headers` must come
before `query-params`, and `response-validator` last. The error reads
*"Invalid content ... One of {...response-validator} is expected"*, which means
the element is valid but arrived too late, not that it is unknown.

**RAML 1.0 parameters are required by default.** Giving one a `default:` does
NOT make it optional — APIkit rejects the request before any default applies.
Every optional parameter needs an explicit `required: false`.

**`example` belongs inside `body`, not beside it.** As a sibling of `body` it
is a response-node property, which RAML 1.0 forbids: *"Property 'example' not
supported in a RAML 1.0 response node"*.

**`as Date as DateTime` is not a conversion.** It fails at runtime with
"Cannot coerce Date to DateTime". To get midnight of the current day, format
the instant and parse it back:

```dataweave
var berlinNow = now() >> 'Europe/Berlin'
---
(berlinNow as String {format: 'yyyy-MM-dd'}
 ++ 'T00:00:00'
 ++ (berlinNow as String {format: 'XXX'})) as DateTime
```

Berlin rather than UTC on purpose: a delivery day is local, so a UTC-midnight
window straddles two of them. Taking the offset from the current instant keeps
it correct either side of the October changeover.

## MUnit does not prove deployability

Twice now a green `mvn test` has hidden a failure that only appeared on a
packaged deploy — the RAML sitting at the classpath root instead of `api/`,
and the misplaced `example` key. MUnit deploys the application, but evidently
resolves the spec more leniently.

**A passing test suite is not a deployment check.** Until there is a smoke
test that deploys the packaged jar and hits an endpoint, `mvn test` green
plus a manual deploy is the only honest verification.

---

# Persistence and the degraded-mode cache

The store serves two purposes: the historical record, and the cache the
process layer falls back to when both upstreams are unreachable. That
fallback is what makes `source: CACHE` in the canonical model reachable at
all.

Verified end to end by undeploying both system APIs and calling the process
API:

```json
{ "degraded": true, "resolutionMinutes": 15, "source": "CACHE",
  "points": [{ "startsAt": "2026-09-30T22:00:00Z", ... }] }
```

Same instant, same string format as the live path produces.

## Schema decisions

**price_point** holds what is true now, keyed on
`(bidding_zone, starts_at, source)`. Source is in the key because the two
upstreams publish the same auction at different resolutions and are never
merged, so ENTSO-E's 22:00 to 22:15 and aWATTar's 22:00 to 23:00 coexist
rather than fight over one row.

**price_revision** gets a row only when a stored price actually changes.
ENTSO-E revises published prices occasionally. Overwriting silently would
lose that; appending every observation would make every read a "latest per
interval" query. This way reads stay trivial and the question "do they
revise, and how often?" has a data-backed answer. The audit row is written
by a BEFORE UPDATE trigger, not by application code, so no future write path
can forget it.

**poll_run** separates `NO_DATA` from `FAILED` deliberately. "Tomorrow's
auction has not cleared yet" happens every morning and is normal;
"ENTSO-E is unreachable" is not. Collapsing them would make /health cry wolf
daily.

## A failed write never fails a read

The persist call is wrapped in try / on-error-continue. When the database
was rejecting timestamps, the API kept serving prices correctly and logged
"Persist failed, serving live data anyway". The caller asked for prices and
we had them; the storage problem was ours, not theirs.

## Five Mule and JDBC traps, each costing one build

**The JDBC driver must be a `sharedLibrary` in the pom.** Mule isolates each
plugin's classloader, so without it the app deploys cleanly and then fails at
runtime with "No suitable driver found". When it is right, the startup banner
lists it under "Application libraries".

**Element order inside `db:bulk-insert`.** `db:bulk-input-parameters` comes
BEFORE `db:sql`. It is not valid as an attribute either. The error
"One of {...parameter-types} is expected" is naming what may follow at that
point, which means your element belongs earlier, not that it is wrong. Same
rule bit `http:request`, where headers precede query-params.

**Postgres JDBC rejects ISO-8601 for timestamp parameters.** The driver
infers a parameter's type from the CAST target and parses the string itself:
`Bad value for type timestamp/date/time: 2026-09-24T22:00:00Z`. Values go out
as `yyyy-MM-dd HH:mm:ss` in UTC and the SQL attaches the zone with
`AT TIME ZONE 'UTC'`.

**A statement cannot open with a SQL line comment.** The DB connector decides
the query type from the first token:
`Query type must be one of [SELECT, STORE_PROCEDURE_CALL]`. Explanations go
in an XML comment outside the statement. Cost two builds, because the first
failure got attributed to a more interesting theory about the connector
parsing `:MI` and `:SS` in a to_char format string as named parameters. The
log had quoted the offending query back, opening with the comment, both
times.

**XML forbids a double hyphen inside a comment** - including in the comment
explaining the point above, which is how that one was discovered.

## Timestamps out of the database

The raw JDBC value arrives without zone information: a naive local-time
timestamp. Converting it in DataWeave with `>> 'UTC'` relabels rather than
converts, which silently shifts the instant by the local offset. The first
fix made the string look right while making the value two hours wrong, which
is worse than the original bug.

Fix: have Postgres return `extract(epoch from starts_at)`. An epoch is a
number - no colons for the parameter parser to misread, no zone to lose - and
DataWeave converts it back with the same `{unit: 'milliseconds'}` pattern the
aWATTar mapper already uses.

The principle: a canonical model that only holds when the weather is good is
not canonical. The cache path is exactly where that drift hides, because it
is the path nobody exercises.

## Metaspace

Repeated hot redeploys exhaust metaspace in a long-running CE runtime. After
a dozen redeploys the runtime threw `OutOfMemoryError: Metaspace`, wrote two
240 MB heap dumps, and started failing deploys in ways that looked like
configuration errors - one app vanished from the deployment list entirely and
sent the investigation sideways.

Default in `conf/wrapper.conf` is `-XX:MaxMetaspaceSize=256m`; raised to
512m. During heavy iteration, restart the runtime periodically rather than
assuming a deploy failure means broken code. Worth remembering for
deployment: three Mule apps in one CE runtime on a small VPS will hit exactly
this.

---

# The scheduled poll, and the bug that deleted a source

Verified 2026-10-01. The scheduler fires, both sources are polled, every
attempt is recorded, and `/health` answers from that record instead of
asserting it is fine:

```json
{ "status": "UP", "pollHistory": "AVAILABLE",
  "upstreams": [
    { "name": "ENTSOE",  "role": "PRIMARY",  "lastSuccessAt": "2026-10-01T20:03:00Z" },
    { "name": "AWATTAR", "role": "FALLBACK", "lastSuccessAt": "2026-10-01T20:03:00Z" } ] }
```

```
 source  | status  | points_written
---------+---------+----------------
 AWATTAR | SUCCESS |             24
 ENTSOE  | SUCCESS |             96
```

96 and 24 for the same delivery day: the same auction at both native
resolutions, stored side by side, never merged.

## A logger took a whole upstream offline

The worst bug in the project so far, and it was a log statement.

Two loggers concatenated `vars.toPersist` with a plain string variable.
DataWeave then has two media types to reconcile - `application/json` from
the upstream response and `application/java` from the String - and refuses
to infer an output type:

```
Unable to infer a output media type as more than one is being used:
application/json,application/java
```

Loggers elsewhere in the same file concatenate ONE variable with string
literals, so inference has a single media type and they need no directive.
That is why this had never appeared before.

The timing is the interesting part. The error handler sets `toPersist` to an
empty Java array on failure, so while every poll was failing the media types
were homogeneous and the logger worked. **It broke the moment the first poll
succeeded.** A latent fault that only fires on the success path is close to
the worst possible ordering: the thing that fixes one bug reveals another,
and it looks like the fix caused it.

## Why it was worse than a broken log line

The failing logger sat AFTER the `db:insert` and OUTSIDE its try. So:

1. ENTSO-E was fetched, 96 prices were written to `price_point`.
2. `poll_run` recorded `ENTSOE / SUCCESS / 96`. Committed.
3. The logger threw.
4. The error escaped `record-poll-run`, escaped `poll-entsoe`, and aborted
   the parent flow.
5. `poll-awattar` was never reached.

For roughly fifteen minutes the system polled once a minute, wrote correct
prices, and reported `ENTSOE / SUCCESS / 96` every single cycle. By every
signal it emitted about itself it was healthy. aWATTar had not been polled
once, and nothing anywhere said so.

**A monitoring table can only record the runs that happen. It cannot report
the runs that never started.** The query that found it was not "show me the
errors" - there were none - but "show me both sources", and noticing one of
them had quietly stopped appearing.

This is the same failure mode as the flat price curve and the shifted cache
timestamps, in different clothes: output that is well-formed, plausible, and
wrong. Three times now the fault has been invisible to structural checks and
caught only by asserting on values - or, here, on a row that should have
existed and did not.

## Two rules out of it

**Observability must never be able to change the thing it observes.** A log
statement that can abort a flow is not instrumentation, it is logic. Both
loggers now carry an explicit `output text/plain` directive.

**Independent sources need independent error boundaries.** The two
`flow-ref`s in `poll-day-ahead-auction` are each wrapped in their own
try / on-error-continue. There is no reason a problem reaching ENTSO-E
should mean aWATTar is never polled, and until this bug the code quietly
assumed otherwise. The inner handlers already classify real upstream
failures into `poll_run`, so anything reaching the outer handler is a fault
in the bookkeeping itself: WARN and continue.

## Deploy, verified rather than assumed

Two full diagnostic cycles were spent on a build whose jar had never been
copied to `apps/`. The log kept quoting the OLD expression back - the
`Element DSL` line shows the source of the *running* application, which is
the fastest way to tell "my fix is wrong" from "my fix is not deployed".
They look identical from the symptom and need completely different work.

Build and deploy now run as one `&&` chain ending in `echo "JAR COPIED"`, so
a silent skip is not possible.
