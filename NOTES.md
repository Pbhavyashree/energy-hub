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
