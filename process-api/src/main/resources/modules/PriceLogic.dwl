%dw 2.0

/**
 * Process-layer price logic.
 *
 * Operates on the canonical model the system APIs produce, so it never
 * sees ENTSO-E or aWATTar vocabulary.
 *
 * DESIGN DECISION - the two upstreams are at different resolutions:
 *   ENTSO-E  quarter-hourly (PT15M, 96 intervals/day)
 *   aWATTar  hourly         (24 intervals/day)
 *
 * and an aWATTar hour is the MEAN of four ENTSO-E quarters - verified
 * against live data for 2026-09-25 (181.94 vs 181.9425).
 *
 * The series are therefore NEVER interleaved. ENTSO-E is primary at its
 * native resolution; aWATTar is a fallback at its own. Mixing them would
 * either discard the 15-minute detail where negative-price spikes live,
 * or fabricate detail by asserting each quarter equals the hourly mean.
 * Both would misrepresent the data.
 *
 * No type annotations on collection-shaped parameters - see NOTES.md.
 */

fun mean(xs) =
    if (isEmpty(xs)) 0 else (xs reduce ($$ + $)) / sizeOf(xs)

fun round5(n) = round(n * 100000) / 100000

/**
 * Distinct resolutions present in a series. A well-formed series has
 * exactly one; more than one means sources were interleaved somewhere
 * upstream, and the window logic below refuses to guess.
 */
fun resolutionsOf(points) = (points map $.resolutionMinutes) distinctBy $

/**
 * Source selection. ENTSO-E is authoritative; aWATTar answers only when
 * ENTSO-E gave nothing. `degraded` tells the consumer which happened,
 * and every point already carries its own `source` and
 * `resolutionMinutes`, so a mixed-resolution response is honest rather
 * than hidden.
 */
fun selectSeries(primary, fallback) =
    if (!isEmpty(primary))
        { points: primary, degraded: false }
    else if (!isEmpty(fallback))
        { points: fallback, degraded: true }
    else
        { points: [], degraded: true }

/**
 * Cheapest contiguous block of `hours`, computed in INTERVALS rather
 * than hours so it works at any resolution: four hours is 16 intervals
 * at PT15M and 4 at PT60M.
 *
 * Returns null - never a partial answer - when the series is shorter
 * than the requested window, or when it contains mixed resolutions.
 *
 * `notBefore` may be null.
 */
fun cheapestWindow(points, hours, notBefore) = do {
    var eligible = (points
        filter ((p) -> notBefore == null or (p.startsAt as DateTime) >= notBefore)
        orderBy $.startsAt)
    var resolutions = resolutionsOf(eligible)
    ---
    if (sizeOf(resolutions) != 1)
        null
    else do {
        var step = resolutions[0]
        var perWindow = floor((hours * 60) / step)
        ---
        if (perWindow < 1 or sizeOf(eligible) < perWindow)
            null
        else do {
            /*
             * The day mean is taken over ALL points, not over `eligible`.
             *
             * `eligible` is the notBefore-filtered set, and it is the right
             * basis for CHOOSING the window - you cannot run an appliance in
             * the past. It is the wrong basis for the comparison, because
             * "savingVsDayMean" claims to measure against the day. Taken over
             * the filtered set it measures against whatever is left, so late
             * in the evening, when only a few intervals remain, the best
             * window sits near the mean of those few and the saving collapses
             * towards zero regardless of how cheap it actually is.
             *
             * Unreachable until something passed notBefore, which nothing did
             * until the experience layer started asking "when should I run
             * this" rather than "which hours were cheapest".
             */
            var dayMean = mean(points map $.pricePerKWh)
            var windows = (0 to (sizeOf(eligible) - perWindow)) map ((i) -> do {
                var slice = eligible[i to (i + perWindow - 1)]
                ---
                {
                    startsAt: slice[0].startsAt,
                    endsAt: slice[-1].endsAt,
                    hours: hours,
                    intervals: perWindow,
                    resolutionMinutes: step,
                    source: slice[0].source,
                    meanPricePerKWh: round5(mean(slice map $.pricePerKWh))
                }
            })
            var best = (windows orderBy $.meanPricePerKWh)[0]
            ---
            best ++ {
                savingVsDayMean:
                    if (dayMean == 0) 0
                    else round(((dayMean - best.meanPricePerKWh) / dayMean) * 1000) / 1000
            }
        }
    }
}

/**
 * The interval covering a given instant, or null if the series does not
 * reach it.
 */
fun currentPoint(points, at) =
    (points filter ((p) ->
        (p.startsAt as DateTime) <= at and (p.endsAt as DateTime) > at
    ))[0]

/**
 * Cross-source agreement check, and the most interesting function here.
 *
 * Both upstreams publish the same EPEX day-ahead auction, so an hourly
 * price must equal the mean of the four quarter-hours inside it. This
 * was first done by hand to confirm which ENTSO-E auction sequence to
 * select; as a runtime check it becomes monitoring.
 *
 * Returns only the DISAGREEMENTS. An empty result is the healthy case.
 * A non-empty one means one feed is stale, or the wrong auction sequence
 * is being selected - both worth a WARN, neither worth failing a request
 * over, since the primary series is still perfectly usable.
 */
fun crossCheck(quarterly, hourly, toleranceKWh) =
    (hourly map ((h) -> do {
        var within = quarterly filter ((q) ->
            (q.startsAt as DateTime) >= (h.startsAt as DateTime)
            and (q.startsAt as DateTime) < (h.endsAt as DateTime))
        ---
        {
            startsAt: h.startsAt,
            hourlyPerKWh: h.pricePerKWh,
            quarterMean: if (isEmpty(within)) null else round5(mean(within map $.pricePerKWh)),
            intervalsCovered: sizeOf(within)
        }
    }))
    filter ((r) ->
        r.quarterMean != null and abs(r.hourlyPerKWh - r.quarterMean) > toleranceKWh)

/**
 * Summary for the response envelope and for logging.
 */
fun seriesSummary(points) = {
    count: sizeOf(points),
    resolutionMinutes: (resolutionsOf(points))[0],
    sources: (points map $.source) distinctBy $,
    startsAt: if (isEmpty(points)) null else (points orderBy $.startsAt)[0].startsAt,
    endsAt: if (isEmpty(points)) null else (points orderBy $.startsAt)[-1].endsAt
}

/**
 * Clip a string to at most n characters.
 *
 * NOT `s[0 to n]`. A range selector on a String SHORTER than the range
 * returns null in DataWeave - it does not return the whole string. So
 *
 *     (error.description default 'Unknown failure')[0 to 480]
 *
 * yields null for every message under 481 characters, which is all of
 * them. That is why eleven ENTSO-E failures were recorded over five days
 * with FAILED in the status column and NULL in detail, and why the first
 * attempt to fix it changed the wrong half of the expression and made no
 * difference at all.
 *
 * The giveaway was in the data the whole time: NO_DATA rows, whose detail
 * is a plain literal with no slicing, carried their text. Only the sliced
 * ones were null.
 */
fun clip(s, n) = if (sizeOf(s) > n) s[0 to (n - 1)] else s

/**
 * Build a poll_run detail that is never null and never empty.
 *
 * The error TYPE is always populated and is the single most diagnostic
 * field, so it leads. Description and detailedDescription are appended
 * only when they actually carry text - `default` substitutes for null but
 * not for an empty string, so each is checked with isEmpty rather than
 * trusted.
 *
 * A failure record with no reason is not a failure record.
 */
fun failureDetail(err) = do {
    var kind = (err.errorType.namespace default '?')
               ++ ':' ++ (err.errorType.identifier default '?')
    var desc = err.description default ''
    var detailed = err.detailedDescription default ''
    var body =
        if (!isEmpty(desc)) desc
        else if (!isEmpty(detailed)) detailed
        else 'no description supplied by the connector'
    ---
    clip(kind ++ ' - ' ++ body, 480)
}

/**
 * Summarise the intervals below zero in a series, or null if there are
 * none.
 *
 * Reports the span from the FIRST to the LAST negative interval rather
 * than a contiguous run. Negative periods are routinely broken by a
 * single interval that creeps back above zero, and "between 02:00 and
 * 05:00, 9 intervals" is both true and more useful to a person than
 * three fragments they then have to reassemble.
 *
 * `intervals` is reported alongside the span precisely so the two
 * together cannot mislead: a span of three hours with 9 quarter-hours
 * below zero is visibly not solid.
 */
fun negativeSummary(points) = do {
    var below = (points filter ((p) -> p.pricePerKWh < 0)) orderBy $.startsAt
    ---
    if (isEmpty(below)) null
    else {
        intervals:         sizeOf(below),
        startsAt:          below[0].startsAt,
        endsAt:            below[-1].endsAt,
        lowestPerKWh:      ((below map $.pricePerKWh) orderBy $)[0],
        resolutionMinutes: below[0].resolutionMinutes,
        source:            below[0].source
    }
}
