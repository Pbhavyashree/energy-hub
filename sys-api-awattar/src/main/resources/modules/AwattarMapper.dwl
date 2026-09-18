%dw 2.0

/**
 * aWATTar market data -> canonical PricePoint[].
 *
 * Written against live responses captured 2026-09-17. Shape:
 *
 *   {
 *     "object": "list",
 *     "data": [
 *       {
 *         "start_timestamp": 1789678800000,
 *         "end_timestamp":   1789682400000,
 *         "marketprice":     179.37,
 *         "unit":            "Eur/MWh"
 *       }
 *     ]
 *   }
 *
 * Deliberately simple compared with the ENTSO-E mapper: every interval is
 * explicit, nothing is sparse, nothing needs reconstructing. The value of
 * this module is that it proves the canonical model is actually an
 * abstraction and not just ENTSO-E's shape wearing different field names.
 */

/**
 * Epoch MILLISECONDS, not seconds. A 10-digit value here would put every
 * price in 1970, so the length guard fails loudly rather than silently
 * producing plausible-looking nonsense.
 */
fun epochMillisToUtc(millis: Number): DateTime =
  if (millis < 100000000000)
    fail("Expected epoch milliseconds (13 digits), got: " ++ millis as String)
  else
    (millis as DateTime {unit: "milliseconds"}) >> "UTC"

fun perKWh(perMWh: Number): Number = round((perMWh / 1000) * 100000) / 100000

/**
 * Derived rather than assumed. aWATTar has published hourly data throughout,
 * but the German market is moving toward 15-minute settlement and this will
 * start returning 15 without warning. Computing it means that day is a
 * non-event instead of an outage.
 */
fun intervalMinutes(entry: Object): Number =
  (entry.end_timestamp - entry.start_timestamp) / 60000

/**
 * The upstream states its unit on every entry. Trusting it blindly is how a
 * silent unit change becomes a 1000x pricing error, so anything unexpected
 * is surfaced for the caller to turn into a 502.
 */
fun unexpectedUnits(doc: Object): Array<String> =
  ((doc.data default []) map ($.unit default "MISSING")
    filter ($ != "Eur/MWh")) distinctBy $

fun toCanonical(doc: Object): Array<Object> =
  ((doc.data default []) map ((entry) -> {
    startsAt: epochMillisToUtc(entry.start_timestamp),
    endsAt: epochMillisToUtc(entry.end_timestamp),
    resolutionMinutes: intervalMinutes(entry),
    pricePerMWh: entry.marketprice,
    pricePerKWh: perKWh(entry.marketprice),
    currency: "EUR",
    source: "AWATTAR"
  })) orderBy $.startsAt

/**
 * Convenience for the flow: returns the canonical array, or raises if the
 * unit contract was broken. Kept separate from toCanonical so MUnit can
 * test the mapping and the guard independently.
 */
fun toCanonicalChecked(doc: Object): Array<Object> = do {
  var bad = unexpectedUnits(doc)
  ---
  if (isEmpty(bad))
    toCanonical(doc)
  else
    fail("Unexpected price unit(s) from aWATTar: " ++ (bad joinBy ", "))
}
