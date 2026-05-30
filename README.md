# fraud-worker

Cloud Run worker that picks fraud complaint rows from Postgres, runs the
investigation state machine against the HSBC MHA Gateway (sibling Cloud
Run), and writes a final JSON response for the sender service to deliver
to MHA.

## What it does

For each complaint:

1. **Balance enquiry** — calls the gateway's `/api/v1/accounts/demand-deposit`
   to read the available balance on the payer's account.
2. **Transaction detail** — per incident, calls
   `/api/v1/transactions/history` if the txn is within 24 hours, otherwise
   falls back to `/api/v1/search` (BigQuery).
3. **Apply hold** — calls `/api/v1/accounts/apply-hold` for
   `min(disputed_amount, available_balance)`. This call is the one with the
   strongest idempotency guarantees (see below).
4. **Trace** — if the hold was partial, queries BigQuery to follow the
   fraud trail until the disputed amount is covered (or we hit
   `TRACE_MAX_ROWS`).
5. **Assemble** the final JSON and insert it into `complaint_responses`
   with `status='READY'` for the sender service to pick up.

Every external call is logged to `api_response_logs` with a deterministic
`job_id` so retries reuse the same row.

## Trigger model

Cloud Scheduler hits `POST /internal/sweep` every 60 seconds. The sweep
claims up to `SWEEP_BATCH_SIZE` rows using `SELECT … FOR UPDATE SKIP
LOCKED` and processes each through the orchestrator. At ~100/day this is
~4 complaints per hour — well below capacity.

Manual reprocess for ops:

```bash
curl -X POST https://<service>/internal/process/<complaint_id> \
  -H "Authorization: Bearer $(gcloud auth print-identity-token)"
```

## Idempotency — the apply-hold guarantee

A hold must be placed **at most once** per complaint. Three things together
make that true:

1. **Write-ahead log.** Before calling `apply_hold`, the orchestrator
   inserts an `api_response_logs` row with `response_message='PENDING'` and
   commits — so a crash mid-call leaves a marker.
2. **Unique partial index** (in `migration.sql`):
   ```sql
   CREATE UNIQUE INDEX uq_one_successful_hold_per_complaint
       ON api_response_logs(complaint_id)
       WHERE response_message = 'SUCCESS' AND job_id LIKE 'apply_hold:%';
   ```
   The database physically refuses a second successful row.
3. **PENDING → MANUAL_REVIEW.** On retry, if the orchestrator finds a
   `PENDING` `apply_hold` row from a previous crashed attempt, it does
   **not** retry the call. The complaint moves to `MANUAL_REVIEW` so an
   operator can confirm on the account whether the hold actually landed,
   then re-queue.

## State machine

`complaints.status` walks:

```
OPEN
 └─> PROCESSING
      └─> BALANCE_FETCHED
           ├─> HOLD_APPLIED_FULL ────────────────────────┐
           └─> HOLD_APPLIED_PARTIAL ─> TRACING ─> TRACE_COMPLETE
                                                         │
                                                         v
                                                    RESPONSE_READY ─> RESOLVED
```

Off-happy-path:

* `FAILED_RETRYABLE` — picked up on the next sweep.
* `FAILED_TERMINAL` — `attempt_count >= MAX_ATTEMPTS`; needs a human.
* `MANUAL_REVIEW` — data anomaly or PENDING-hold; needs a human.

## Project layout

```
fraud-worker/
├── README.md
├── requirements.txt
├── Dockerfile
├── .env.sample
├── migration.sql        # additions to your existing schema
├── config.py            # env + Secret Manager (same pattern as gateway)
├── logger.py
├── db.py                # async engine, session, claim helper
├── models.py            # SQLAlchemy models + status constants
├── gateway_client.py    # async client for the sibling Cloud Run
├── orchestrator.py      # the state machine for one complaint
├── response_builder.py  # assembles the final JSON
└── main.py              # FastAPI app: /healthz, /internal/sweep, /internal/process/{id}
```

## Local setup

```bash
cp .env.sample .env
# Fill in DB_HOST/DB_PASSWORD/GATEWAY_BASE_URL, set GATEWAY_USE_IAM_AUTH=false

# Apply migration.sql against your local Postgres (after schema.sql)
psql -h localhost -U fraud -d fraud -f migration.sql

pip install -r requirements.txt
uvicorn main:app --reload --port 8000
```

Trigger a sweep manually:
```bash
curl -X POST http://localhost:8000/internal/sweep
```

## Cloud Run deploy

```bash
gcloud run deploy fraud-worker \
  --source . \
  --region asia-south1 \
  --service-account fraud-worker-sa@$PROJECT.iam.gserviceaccount.com \
  --no-allow-unauthenticated \
  --min-instances 1 \
  --max-instances 3 \
  --cpu 1 --memory 512Mi \
  --set-env-vars="GOOGLE_CLOUD_PROJECT=$PROJECT,\
GATEWAY_BASE_URL=https://hsbc-mha-gateway-xxxxx.a.run.app,\
GATEWAY_USE_IAM_AUTH=true,\
DB_USER=fraud,DB_NAME=fraud,INSTANCE_CONNECTION_NAME=$PROJECT:asia-south1:fraud-db,\
SWEEP_BATCH_SIZE=20,MAX_ATTEMPTS=5,FRESH_WINDOW_HOURS=24,\
HOLD_EXPIRY_DATE=2099-12-31"
```

Required service-account roles:
- `roles/cloudsql.client`
- `roles/cloudsql.instanceUser` (IAM DB auth)
- `roles/secretmanager.secretAccessor` (for DB password)
- `roles/run.invoker` **on the gateway service** (Cloud Run → Cloud Run)

Cloud Scheduler:

```bash
gcloud scheduler jobs create http fraud-worker-sweep \
  --location asia-south1 \
  --schedule "* * * * *" \
  --uri "https://fraud-worker-xxxxx.a.run.app/internal/sweep" \
  --http-method POST \
  --oidc-service-account-email fraud-scheduler-sa@$PROJECT.iam.gserviceaccount.com \
  --oidc-token-audience "https://fraud-worker-xxxxx.a.run.app"
```

The scheduler service account needs `roles/run.invoker` on this worker.

## Known TODOs

The code includes clearly-marked TODOs where business rules are uncertain:

1. **`gateway_client.py` — the `accountNumberToken` vs `realAccountNumber`
   contract.** Both currently use `payer_account_number`. If the gateway
   expects a hashed/external token for the URL param and the raw account
   only in `sensitiveData`, change the call sites in `orchestrator.py`.
2. **`orchestrator.py:_extract_balance`** — tries a few common JSON paths
   for the available balance. Once you have a real HSBC response sample,
   trim it to the single correct path.
3. **`orchestrator.py` BQ trace fields** — `BQ_FIELD_*` constants at the
   top of the file. Adjust if the schema's semantic mapping is different
   from "OGBEAC = beneficiary account".
4. **`response_builder.py`** — the final JSON shape is a placeholder.
   Replace with the MHA-specified shape when available.
