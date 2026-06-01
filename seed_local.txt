"""
seed_local.py — Inserts one complaint + instrument + incident for local testing.

Run with:
  python seed_local.py

Re-run-safe: it deletes any prior row with the same acknowledgement_no before
inserting.
"""
from __future__ import annotations

import asyncio
from datetime import datetime, time, timedelta, timezone
from decimal import Decimal

from sqlalchemy import delete, select

import config  # loads .env
from db import close_db, init_db, session_scope
from models import Complaint, Incident, Instrument


ACK_NO = "TEST-LOCAL-0001"


async def main() -> None:
    await init_db()
    try:
        async with session_scope() as s:
            # Wipe any previous seed
            existing = (await s.execute(
                select(Complaint).where(Complaint.acknowledgement_no == ACK_NO)
            )).scalar_one_or_none()
            if existing is not None:
                await s.execute(delete(Complaint).where(Complaint.id == existing.id))
                print(f"Deleted prior complaint id={existing.id}")

            now = datetime.now(timezone.utc)

            c = Complaint(
                acknowledgement_no=ACK_NO,
                sub_category="UPI Related Frauds",
                status="OPEN",
                created_at=now,
                updated_at=now,
                attempt_count=0,
            )
            s.add(c)
            await s.flush()

            i = Instrument(
                complaint_id=c.id,
                requestor="I4C-MHA",
                payer_bank="HSBC",
                payer_bank_code="HSBC0001",
                mode_of_payment="UPI",
                transaction_type="P2P",
                payer_mobile_number="9999999999",
                payer_account_number="INHSBC500021738001",
                state="Maharashtra",
                district="Mumbai",
                created_at=now,
                updated_at=now,
            )
            s.add(i)
            await s.flush()

            inc_at = now - timedelta(hours=4)   # fresh — within 24h window
            inc = Incident(
                instrument_id=i.id,
                merchant_id="FRAUD_MERCHANT_001",
                amount=Decimal("1000.00"),
                disputed_amount=Decimal("1000.00"),
                layer=0,
                transaction_date=inc_at.date(),
                transaction_time=time(inc_at.hour, inc_at.minute, inc_at.second),
                transaction_at=inc_at,
                created_at=now,
                updated_at=now,
            )
            s.add(inc)
            await s.flush()

            print(f"Seeded complaint id={c.id} ack={ACK_NO}")
            print(f"  instrument id={i.id} account={i.payer_account_number}")
            print(f"  incident   id={inc.id} amount={inc.amount} (fresh, {inc_at.isoformat()})")
    finally:
        await close_db()


if __name__ == "__main__":
    asyncio.run(main())
