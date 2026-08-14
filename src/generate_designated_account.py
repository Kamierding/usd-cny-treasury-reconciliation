#!/usr/bin/env python3
"""Generate the simplified Module 3 designated client-money account roll-forward.

The account is generated independently from the safeguarding calculation. It
uses observable payment cash flows and does not target a control outcome.
"""

from __future__ import annotations

import argparse
import csv
from collections import defaultdict
from datetime import date, datetime, time, timedelta
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path
from zoneinfo import ZoneInfo

from generate_transactions import DEFAULT_US_BANK_HOLIDAYS


USD_CENT = Decimal("0.01")
ZERO = Decimal("0.00")
NEW_YORK = ZoneInfo("America/New_York")

OUTPUT_FIELDS = (
    "balance_date",
    "control_cutoff_timestamp_local",
    "account_id",
    "entity",
    "currency",
    "opening_balance_usd",
    "cleared_customer_receipts_usd",
    "operating_topups_usd",
    "partner_fx_funding_debits_usd",
    "partner_fee_debits_usd",
    "operating_sweeps_usd",
    "closing_balance_usd",
)


def money(value: Decimal) -> Decimal:
    return value.quantize(USD_CENT, rounding=ROUND_HALF_UP)


def parse_date(value: str) -> date:
    return date.fromisoformat(value)


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def next_us_business_day(value: date, us_holidays: frozenset[date]) -> date:
    candidate = value + timedelta(days=1)
    while candidate.weekday() >= 5 or candidate in us_holidays:
        candidate += timedelta(days=1)
    return candidate


def build_daily_flows(
    ledger_rows: list[dict[str, str]],
    bank_rows: list[dict[str, str]],
    customer_rows: list[dict[str, str]],
    us_holidays: frozenset[date],
) -> tuple[list[dict[str, str]], Decimal]:
    ledger_by_instruction = {
        row["partner_instruction_id"]: row for row in ledger_rows
    }
    if len(ledger_by_instruction) != len(ledger_rows):
        raise ValueError("ledger contains duplicate partner_instruction_id values")

    bank_instruction_ids = [row["partner_instruction_id"] for row in bank_rows]
    if len(set(bank_instruction_ids)) != len(bank_instruction_ids):
        raise ValueError("bank data contains duplicate partner_instruction_id values")

    balance_dates = sorted({parse_date(row["balance_date"]) for row in customer_rows})
    if not balance_dates:
        raise ValueError("customer balance data is empty")

    first_date = balance_dates[0]
    opening_balance = money(
        sum(
            (
                Decimal(row["opening_balance"])
                for row in customer_rows
                if parse_date(row["balance_date"]) == first_date
            ),
            ZERO,
        )
    )

    receipts_by_date: defaultdict[date, Decimal] = defaultdict(lambda: ZERO)
    for row in customer_rows:
        flow_date = parse_date(row["balance_date"])
        receipts_by_date[flow_date] += Decimal(row["funding_inflows"])

    fx_debits_by_date: defaultdict[date, Decimal] = defaultdict(lambda: ZERO)
    fee_debits_by_date: defaultdict[date, Decimal] = defaultdict(lambda: ZERO)
    topups_by_date: defaultdict[date, Decimal] = defaultdict(lambda: ZERO)
    sweeps_by_date: defaultdict[date, Decimal] = defaultdict(lambda: ZERO)

    for bank_row in bank_rows:
        instruction_id = bank_row["partner_instruction_id"]
        ledger_row = ledger_by_instruction.get(instruction_id)
        if ledger_row is None:
            raise ValueError(f"bank instruction {instruction_id} has no ledger row")
        if bank_row["external_status"] != "SETTLED":
            raise ValueError(f"bank instruction {instruction_id} is not SETTLED")
        if (
            ledger_row["source_currency"] != "USD"
            or bank_row["source_currency"] != "USD"
        ):
            raise ValueError(f"bank instruction {instruction_id} is not USD-funded")

        value_date = parse_date(bank_row["value_date"])
        source_amount = Decimal(ledger_row["source_amount_usd"])
        fee_amount = Decimal(bank_row["fee_amount_usd"])
        fx_funding_amount = Decimal(bank_row["fx_execution_source_amount_usd"])

        fee_debits_by_date[value_date] += fee_amount
        fx_debits_by_date[value_date] += fx_funding_amount

        execution_residual = money(source_amount - fee_amount - fx_funding_amount)
        transfer_date = next_us_business_day(value_date, us_holidays)
        if execution_residual > ZERO:
            sweeps_by_date[transfer_date] += execution_residual
        elif execution_residual < ZERO:
            topups_by_date[transfer_date] += -execution_residual

    rows: list[dict[str, str]] = []
    current_opening = opening_balance
    for balance_date in balance_dates:
        receipts = money(receipts_by_date[balance_date])
        topups = money(topups_by_date[balance_date])
        fx_debits = money(fx_debits_by_date[balance_date])
        fee_debits = money(fee_debits_by_date[balance_date])
        sweeps = money(sweeps_by_date[balance_date])
        closing = money(
            current_opening
            + receipts
            + topups
            - fx_debits
            - fee_debits
            - sweeps
        )

        cutoff = datetime.combine(
            balance_date, time(23, 59, 59), tzinfo=NEW_YORK
        ).isoformat()
        rows.append(
            {
                "balance_date": balance_date.isoformat(),
                "control_cutoff_timestamp_local": cutoff,
                "account_id": "CLIENT_MONEY_USD_01",
                "entity": "GLOBALPAY_US",
                "currency": "USD",
                "opening_balance_usd": f"{current_opening:.2f}",
                "cleared_customer_receipts_usd": f"{receipts:.2f}",
                "operating_topups_usd": f"{topups:.2f}",
                "partner_fx_funding_debits_usd": f"{fx_debits:.2f}",
                "partner_fee_debits_usd": f"{fee_debits:.2f}",
                "operating_sweeps_usd": f"{sweeps:.2f}",
                "closing_balance_usd": f"{closing:.2f}",
            }
        )
        current_opening = closing

    return rows, opening_balance


def validate_roll_forward(rows: list[dict[str, str]]) -> None:
    previous_closing: Decimal | None = None
    for row in rows:
        opening = Decimal(row["opening_balance_usd"])
        receipts = Decimal(row["cleared_customer_receipts_usd"])
        topups = Decimal(row["operating_topups_usd"])
        fx_debits = Decimal(row["partner_fx_funding_debits_usd"])
        fee_debits = Decimal(row["partner_fee_debits_usd"])
        sweeps = Decimal(row["operating_sweeps_usd"])
        closing = Decimal(row["closing_balance_usd"])

        if previous_closing is not None and opening != previous_closing:
            raise ValueError(f"opening balance does not roll on {row['balance_date']}")
        expected_closing = money(
            opening + receipts + topups - fx_debits - fee_debits - sweeps
        )
        if closing != expected_closing:
            raise ValueError(f"closing balance does not roll on {row['balance_date']}")
        previous_closing = closing


def write_csv(path: Path, rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=OUTPUT_FIELDS)
        writer.writeheader()
        writer.writerows(rows)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate the Module 3 designated-account roll-forward."
    )
    parser.add_argument("--data-dir", type=Path, default=Path("data"))
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("data/designated_account_balances.csv"),
    )
    parser.add_argument(
        "--us-holiday",
        action="append",
        default=[],
        metavar="YYYY-MM-DD",
        help="Add a US banking holiday used for operating transfer scheduling.",
    )
    return parser


def main() -> None:
    args = build_parser().parse_args()
    us_holidays = frozenset(
        set(DEFAULT_US_BANK_HOLIDAYS) | {parse_date(value) for value in args.us_holiday}
    )
    ledger_rows = read_csv(args.data_dir / "ledger.csv")
    bank_rows = read_csv(args.data_dir / "bank_transactions.csv")
    customer_rows = read_csv(args.data_dir / "customer_balances.csv")

    rows, opening_balance = build_daily_flows(
        ledger_rows, bank_rows, customer_rows, us_holidays
    )
    validate_roll_forward(rows)
    write_csv(args.output, rows)

    print(f"Wrote {len(rows)} daily account rows to {args.output}")
    print(f"Initial designated-account opening balance: {opening_balance:.2f} USD")
    print(f"Final designated-account closing balance: {rows[-1]['closing_balance_usd']} USD")


if __name__ == "__main__":
    main()
