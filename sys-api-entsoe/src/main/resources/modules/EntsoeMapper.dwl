%dw 2.0

/**
 * ENTSO-E Publication_MarketDocument (A44, day-ahead prices)
 * -> canonical PricePoint[].
 *
 * Rewritten against a REAL captured response (DE-LU, 2026-09-25).
 * The previous version was built from a synthetic fixture and got four
 * of five structural assumptions wrong:
 *
 *   assumed                          actual
 *   ---------------------------------------------------------------
 *   namespace ...publicationdocument:7:0   ...:7:3
 *   curveType A01 (all positions present)  A03 (sparse)
 *   PT60M, 24 points                       PT15M, 96 positions
 *   one TimeSeries                         two
 *   timestamps without seconds             confirmed correct
 *
 * Namespaces, both verified against live responses:
 *   publication     urn:iec62325.351:tc57wg16:451-3:publicationdocument:7:3
 *   acknowledgement urn:iec62325.351:tc57wg16:451-1:acknowledgementdocument:7:0
 *
 * No type annotations on document-shaped parameters - see NOTES.md.
 */

ns pub urn:iec62325.351:tc57wg16:451-3:publicationdocument:7:3
ns ack urn:iec62325.351:tc57wg16:451-1:acknowledgementdocument:7:0

// ---------------------------------------------------------------
// Timestamps
// ---------------------------------------------------------------

/**
 * ENTSO-E writes timeInterval as yyyy-MM-ddTHH:mmZ - no seconds -
 * which DataWeave will not coerce to DateTime directly. Verified
 * against live data. Tolerates both forms in case that ever changes.
 */
fun normaliseInstant(raw: String): String = do {
    var trimmed = trim(raw)
    var body = if (endsWith(trimmed, "Z")) trimmed[0 to -2] else trimmed
    ---
    // 16 chars is "yyyy-MM-ddTHH:mm"; 19 includes seconds.
    if (sizeOf(body) == 16) (body ++ ":00Z") else (body ++ "Z")
}

fun toInstant(raw: String): DateTime =
    (normaliseInstant(raw) as DateTime {format: "yyyy-MM-dd'T'HH:mm:ssX"}) >> "UTC"

fun resolutionMinutes(resolution: String): Number =
    resolution match {
        case "PT15M" -> 15
        case "PT30M" -> 30
        case "PT60M" -> 60
        case "PT1H"  -> 60
        case "P1D"   -> 1440
        else -> 60
    }

fun toKWh(perMWh: Number): Number = round((perMWh / 1000) * 100000) / 100000

// ---------------------------------------------------------------
// Picking the right auction
// ---------------------------------------------------------------

/**
 * A44 for DE-LU returns TWO TimeSeries covering the identical interval
 * at the same resolution, distinguished only by
 * classificationSequence_AttributeInstanceComponent.position:
 *
 *   sequence 1 - the primary day-ahead auction (EPEX SPOT)
 *   sequence 2 - the separate EXAA auction held at 10:15 CET
 *
 * Flattening both yields two prices for every interval. Sequence 1 is
 * the day-ahead price.
 *
 * Verified, not assumed: for 2026-09-25 the mean of sequence 1's first
 * four quarter-hours (196.99, 184.40, 175.79, 170.59) is 181.9425, and
 * aWATTar - an independent publisher of the same EPEX auction - reports
 * 181.94 for that hour. Sequence 2 opens at 192.55 and does not match.
 *
 * Document order is NOT sequence order: in the captured response the
 * FIRST TimeSeries carries sequence 2. Taking [0] would pick EXAA.
 */
fun sequenceOf(ts) =
    ts.pub#'classificationSequence_AttributeInstanceComponent.position'

/**
 * Filters to sequence 1 when the document declares sequences at all.
 * Zones other than DE-LU may publish a single series with no
 * classification element; those are returned untouched rather than
 * filtered away to nothing.
 */
fun primarySeries(doc) = do {
    var all = (doc.pub#Publication_MarketDocument.*pub#TimeSeries) default []
    var classified = all filter ((ts) -> sequenceOf(ts) != null)
    ---
    if (isEmpty(classified))
        all
    else
        classified filter ((ts) -> (sequenceOf(ts) as Number) == 1)
}

// ---------------------------------------------------------------
// Position -> timestamp
// ---------------------------------------------------------------

/**
 * ENTSO-E does not timestamp prices. Each Point carries a position
 * (1, 2, 3 ...) and the instant is
 *     periodStart + (position - 1) * resolution
 *
 * curveType is A03 ("variable sized block"), CONFIRMED against live
 * data: the captured response omits positions 7 and 10 in one series,
 * meaning those intervals repeat the previous declared price. This
 * expansion is therefore essential, not defensive - mapping points
 * one-to-one would silently produce a short, misaligned day.
 *
 * `filled` marks an interval that had no declared Point, so the flow
 * can report how much holding-forward actually happened.
 */
fun expandPositions(declared, intervalCount) =
    (1 to intervalCount) map ((slot) -> do {
        var applicable = declared filter ((d) -> d.position <= slot)
        ---
        {
            slot: slot,
            price: (applicable[-1] default declared[0]).price,
            filled: sizeOf(declared filter ((d) -> d.position == slot)) == 0
        }
    })

fun mapPeriod(period) = do {
    var start = toInstant(period.pub#timeInterval.pub#start as String)
    var end = toInstant(period.pub#timeInterval.pub#end as String)
    var stepMins = resolutionMinutes(period.pub#resolution as String)
    // Derived from the bounds, not assumed. A PT15M day is 96 intervals,
    // and the 25-hour DST day in late October needs no special case.
    var intervalCount = floor(((end as Number) - (start as Number)) / (stepMins * 60))
    var declared = (period.*pub#Point default []) map {
        position: $.pub#position as Number,
        // The dot is part of the element name, so the selector must be
        // quoted. Unquoted it parses as a nested selector and returns null.
        price: $.pub#'price.amount' as Number
    }
    ---
    expandPositions(declared, intervalCount) map ((p) -> do {
        var pointStart = start + ((p.slot - 1) * stepMins * 60)
        ---
        {
            startsAt: pointStart >> "UTC",
            endsAt: (pointStart + (stepMins * 60)) >> "UTC",
            resolutionMinutes: stepMins,
            pricePerMWh: p.price,
            pricePerKWh: toKWh(p.price),
            currency: "EUR",
            source: "ENTSOE"
        }
    })
}

fun toCanonical(doc) =
    flatten(
        primarySeries(doc) map ((ts) ->
            flatten(((ts.*pub#Period) default []) map ((period) -> mapPeriod(period)))
        )
    ) orderBy $.startsAt

// ---------------------------------------------------------------
// Diagnostics for the flow to act on
// ---------------------------------------------------------------

/**
 * ENTSO-E returns an Acknowledgement document for "no matching data
 * found" (reason code 999) with HTTP 200, not a 404, so an empty result
 * looks like success at the transport layer.
 */
fun isAcknowledgement(doc) =
    doc.ack#Acknowledgement_MarketDocument != null

fun acknowledgementReason(doc) = {
    code: doc.ack#Acknowledgement_MarketDocument.ack#Reason.ack#code default "UNKNOWN",
    text: doc.ack#Acknowledgement_MarketDocument.ack#Reason.ack#text default ""
}

/**
 * Reported so a change upstream becomes visible rather than silently
 * working. A01 would mean positions are dense and the expansion above
 * is a no-op; A03 is what live data actually uses.
 */
fun curveTypes(doc) =
    (primarySeries(doc) map ($.pub#curveType default "ABSENT")) distinctBy $

/**
 * How many series the document carried, and which sequences. Useful in
 * a log line: a day where this stops being [2 series, sequences 1 and 2]
 * is worth noticing.
 */
fun seriesSummary(doc) = do {
    var all = (doc.pub#Publication_MarketDocument.*pub#TimeSeries) default []
    ---
    {
        total: sizeOf(all),
        sequences: (all map (sequenceOf($) default "ABSENT")) distinctBy $,
        selected: sizeOf(primarySeries(doc))
    }
}
