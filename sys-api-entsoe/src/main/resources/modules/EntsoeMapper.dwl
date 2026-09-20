%dw 2.0

/**
 * ENTSO-E Publication_MarketDocument (A44, day-ahead prices)
 * -> canonical PricePoint[].
 *
 * Namespaces confirmed against the Transparency Platform RESTful API
 * user guide:
 *   publication     urn:iec62325.351:tc57wg16:451-3:publicationdocument:7:0
 *   acknowledgement urn:iec62325.351:tc57wg16:451-1:acknowledgementdocument:7:0
 *
 * Developed against a synthetic fixture built from the documented
 * structure. Revalidate against a real response before trusting it:
 * element ordering, optional elements and the exact timestamp format
 * are the things most likely to differ.
 *
 * No return-type annotations on document-shaped parameters - indexing
 * into a bare Object yields Any, which breaks a declared return type.
 */

ns pub urn:iec62325.351:tc57wg16:451-3:publicationdocument:7:0
ns ack urn:iec62325.351:tc57wg16:451-1:acknowledgementdocument:7:0

/**
 * The guide documents timeInterval as yyyy-MM-ddTHH:mmZ - no seconds -
 * which DataWeave will not coerce to DateTime directly. Tolerates both
 * forms, since a real response may well include them.
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

/**
 * ENTSO-E does not timestamp prices. Each Point carries a position
 * (1, 2, 3 ...) and the real instant is
 *     periodStart + (position - 1) * resolution
 *
 * curveType A01 ("sequential fixed size block") means every position is
 * present, and the guide states A44 uses A01. A03 ("variable sized
 * block") omits repeated values, so a declared position holds until the
 * next one appears.
 *
 * Expansion is defensive: with a complete A01 series it is the identity,
 * so it costs nothing and covers the case where that assumption is
 * wrong. `filled` marks a slot that had no declared Point, so the flow
 * can log when it is actually doing work.
 */
fun expandPositions(declared: Array, intervalCount: Number): Array<Object> =
    (1 to intervalCount) map ((slot) -> do {
        var applicable = declared filter ($.position <= slot)
        ---
        {
            slot: slot,
            price: (applicable[-1] default declared[0]).price,
            filled: sizeOf(declared filter ((d) -> d.position == slot)) == 0
        }
    })

fun mapPeriod(period: Object): Array<Object> = do {
    var start = toInstant(period.pub#timeInterval.pub#start as String)
    var end = toInstant(period.pub#timeInterval.pub#end as String)
    var stepMins = resolutionMinutes(period.pub#resolution as String)
    // Derived from the bounds rather than assumed to be 24, so the
    // 25-hour DST day in late October needs no special case.
    var intervalCount = floor(((end as Number) - (start as Number)) / (stepMins * 60))
    var declared = (period.*pub#Point default []) map {
        position: $.pub#position as Number,
        // The dot is part of the element name, so the selector must be
        // quoted. Unquoted it parses as a nested selector and silently
        // returns null.
        price: $.pub#"price.amount" as Number
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
        ((doc.pub#Publication_MarketDocument.*pub#TimeSeries) default []) map ((ts) ->
            flatten(((ts.*pub#Period) default []) map ((period) -> mapPeriod(period)))
        )
    ) orderBy $.startsAt

/**
 * ENTSO-E returns an Acknowledgement document for "no matching data
 * found" (reason code 999) rather than a 404, so an empty result looks
 * like a success at the HTTP layer.
 */
fun isAcknowledgement(doc) =
    doc.ack#Acknowledgement_MarketDocument != null

fun acknowledgementReason(doc) = {
    code: doc.ack#Acknowledgement_MarketDocument.ack#Reason.ack#code default "UNKNOWN",
    text: doc.ack#Acknowledgement_MarketDocument.ack#Reason.ack#text default ""
}

/**
 * Any curve type other than A01 means the expansion above is
 * load-bearing rather than decorative. Worth a WARN, not a failure.
 */
fun curveTypes(doc) =
    (((doc.pub#Publication_MarketDocument.*pub#TimeSeries) default [])
        map ($.pub#curveType default "ABSENT")) distinctBy $
