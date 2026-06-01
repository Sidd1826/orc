"""
mock_gateway.py — Tiny stand-in for the HSBC MHA Gateway, for local testing.

Implements the same 4 endpoints with canned responses so the worker can run
its full state machine end-to-end without any HSBC connectivity.

Run with:
  uvicorn mock_gateway:app --host 0.0.0.0 --port 9000 --reload

Behaviours you can tweak inline below:
  * MOCK_BALANCE         — what demand-deposit returns
  * MOCK_TRACE_ROWS      — what /search returns when tracing
  * FAIL_RATES           — set non-zero to test retry paths
"""
from __future__ import annotations

import random
import uuid
from typing import Any

from fastapi import Body, FastAPI, Query, Request

app = FastAPI(title="Mock HSBC Gateway", version="0.1.0")


# ---------------------------------------------------------------------------
# Tunables — edit to exercise different worker paths
# ---------------------------------------------------------------------------

# Default available balance on the account (string, two decimals as the real
# API returns). Adjust to flip between FULL_HOLD vs PARTIAL_HOLD paths.
MOCK_BALANCE = "5000.00"

# How many rows /search returns when the worker traces a fraud trail.
MOCK_TRACE_ROW_COUNT = 12

# Per-endpoint failure rate (0.0 to 1.0) — useful for testing retries.
FAIL_RATES: dict[str, float] = {
    "demand_deposit": 0.0,
    "transaction_history": 0.0,
    "apply_hold": 0.0,
    "search": 0.0,
}


def _maybe_fail(op: str) -> None:
    if random.random() < FAIL_RATES.get(op, 0.0):
        from fastapi import HTTPException
        raise HTTPException(status_code=503, detail=f"mock injected failure: {op}")


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

@app.get("/healthz")
async def health():
    return {"status": "ok", "service": "mock-hsbc-gateway"}


# ---------------------------------------------------------------------------
# Demand deposit (balance)
# ---------------------------------------------------------------------------

@app.get("/api/v1/accounts/demand-deposit")
async def demand_deposit(
    request: Request,
    hubCustomerNumber: str = Query(...),
    body: dict[str, Any] = Body(...),
):
    _maybe_fail("demand_deposit")
    return {
        "requestId": str(uuid.uuid4()),
        "data": {
            "hubCustomerNumber": hubCustomerNumber,
            "availableBalance":  MOCK_BALANCE,
            "currency":          "INR",
            "accountStatus":     "ACTIVE",
        },
    }


# ---------------------------------------------------------------------------
# Transaction history (< 24h flow)
# ---------------------------------------------------------------------------

@app.get("/api/v1/transactions/history")
async def transaction_history(
    request: Request,
    accountNumber: str = Query(...),
    fromDate: str = Query(None),
    toDate:   str = Query(None),
    body: dict[str, Any] = Body(...),
):
    _maybe_fail("transaction_history")
    return {
        "requestId": str(uuid.uuid4()),
        "data": {
            "accountNumber": accountNumber,
            "fromDate":      fromDate,
            "toDate":        toDate,
            "transactions": [
                {
                    "txnRef":      "TXN" + str(random.randint(10**9, 10**10 - 1)),
                    "amount":      "100.00",
                    "currency":    "INR",
                    "txnDateTime": "2026-05-30T10:15:42Z",
                    "narrative":   "FRAUD_TXN_MARKER",
                },
            ],
        },
    }


# ---------------------------------------------------------------------------
# Apply hold
# ---------------------------------------------------------------------------

@app.post("/api/v1/accounts/apply-hold")
async def apply_hold(request: Request, body: dict[str, Any] = Body(...)):
    _maybe_fail("apply_hold")
    details = body.get("applyHoldDetails", {})
    return {
        "requestId": str(uuid.uuid4()),
        "data": {
            "status":        "OK",
            "holdReference": "HOLD-" + uuid.uuid4().hex[:12].upper(),
            "accountNumber": details.get("accountNumber"),
            "holdAmount":    details.get("holdAmount"),
            "holdCurrency":  details.get("holdCurrency"),
        },
    }


# ---------------------------------------------------------------------------
# BigQuery search
# ---------------------------------------------------------------------------

@app.post("/api/v1/search")
async def search(request: Request, body: dict[str, Any] = Body(...)):
    _maybe_fail("search")

    # Pull filters out, drop the limit key.
    filters = {k: v for k, v in body.items() if k != "limit"}
    limit = int(body.get("limit", 100))

    # Build deterministic-ish rows so traces are inspectable.
    rows = []
    seed_acct = filters.get("OGBEAC", "UNKNOWN")
    for i in range(min(MOCK_TRACE_ROW_COUNT, limit)):
        rows.append({
            "OGBEAC": seed_acct,
            "OGTRNO": f"REF{i:06d}",
            "OGPYAM": float(50 + i * 25),       # 50, 75, 100, 125, ...
            "OGPYCY": "INR",
            "OGCPDT": 20260530,
            "OGCPTM": 100000 + i,
            "OGNAR1": f"layered hop {i}",
        })

    return {
        "requestId":   str(uuid.uuid4()),
        "filters_used": filters,
        "row_count":   len(rows),
        "rows":        rows,
    }
