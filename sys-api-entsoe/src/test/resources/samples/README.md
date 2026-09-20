# Test fixtures

## Provenance

Both files are **SYNTHETIC** — hand-built from the structure documented in the
ENTSO-E Transparency Platform RESTful API user guide, so the mapper could be
developed before API credentials arrived. Neither is a captured response.

Replace them with real captures as soon as the security token works, then
re-run the suite. The things most likely to differ:

- element ordering
- optional elements omitted here
- whether `timeInterval` timestamps carry seconds (the guide shows
  `yyyy-MM-ddTHH:mmZ`, without)

## Why there are no comments inside the XML

There were, and they broke the build.

The flow serialises the response body once with `write(payload,
'application/xml')` so the document can be inspected several times without
re-reading a non-repeatable stream. DataWeave reads a comment sitting before
the root element as prolog content and then refuses to write it back:

```
Trying to output non-whitespace characters outside main element tree
(in prolog or epilog), while writing Xml
```

Real ENTSO-E responses carry no such comment, so the failure was caused
purely by explanatory text added to the fixture. Fixtures should look like
what the upstream actually sends; commentary belongs here instead.

## entsoe-a44-SYNTHETIC.xml

A full delivery day for DE-LU, 2026-09-18: 24 hourly positions from 22:00Z on
the 17th to 22:00Z on the 18th, because Berlin is UTC+2 in September.

Deliberate properties, each exercising a branch of the mapper:

| Property | Why |
|---|---|
| `timeInterval` timestamps have no seconds | The documented format; DataWeave will not coerce it to `DateTime` without help |
| `curveType` is `A01` | All 24 positions present, which is what the guide says A44 uses |
| Position 14 is `0` | Zero must not be treated as absent |
| Position 15 is `-12.40` | Negative prices are the reason the alerting layer exists |
| Prices vary across the day | A flat series would have hidden the stream-consumption bug, where every interval took the last point's price |

## entsoe-a44-acknowledgement-SYNTHETIC.xml

What ENTSO-E returns when nothing is published for the requested zone and
period: an `Acknowledgement_MarketDocument` with HTTP **200** and reason code
999 — not a 404. An empty result therefore looks like success at the transport
layer, which is why the flow checks for it explicitly before mapping.

Note the namespace differs from the publication document:

```
publication     urn:iec62325.351:tc57wg16:451-3:publicationdocument:7:0
acknowledgement urn:iec62325.351:tc57wg16:451-1:acknowledgementdocument:7:0
```

To capture a real one, request a date far enough ahead that no auction has
cleared.
