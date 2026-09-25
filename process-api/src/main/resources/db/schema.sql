-- energy-hub schema
--
-- Apply with:
--   psql -U postgres -h localhost -d energyhub -f schema.sql
--
-- Three tables, each with a distinct job:
--   price_point     what is true now, and the degraded-mode cache
--   price_revision  an audit row whenever a published price CHANGES
--   poll_run        the outcome of each scheduled poll, so /health has
--                   something real to report

-- ---------------------------------------------------------------
-- price_point
-- ---------------------------------------------------------------
--
-- Serves double duty: the historical record, and the cache the process
-- layer falls back to when both upstreams are unreachable (which is
-- what makes `source: CACHE` in the canonical model reachable at all).
--
-- The primary key includes `source` on purpose. The two upstreams
-- publish the same auction at different resolutions, and the process
-- layer never merges them - so ENTSOE's 22:00-22:15 and AWATTAR's
-- 22:00-23:00 coexist as separate rows rather than fighting over one.

CREATE TABLE IF NOT EXISTS price_point (
    bidding_zone        text          NOT NULL,
    starts_at           timestamptz   NOT NULL,
    ends_at             timestamptz   NOT NULL,
    resolution_minutes  smallint      NOT NULL,
    source              text          NOT NULL,
    price_per_mwh       numeric(12,4) NOT NULL,
    price_per_kwh       numeric(12,7) NOT NULL,
    currency            text          NOT NULL DEFAULT 'EUR',
    first_seen_at       timestamptz   NOT NULL DEFAULT now(),
    updated_at          timestamptz   NOT NULL DEFAULT now(),

    CONSTRAINT price_point_pk PRIMARY KEY (bidding_zone, starts_at, source),
    CONSTRAINT price_point_interval_ck CHECK (ends_at > starts_at),
    CONSTRAINT price_point_resolution_ck CHECK (resolution_minutes IN (15, 30, 60)),
    CONSTRAINT price_point_source_ck CHECK (source IN ('ENTSOE', 'AWATTAR'))
);

-- Range queries are always "this zone, this source, this window".
CREATE INDEX IF NOT EXISTS price_point_lookup_idx
    ON price_point (bidding_zone, source, starts_at);

COMMENT ON TABLE price_point IS
    'Current published price per settlement interval. Also the degraded-mode cache.';
COMMENT ON COLUMN price_point.first_seen_at IS
    'When this interval was first stored - unchanged by later revisions.';
COMMENT ON COLUMN price_point.updated_at IS
    'When this row last changed. Equal to first_seen_at unless revised.';

-- ---------------------------------------------------------------
-- price_revision
-- ---------------------------------------------------------------
--
-- ENTSO-E occasionally revises already-published prices. Overwriting
-- silently would lose that fact entirely; appending every observation
-- would make every read a "latest per interval" query.
--
-- So: price_point holds what is true now, and this table gets a row
-- ONLY when a stored price actually changes. Normally empty, and it
-- turns "do they revise, and how often?" into a question with a
-- data-backed answer.

CREATE TABLE IF NOT EXISTS price_revision (
    id                 bigserial     PRIMARY KEY,
    bidding_zone       text          NOT NULL,
    starts_at          timestamptz   NOT NULL,
    source             text          NOT NULL,
    old_price_per_mwh  numeric(12,4) NOT NULL,
    new_price_per_mwh  numeric(12,4) NOT NULL,
    observed_at        timestamptz   NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS price_revision_lookup_idx
    ON price_revision (bidding_zone, starts_at, observed_at DESC);

COMMENT ON TABLE price_revision IS
    'One row per observed change to an already-published price.';

-- The audit row is written by the database, not the application, so it
-- cannot be forgotten by a code path that writes prices some other way.
CREATE OR REPLACE FUNCTION record_price_revision() RETURNS trigger AS $$
BEGIN
    IF NEW.price_per_mwh IS DISTINCT FROM OLD.price_per_mwh THEN
        INSERT INTO price_revision (
            bidding_zone, starts_at, source,
            old_price_per_mwh, new_price_per_mwh)
        VALUES (
            OLD.bidding_zone, OLD.starts_at, OLD.source,
            OLD.price_per_mwh, NEW.price_per_mwh);

        NEW.updated_at := now();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS price_point_revision_trg ON price_point;
CREATE TRIGGER price_point_revision_trg
    BEFORE UPDATE ON price_point
    FOR EACH ROW
    EXECUTE FUNCTION record_price_revision();

-- ---------------------------------------------------------------
-- poll_run
-- ---------------------------------------------------------------
--
-- /health currently reports liveness only, because there is no recorded
-- state to report. With this, it can answer the question that actually
-- matters: when did each upstream last give us data?
--
-- NO_DATA is deliberately distinct from FAILED. "The auction has not
-- cleared yet" is normal every morning; "ENTSO-E is unreachable" is not.

CREATE TABLE IF NOT EXISTS poll_run (
    id              bigserial   PRIMARY KEY,
    source          text        NOT NULL,
    bidding_zone    text        NOT NULL,
    started_at      timestamptz NOT NULL DEFAULT now(),
    finished_at     timestamptz,
    status          text        NOT NULL,
    points_written  integer,
    detail          text,

    CONSTRAINT poll_run_status_ck CHECK (status IN ('SUCCESS', 'NO_DATA', 'FAILED'))
);

CREATE INDEX IF NOT EXISTS poll_run_recent_idx
    ON poll_run (source, started_at DESC);

COMMENT ON TABLE poll_run IS
    'Outcome of each scheduled poll. Feeds a meaningful /health.';

-- Last successful poll per source, for /health to read in one query.
CREATE OR REPLACE VIEW upstream_health AS
SELECT
    source,
    max(started_at) FILTER (WHERE status = 'SUCCESS')  AS last_success_at,
    max(started_at)                                     AS last_attempt_at,
    count(*) FILTER (
        WHERE status = 'FAILED'
          AND started_at > now() - interval '24 hours') AS failures_24h
FROM poll_run
GROUP BY source;

COMMENT ON VIEW upstream_health IS
    'Per-source poll health, read by /health.';
