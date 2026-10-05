%dw 2.0

/**
 * View logic for the household experience layer.
 *
 * Everything here is presentation: unit conversion, local time, and the
 * one judgement this layer is allowed to make - whether a price counts
 * as cheap. No market concepts, no upstream names, no persistence.
 *
 * The cheapest-window calculation is NOT here. The process layer owns
 * it, and this module only reshapes the answer. Recomputing it would
 * give two implementations of the same rule that can disagree.
 */

var BERLIN = 'Europe/Berlin'

/**
 * The canonical model is UTC throughout, which is right for storage and
 * useless on a screen. A household reads wall-clock.
 */
fun toLocal(d) = (d as DateTime) >> BERLIN

fun clock(d) = toLocal(d) as String {format: 'HH:mm'}

fun dayOf(d) = toLocal(d) as String {format: 'yyyy-MM-dd'}

/**
 * EUR/kWh to cents/kWh at two decimals. Cents because that is the unit
 * on a German electricity bill; EUR/MWh is a wholesale unit and means
 * nothing to the person reading it.
 *
 * round() returns an integer, so scale first and divide after.
 */
fun cents(eurPerKWh) =
    if (eurPerKWh == null) null
    else round((eurPerKWh as Number) * 10000) / 100

/**
 * The parameter is NOT called `ns`. That is the namespace-declaration
 * keyword in DataWeave - the same `ns` used in the ENTSO-E mapper - and
 * using it as a parameter name fails to parse with
 * "Invalid input 'n', expected missing `)` for the function parameters",
 * pointing at a generic `fun a() = 1` rather than naming the collision.
 */
fun total(nums) = nums reduce ((item, acc = 0) -> acc + item)

fun meanOf(nums) =
    if (isEmpty(nums)) null else total(nums) / sizeOf(nums)

/**
 * Today's prices, ascending. Computed once per request and passed in,
 * rather than re-sorted for every interval.
 */
fun priceLadder(points) = (points map $.pricePerKWh) orderBy $

/**
 * Banding by position in today's own distribution, in terciles.
 *
 * Two alternatives were rejected:
 *
 *   A fixed threshold ("cheap is under 5 ct") is wrong as soon as the
 *   market moves, and would label an entire quiet week CHEAP.
 *
 *   A percentage of the day's mean breaks on negative prices, which
 *   German day-ahead produces regularly on windy Sundays. Once the mean
 *   is near zero the ratio explodes; once it is negative the comparison
 *   inverts and the cheapest hours get labelled EXPENSIVE.
 *
 * Rank is ordinal, so it survives both. It also means CHEAP always
 * describes roughly a third of the day - which is what makes the label
 * useful for deciding when to act.
 */
fun bandOf(price, ladder) = do {
    var n = sizeOf(ladder)
    var below = sizeOf(ladder filter ($ < price))
    ---
    if (n == 0) 'NORMAL'
    else if (below * 3 < n) 'CHEAP'
    else if (below * 3 >= n * 2) 'EXPENSIVE'
    else 'NORMAL'
}

fun verdictFor(band) =
    if (band == 'CHEAP') 'Good time to run anything that uses a lot of power.'
    else if (band == 'EXPENSIVE') 'Worth waiting if whatever you need can wait.'
    else 'Nothing unusual either way.'

/**
 * The interval covering an instant. Half-open: start inclusive, end
 * exclusive, so the boundary between two intervals belongs to exactly
 * one of them and midnight does not match twice.
 */
fun covering(points, instant) =
    (points filter ((p) ->
        (p.startsAt as DateTime) <= instant
        and instant < (p.endsAt as DateTime)))[0]

fun slotOf(p, ladder) = {
    from:  clock(p.startsAt),
    to:    clock(p.endsAt),
    cents: cents(p.pricePerKWh),
    band:  bandOf(p.pricePerKWh, ladder)
}

fun nowViewOf(point, ladder, degraded) =
    if (point == null) null
    else do {
        var band = bandOf(point.pricePerKWh, ladder)
        ---
        {
            at:        clock(point.startsAt),
            cents:     cents(point.pricePerKWh),
            band:      band,
            verdict:   verdictFor(band),
            estimated: degraded default false
        }
    }

/**
 * Reshape the process layer's CheapestWindow. A null window means the
 * series was too short or mixed-resolution; the process layer refuses to
 * guess there, and this layer passes that refusal through rather than
 * inventing an answer.
 */
fun bestTimeOf(w, degraded, day = 'today') =
    if (w == null) null
    else {
        /*
         * `day` matters because the clock times alone are ambiguous.
         * "03:00" at eleven at night could be four hours away or
         * twenty-eight, and the difference is the whole answer.
         */
        day:           day,
        from:          clock(w.startsAt),
        to:            clock(w.endsAt),
        hours:         w.hours,
        averageCents:  cents(w.meanPricePerKWh),
        savingPercent: round((w.savingVsDayMean default 0) * 100),
        estimated:     degraded default false
    }

fun todayViewOf(series, window, instant, windowDay = 'today') = do {
    var points = series.points default []
    var ladder = priceLadder(points)
    var degraded = series.degraded default false
    ---
    {
        day:          if (isEmpty(points)) null else dayOf(points[0].startsAt),
        averageCents: cents(meanOf(points map $.pricePerKWh)),
        estimated:    degraded,
        now:          nowViewOf(covering(points, instant), ladder, degraded),
        bestTime:     bestTimeOf(window, degraded, windowDay),
        slots:        points map slotOf($, ladder)
    }
}
