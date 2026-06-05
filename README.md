# Fraud-Ops Orchestrator — Complete Guide

A FastAPI service that **picks fraud complaints another service has written into
Postgres**, runs a resumable state machine over each one, calls the upstream
**HSBC MHA Gateway** (transaction enquiry, balance enquiry, apply-hold, UPI
beneficiary lookup, CBDOC/BigQuery), holds funds, traces the money trail, and
writes a collated response keyed by `job_id` + `acknowledgement_no`.

This document explains every file, the processing logic end to end, the
configuration, how to run it locally with **DBeaver (no Docker, no psql)**, and a
**step-by-step walkthrough of the 10 test cases**.

-----

## 1. Where this service sits

```
[Other service]  --writes-->  Postgres  (complaints / instruments / incidents, status = OPEN)
                                  |
   Cloud Scheduler --POST /process-batch every 1-2 min-->  THIS service
                                  |
                                  v
                         HSBC MHA Gateway
                  (transaction enquiry / balance / hold / UPI / CBDOC search)
                                  |
                                  v
                Postgres:  complaint_processing  (state machine, this service owns)
                           processing_steps      (per-call audit + idempotency)
                           api_response_logs      (the final MHA response)
```

- This service does **not** ingest from MHA. A separate service inserts the
  complaint rows. We only read them.
- The entry point is the poller: **`POST /process-batch`**, called on a timer by
  Cloud Scheduler. At ~100 complaints/day a queue (Pub/Sub, Cloud Tasks) is
  overkill — polling the table is simpler and fully sufficient.

## 2. Schema safety

This service makes **zero changes to the shared tables** `complaints`,
`instruments`, `incidents`, `api_response_logs` (your fixed schema.txt). It
treats `complaints` as **read-only** — it never writes there, not even `status`.
All processing state lives in **two tables this service alone owns**, created by
`orchestrator_tables.sql`:

|Table                 |Purpose                                                                                      |
|----------------------|---------------------------------------------------------------------------------------------|
|`complaint_processing`|one row per complaint: state machine, lease, `job_id`, attempt count, last error             |
|`processing_steps`    |one row per external API call: audit trail + the `idempotency_key` that prevents double-holds|

The only shared table written is `api_response_logs` — which is its designed
purpose (the response table).

-----

## 3. The files, explained

### Application code

|File               |What it does                                                                                                                                                                                                                                                                                                |
|-------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|`main.py`          |The FastAPI app. Routes: `GET /health` (also pings the DB), `POST /process-batch` (the polling tick), `POST /process/{ack_no}` (manual single-complaint trigger), `GET /api/v1/complaints/{ack_no}` (status + final response), and a **testing-only** `POST /api/v1/complaints` to seed a complaint locally.|
|`processor.py`     |The engine. Claims a batch, runs the resumable state machine, calls the gateway, applies the idempotent hold, runs the CBDOC reconciliation, and writes the final response. This is the heart of the system.                                                                                                |
|`gateway_client.py`|Thin HTTP client for the 5 upstream gateway endpoints. Handles the optional OIDC token for service-to-service auth, and the sensitive-data tokenisation the gateway expects.                                                                                                                                |
|`classifier.py`    |Turns an instrument + incidents into a routing decision: channel (UPI vs Internet Banking), direction (debit vs credit), and recent (< 24h) vs old.                                                                                                                                                         |
|`models.py`        |SQLAlchemy ORM. Shared tables mapped read-only; the two owned tables defined here. PG enums and generated columns handled.                                                                                                                                                                                  |
|`schemas.py`       |Pydantic models for the inbound MHA payload (tolerant of the vendor’s spaced/typo’d keys).                                                                                                                                                                                                                  |
|`db.py`            |Postgres connection via **pg8000** using plain host/user/password (the same way you connect in DBeaver). Supports Cloud Run’s unix socket for deployment.                                                                                                                                                   |
|`config.py`        |All configuration, read from environment / `.env`. See the config reference below.                                                                                                                                                                                                                          |
|`logger.py`        |Centralised logging to stdout (Cloud Run captures it).                                                                                                                                                                                                                                                      |

### SQL

|File                     |What it does                                                                                                                       |
|-------------------------|-----------------------------------------------------------------------------------------------------------------------------------|
|`local_setup.sql`        |Recreates the **shared** schema.txt tables on a *blank* local DB. Skip it if your DB already has those tables.                     |
|`orchestrator_tables.sql`|Creates the **two owned** tables (`complaint_processing`, `processing_steps`). Run this against your DB — it’s safe and idempotent.|
|`seed.sql`               |Inserts ONE complaint (simulating the other service) for a quick smoke test.                                                       |
|`seed_tests.sql`         |Inserts **10 labelled test complaints**, one per code path (see section 8).                                                        |

### Testing / ops

|File                   |What it does                                                                                                                                                                    |
|-----------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|`mock_gateway.py`      |A fake HSBC gateway so you can test the whole flow with no bank connectivity. It derives balances and CBDOC recoveries from the account number so one mock exercises every path.|
|`run_local.sh`         |Starts the mock gateway + the orchestrator together.                                                                                                                            |
|`smoke_test.sh`        |Drives one complaint through (health -> process-batch -> status).                                                                                                               |
|`TEST_MATRIX.md`       |The 10 test cases in a table with expected outcomes.                                                                                                                            |
|`sample_complaint.json`|A valid payload for the testing-only ingest endpoint.                                                                                                                           |
|`requirements.txt`     |Python dependencies.                                                                                                                                                            |
|`.env.sample`          |Template for your `.env`.                                                                                                                                                       |

-----

## 4. Processing logic (the state machine)

Each complaint advances through these states, stored in
`complaint_processing.processing_state`. **State is committed after every step**,
so if the process crashes or a step fails, the next tick resumes exactly where it
left off — nothing is reprocessed, nothing is lost.

```
RECEIVED -> CLASSIFIED -> ENRICHED -> BALANCE_CHECKED
         -> HOLD_APPLIED -> RECONCILING -> RESOLVED
                                        -> NEEDS_REVIEW   (terminal, needs a human)
```

What happens in each state:

1. **RECEIVED -> CLASSIFIED**
   `classifier.py` derives:
- **channel**: `UPI` if the sub-category or payment mode mentions UPI, else `INTERNET_BANKING`.
- **direction**: `CREDIT` if the payment mode says credit, else `DEBIT`.
- **recent**: fraud age = `now - transaction_at`; recent if `< FRAUD_AGE_THRESHOLD_HOURS` (24h).
1. **CLASSIFIED -> ENRICHED** — get beneficiary / transaction context:
- **UPI + debit** -> call the **UPI beneficiary lookup** (`/upi/secure`) per incident. (This path needs only the beneficiary, no hold — it short-circuits to RESOLVED.)
- **recent (< 24h)** -> **transaction enquiry** (`/transactions/history`): fetch the account’s transactions, then for each incident find the transaction whose `transactionNarrative` list contains the RRN (`merchant_id`). The matched transaction (with its beneficiary-chain narratives) is captured.
- **old (> 24h)** -> **CBDOC / BigQuery** locate the disputed transaction by account + amount + date + ref.
1. **ENRICHED -> BALANCE_CHECKED** — call the **balance enquiry** (`/accounts/demand-deposit`) and read `currentBalance.amount` (found via a configurable path, with a deep-search fallback that tolerates either a scalar or an `{amount}` object anywhere in the response).
1. **BALANCE_CHECKED -> HOLD_APPLIED** — decide the hold:
- `D` = total disputed (sum of all incidents’ disputed_amount), `B` = balance.
- Hold `min(D, B)`. Remaining `R = D - min(D, B)`.
- The hold is **idempotent**: guarded by a `UNIQUE idempotency_key`
  (`HOLD:<ack>:<account>:<amount>`) in `processing_steps`. A retry that finds a
  prior success **skips the call** — a customer is never double-held.
1. **HOLD_APPLIED -> …**
- If `R == 0` (balance covered everything) -> finalize -> **RESOLVED**.
- If `R > 0` (partial hold, or no balance) -> **RECONCILING**.
1. **RECONCILING -> RESOLVED / NEEDS_REVIEW** — the **account-centric CBDOC reconciliation**:
- Pull the account’s **debit** transactions from CBDOC.
- **Anchor on the fraud transaction by reference number** — start the walk at the first debit whose ref matches a fraud RRN.
- Walk the account’s debits **chronologically**, accumulating each amount.
- Stop when the running total reconciles `R`. **Every collected debit goes into the MHA response.**
- If the account’s debits never sum to `R` -> **NEEDS_REVIEW** (with everything collected so far still saved).
1. **Failure handling** — any exception during processing increments
   `attempt_count`, records `last_error`, and leaves the row for the next tick.
   After `MAX_ATTEMPTS` it parks in **NEEDS_REVIEW**. “Never fail” means: never
   lose a complaint, never double-act, always reach a terminal state.

### The final MHA response

Written to `api_response_logs.response_payload` as:

```json
{
  "acknowledgement_no": "...",
  "job_id": "BANKS-...",
  "transactions": [ "hold entries + matched transaction details + reconciliation debits" ]
}
```

### Every external call is recorded

`processing_steps` logs each call with a `step` type and the response — this is
both the audit trail and the idempotency / resume mechanism:

|step         |meaning                                         |
|-------------|------------------------------------------------|
|`UPI_BENE`   |UPI beneficiary lookup                          |
|`TXN_ENQUIRY`|transaction enquiry (the account’s transactions)|
|`DD_TXN`     |the per-incident match of a transaction by RRN  |
|`DD_ENQUIRY` |balance enquiry                                 |
|`HOLD`       |apply-hold (the idempotency guard lives here)   |
|`BQ_TRACE`   |CBDOC/BigQuery search (locate + account debits) |

-----

## 5. The polling trigger

`POST /process-batch` does, in one tick:

1. **Bootstrap** — create a `complaint_processing` row for any complaint that
   doesn’t have one yet (i.e. rows the other service just inserted). Uses
   `INSERT ... SELECT ... ON CONFLICT DO NOTHING`, so it’s safe across instances.
1. **Claim** — `SELECT ... FOR UPDATE SKIP LOCKED` the non-terminal, lease-free
   rows (oldest first, up to `BATCH_SIZE`), set a lease, assign a `job_id`.
1. **Process** each claimed row in its own transaction through the state machine.

Anything stuck (instance died mid-process, lease expired) is naturally re-picked
on the next tick — no separate sweeper needed. In production, Cloud Scheduler
calls this every 1-2 minutes.

-----

## 6. Configuration reference (`.env`)

|Variable                                            |Meaning                                                                                             |Default                                     |
|----------------------------------------------------|----------------------------------------------------------------------------------------------------|--------------------------------------------|
|`PG_HOST` `PG_PORT` `PG_USER` `PG_PASSWORD` `PG_DB` |Postgres connection (same as DBeaver). On Cloud Run set `PG_HOST=/cloudsql/PROJECT:REGION:INSTANCE`.|localhost:5432                              |
|`DATABASE_URL`                                      |Optional full SQLAlchemy URL that overrides the `PG_*` parts.                                       |—                                           |
|`GATEWAY_BASE_URL`                                  |Base URL of the HSBC gateway (use the mock for local testing).                                      |<http://localhost:8000>                     |
|`USE_OIDC_AUTH` / `GATEWAY_AUDIENCE`                |Set true to mint an OIDC token when calling the real private gateway.                               |false                                       |
|`FRAUD_AGE_THRESHOLD_HOURS`                         |recent vs old boundary.                                                                             |24                                          |
|`BATCH_SIZE`                                        |complaints claimed per tick.                                                                        |10                                          |
|`LEASE_SECONDS`                                     |how long a claimed row stays owned before re-pick.                                                  |300                                         |
|`MAX_ATTEMPTS`                                      |retries before NEEDS_REVIEW.                                                                        |5                                           |
|`BALANCE_PATH`                                      |dotted path to the balance amount in the gateway response.                                          |`data.accounts.0.currentBalance.amount`     |
|`BALANCE_FIELD`                                     |deep-search fallback target if the path misses.                                                     |`currentBalance`                            |
|`TXN_DETAILS_PATH`                                  |path to the transaction list in the enquiry response.                                               |`data.accountInformation.transactionDetails`|
|`HOLD_TYPE` `HOLD_TILL_DATE` `HOLD_CURRENCY`        |mandatory apply-hold fields.                                                                        |`F` / `2099-12-31` / `INR`                  |
|`BQ_FIELD_REF/AMOUNT/DATE/TIME/ACCOUNT/BENE_ACCOUNT`|CBDOC column names used for matching/sorting/tracing.                                               |`OGTRNO/OGPYAM/OGCPDT/OGCPTM/OGBEAC/OGBEAC` |
|`CBDOC_MAX_ROWS`                                    |cap on debits pulled per account.                                                                   |500                                         |


> **To confirm against real data:** `BQ_FIELD_ACCOUNT` must be the CBDOC column
> for the **debited (originating) account** — the one we collect debits *from*.
> The OG* whitelist is beneficiary-centric, so set this to the correct source-account column.

-----

## 7. Run it locally — DBeaver + terminal (no Docker, no psql)

You already connect to your DB in DBeaver. Use that for all SQL; use a terminal
only for Python.

### Step 1 — create the owned tables (DBeaver)

1. Open a SQL editor on your connection.
1. **File -> Open File ->** `orchestrator_tables.sql`.
1. Run the whole script: **Execute SQL Script (Alt+X)** — not the single-statement button.

> If your DB does **not** already have the schema.txt tables (e.g. a brand-new
> local DB), run `local_setup.sql` first the same way.

### Step 2 — point the app at your DB

```bash
cp .env.sample .env
# edit .env: set PG_HOST / PG_PORT / PG_USER / PG_PASSWORD / PG_DB
#            to the same values you use in DBeaver.
# leave GATEWAY_BASE_URL=http://localhost:8000 for local testing.
```

### Step 3 — install Python deps

```bash
python -m venv .venv
source .venv/bin/activate            # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

### Step 4 — seed the 10 test complaints (DBeaver)

Open `seed_tests.sql` and run it with **Alt+X**. This inserts complaints
`TC01`-`TC10` into the shared tables (exactly as the other service would).

### Step 5 — start the mock gateway + the app

```bash
./run_local.sh
```

or, on Windows / two terminals:

```bash
uvicorn mock_gateway:app --port 8000
uvicorn main:app --port 8080 --reload
```

### Step 6 — run one polling tick

```bash
curl -X POST http://localhost:8080/process-batch
```

Batch size is 10, so all 10 cases process in this single tick. (This is exactly
what Cloud Scheduler will call in production.)

### Step 7 — inspect results in DBeaver

```sql
-- Final state of each complaint
SELECT acknowledgement_no, processing_state, attempt_count, last_error
FROM complaint_processing ORDER BY acknowledgement_no;

-- What was held (idempotency: at most one HOLD success per complaint)
SELECT acknowledgement_no, request_payload->>'amount' AS held
FROM processing_steps WHERE step='HOLD' AND status='SUCCESS' ORDER BY 1;

-- The transaction types in each MHA response
SELECT acknowledgement_no, jsonb_agg(t->>'txn_type') AS txn_types
FROM api_response_logs l, jsonb_array_elements(l.response_payload->'transactions') t
GROUP BY 1 ORDER BY 1;
```

### Reset and re-run

```sql
TRUNCATE complaints, instruments, incidents,
         complaint_processing, processing_steps, api_response_logs
RESTART IDENTITY CASCADE;
```

then re-run `seed_tests.sql`.

-----

## 8. The 10 test cases — step by step

The mock gateway makes outcomes deterministic by deriving behaviour from the
**account number**: `BALANCES[account]` sets the balance the balance-enquiry
returns, and `ACCOUNT_TRACE[account]` sets how much the CBDOC search “recovers”.
Accounts not listed default to a high balance and zero recovery.

For every case the engine first runs **RECEIVED -> CLASSIFIED -> ENRICHED**, then
diverges. “Recent” cases enrich via transaction enquiry; “old” via CBDOC; UPI-debit
via the UPI lookup.

### TC01 — Internet-Banking debit, recent, balance covers -> full hold

- Account `ACC-FULL-0001`, balance 100000, disputed 35, transaction ~3h ago.
- **Classify**: channel INTERNET_BANKING, direction DEBIT, recent.
- **Enrich**: transaction enquiry; the incident RRN `244444440001` is matched in a transaction’s narratives.
- **Balance**: reads `currentBalance.amount` = 100000.
- **Hold**: `min(35, 100000) = 35`. Remaining 0.
- **Finalize -> RESOLVED.** Response: `Transaction Put on Hold (35)` + `Transaction Details`.

### TC02 — IB debit, recent, TWO incidents -> hold the sum

- Account `ACC-FULL-0002`, balance 100000, incidents disputed 35 and 65.
- **Disputed total = 100** (the engine sums all incidents).
- **Hold** 100, remaining 0 -> **RESOLVED.** Response includes two `Transaction Details` (one per matched incident) + `Transaction Put on Hold (100)`.

### TC03 — IB debit, OLD (> 24h), balance covers

- Account `ACC-FULL-0003`, transaction ~4 days ago, disputed 50.
- **Classify**: old. **Enrich** goes through **CBDOC** locate (not transaction enquiry), so there is *no* `Transaction Details` entry.
- **Hold** 50, remaining 0 -> **RESOLVED.** Response: `Transaction Put on Hold (50)`.

### TC04 — IB credit, recent, balance covers

- Account `ACC-FULL-0004`, mode Credit, disputed 75.
- **Classify**: direction CREDIT (still flows through balance -> hold; not the UPI-debit short-circuit).
- **Hold** 75, remaining 0 -> **RESOLVED.**

### TC05 — partial hold + CBDOC reconciliation succeeds

- Account `ACC-PART-0001`, **balance 20**, disputed 35, CBDOC recovery 1000.
- **Hold** `min(35, 20) = 20`. **Remaining 15** -> **RECONCILING**.
- **CBDOC**: pull the account’s debits; anchor on the fraud ref; accumulate debits until >= 15 -> reconciled.
- **RESOLVED.** Response: `Transaction Put on Hold (20)` + `Transaction Details` + one or more `Money Transfer To` debits.

### TC06 — partial hold, CBDOC reconciliation FALLS SHORT -> review

- Account `ACC-PART-0002`, **balance 20**, disputed 35, CBDOC recovery only **5**.
- **Hold** 20, remaining 15 -> **RECONCILING**.
- **CBDOC**: the account’s debits sum to only 5, which is `< 15`. Cannot reconcile.
- **NEEDS_REVIEW** with `last_error = "CBDOC account debits did not reconcile the disputed amount"`. All collected debits are still saved in the response for the human reviewer.

### TC07 — zero balance -> recover entirely via CBDOC

- Account `ACC-ZERO-0001`, **balance 0**, disputed 35, CBDOC recovery 1000.
- **Hold** `min(35, 0) = 0` -> **no hold step recorded**. Remaining 35 -> **RECONCILING**.
- **CBDOC** accumulates debits until >= 35 -> reconciled -> **RESOLVED.** Response has the `Money Transfer To` debits (no hold entry).

### TC08 — UPI debit -> beneficiary lookup only

- Account `ACC-UPI-0001`, sub-category UPI, mode UPI.
- **Classify**: channel UPI + direction DEBIT -> the **short-circuit** path.
- **Enrich** calls the UPI beneficiary lookup; no balance check, no hold.
- **RESOLVED.** Response: `Beneficiary Lookup`.

### TC09 — UPI credit -> hold path

- Account `ACC-UPI-0002`, sub-category UPI, mode Credit, disputed 40.
- **Classify**: channel UPI but direction CREDIT -> **not** the bene short-circuit. Goes through balance -> hold like an IB case.
- **Hold** 40 -> **RESOLVED.**

### TC10 — complaint with no instrument -> review (edge case)

- A complaint row with no `instruments`/`incidents` (malformed input).
- The state machine detects there’s nothing to act on -> **NEEDS_REVIEW** with
  `last_error = "no instrument/incidents on complaint"`. Proves a bad record is
  never silently dropped.

### Expected summary after one tick

|State       |Cases                                             |
|------------|--------------------------------------------------|
|RESOLVED    |TC01, TC02, TC03, TC04, TC05, TC07, TC08, TC09 (8)|
|NEEDS_REVIEW|TC06 (can’t reconcile), TC10 (no instrument) (2)  |

Holds recorded: TC01=35, TC02=100, TC03=50, TC04=75, TC05=20, TC06=20, TC09=40
(TC07 and TC08 record none). Re-running the tick claims **0** and adds **no new
holds** — proof that terminal rows aren’t reprocessed and holds are idempotent.

-----

## 9. Deploy (Cloud Run + Cloud Scheduler)

```bash
gcloud run deploy fraud-ops-orchestrator \
  --source . --region "$REGION" --no-allow-unauthenticated \
  --add-cloudsql-instances "$PROJECT:$REGION:$INSTANCE" \
  --set-env-vars "PG_HOST=/cloudsql/$PROJECT:$REGION:$INSTANCE,PG_PORT=5432,PG_DB=$DB,GATEWAY_BASE_URL=$GATEWAY_URL,USE_OIDC_AUTH=true,GATEWAY_AUDIENCE=$GATEWAY_URL" \
  --set-secrets "PG_USER=PG_USER:latest,PG_PASSWORD=PG_PASSWORD:latest"

# The polling tick (free cron). Its service account needs run.invoker on this service.
gcloud scheduler jobs create http fraud-ops-tick \
  --location "$REGION" --schedule "*/2 * * * *" \
  --uri "$ORCH_URL/process-batch" --http-method POST \
  --oidc-service-account-email "$SCHED_SA" --oidc-token-audience "$ORCH_URL"
```

For this service to call the **real private gateway**, set `USE_OIDC_AUTH=true`

- `GATEWAY_AUDIENCE`, and grant its service account `roles/run.invoker` on the
  gateway.

-----

## 10. Items to confirm against real HSBC contracts

All are `.env` config, so no code change is needed to fix them:

1. **`BALANCE_PATH`** — the exact path to the balance amount. The code logs the
   real path it found via deep-search; copy that into `.env`.
1. **`BQ_FIELD_ACCOUNT`** — the CBDOC column for the **debited/originating**
   account (the one we collect debits from).
1. **UPI `/upi/secure` payload keys** — `rrn`, `accountNumber`, `amount`,
   `transactionTimestamp`.
1. **Narrative field mapping** — the transaction-enquiry narratives carry the
   beneficiary chain positionally (e.g. `HDFC/500021522001`). We store the full
   list; if you give the position spec we can parse into named fields.