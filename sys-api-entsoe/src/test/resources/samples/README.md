# Test fixtures

## Provenance

Both files are **real captured responses** from the ENTSO-E Transparency
Platform, taken on 2026-09-24 for DE-LU (`10Y1001A1001A82H`), delivery day
2026-09-25.

They replaced synthetic fixtures built from the archived API user guide. Those
were wrong about the namespace, the curve type, the resolution and the number
of TimeSeries — and every test written against them passed, because the
fixture and the mapper shared the same wrong assumptions. See `NOTES.md`.

## Why there are no comments inside the XML

These are verbatim API responses. Keeping them byte-identical to what the
upstream sends is the point — commentary belongs here instead.

## entsoe-a44-REAL.xml

A full delivery day, and considerably more interesting than the invented one:

| Property | Value |
|---|---|
| namespace | `urn:iec62325.351:tc57wg16:451-3:publicationdocument:7:3` |
| resolution | `PT15M` — 96 quarter-hourly intervals |
| curveType | `A03` — sparse; repeated prices are omitted |
| TimeSeries | **two**, covering identical intervals |
| period | 2026-09-24T22:00Z → 2026-09-25T22:00Z (Berlin midnight to midnight, UTC+2) |

### The two TimeSeries

Distinguished only by
`classificationSequence_AttributeInstanceComponent.position`:

- **sequence 1** — the primary day-ahead auction (EPEX SPOT). This is *the*
  day-ahead price and the one the mapper selects.
- **sequence 2** — the separate EXAA auction held at 10:15 CET.

**Document order is not sequence order.** In this capture the first
`<TimeSeries>` carries sequence 2, so `TimeSeries[0]` selects EXAA. The filter
must be on the classification field.

### Known values, used by the tests

| | |
|---|---|
| sequence 1, position 1 | 196.99 |
| sequence 1, positions 1–4 | 196.99, 184.40, 175.79, 170.59 (mean 181.9425) |
| sequence 2, position 1 | 192.55 — appears first in the document |
| aWATTar, hour 00:00–01:00 | 181.94 |

That last row is the cross-source check: aWATTar publishes the same EPEX
auction hourly, and its price for the hour equals the mean of sequence 1's
four quarter-hours. It confirms both the auction choice and the position
arithmetic against a source sharing no code with this project, and it is
asserted in the test suite.

### Sparseness

curveType A03 omits positions whose price repeats the previous one — this
capture skips positions 7 and 10 in the sequence-2 series. The mapper expands
positions across the full interval count and holds values forward. Mapping
declared points one-to-one would produce a short, misaligned day.

## entsoe-a44-acknowledgement-REAL.xml

What ENTSO-E returns when nothing is published for the requested zone and
period — captured by asking for 2026-12-01, far enough ahead that no auction
has cleared.

HTTP **200** with an `Acknowledgement_MarketDocument` and reason code 999, not
a 404. An empty result therefore looks like success at the transport layer,
which is why the flow checks for it explicitly before mapping.

The namespace differs from the publication document:

```
publication     urn:iec62325.351:tc57wg16:451-3:publicationdocument:7:3
acknowledgement urn:iec62325.351:tc57wg16:451-1:acknowledgementdocument:7:0
```

## Still to capture

**25 October 2026** — the DST changeover, a 25-hour local day. Prices publish
one day ahead, so this must be captured on the 24th. It is the best edge case
this domain offers and it comes once a year.
