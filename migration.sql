-- =============================================================================
-- migration.sql — additions for the fraud worker
--
-- Run this AFTER your existing schema.sql. The fraud worker writes the final
-- per-complaint JSON here; the sender service polls WHERE status='READY'.
-- =============================================================================


CREATE TYPE response_send_status AS ENUM ('READY', 'SENT', 'FAILED');


CREATE TABLE complaint_responses (
    id                  BIGSERIAL PRIMARY KEY,
    complaint_id        BIGINT      NOT NULL UNIQUE
                                    REFERENCES complaints(id) ON DELETE CASCADE,
    acknowledgement_no  VARCHAR(20) NOT NULL,
    response_json       JSONB       NOT NULL,
    status              response_send_status NOT NULL DEFAULT 'READY',
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    sent_at             TIMESTAMPTZ,
    sender_attempts     INT         NOT NULL DEFAULT 0
);

CREATE INDEX idx_complaint_responses_status ON complaint_responses(status);
CREATE INDEX idx_complaint_responses_ack_no ON complaint_responses(acknowledgement_no);


-- -----------------------------------------------------------------------------
-- Idempotency safeguards on api_response_logs.
--
-- 1. Composite key (complaint_id, job_id) — one row per logical call attempt.
-- 2. Partial unique index — at most ONE successful 'apply_hold' per complaint.
--    This is the database-level guarantee that the hold is never placed twice
--    no matter how many times the sweep re-picks the row.
-- -----------------------------------------------------------------------------

CREATE UNIQUE INDEX uq_api_logs_complaint_job
    ON api_response_logs(complaint_id, job_id);

CREATE UNIQUE INDEX uq_one_successful_hold_per_complaint
    ON api_response_logs(complaint_id)
    WHERE response_message = 'SUCCESS' AND job_id LIKE 'apply_hold:%';


-- -----------------------------------------------------------------------------
-- Extended complaint status values + attempt tracking.
-- The schema currently uses VARCHAR(20) for status, so no type change needed.
-- We just add the bookkeeping columns the worker needs.
-- -----------------------------------------------------------------------------

ALTER TABLE complaints
    ADD COLUMN IF NOT EXISTS attempt_count INT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS last_error    TEXT,
    ADD COLUMN IF NOT EXISTS locked_at     TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_complaints_status_locked
    ON complaints(status, locked_at);
