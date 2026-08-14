#!/usr/bin/env python3
"""Generate the Module 1B USD-to-CNY payment simulation datasets.

This module models ordinary payment mechanics. It deliberately does not create
reconciliation classifications, answer-key columns, or a target mismatch rate.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import random
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal, ROUND_CEILING, ROUND_HALF_UP
from pathlib import Path
from typing import Iterable
from zoneinfo import ZoneInfo


USD_CENT = Decimal("0.01")
CNY_FEN = Decimal("0.01")
FX_PRECISION = Decimal("0.000001")
BASIS_POINTS = Decimal("10000")
ZERO = Decimal("0.00")
MIN_PAYMENT_USD = Decimal("500.00")
MAX_PAYMENT_USD = Decimal("50000.00")
NEW_YORK = ZoneInfo("America/New_York")

ENTITY = "GLOBALPAY_US"
SOURCE_CURRENCY = "USD"
DESTINATION_CURRENCY = "CNY"
PAYMENT_METHODS = ("LOCAL_BANK_TRANSFER", "SWIFT")
QUOTE_SPREAD_BPS = Decimal("12")
STARTING_MARKET_RATE = Decimal("7.100000")

DEFAULT_US_BANK_HOLIDAYS = frozenset(
    {
        date(2025, 1, 1),   # New Year's Day
        date(2025, 1, 20),  # Martin Luther King Jr. Day
        date(2025, 2, 17),  # Presidents Day
    }
)
DEFAULT_CHINA_BANK_HOLIDAYS = frozenset(
    {
        date(2025, 1, 1),
        date(2025, 1, 28),
        date(2025, 1, 29),
        date(2025, 1, 30),
        date(2025, 1, 31),
        date(2025, 2, 3),
        date(2025, 2, 4),
        date(2025, 4, 4),  # Qingming Festival
    }
)

LEDGER_FIELDS = (
    "payment_id",
    "partner_instruction_id",
    "customer_id",
    "entity",
    "partner",
    "payment_method",
    "booking_timestamp_utc",
    "booking_date",
    "source_currency",
    "source_amount_usd",
    "destination_currency",
    "quoted_fx_rate",
    "expected_partner_fee_usd",
    "expected_net_source_amount_usd",
    "expected_fx_execution_source_amount_usd",
    "quoted_destination_amount_cny",
    "expected_settlement_date",
    "ledger_status",
)

BANK_FIELDS = (
    "bank_txn_id",
    "partner_instruction_id",
    "bank_reference",
    "partner",
    "payment_method",
    "execution_timestamp_utc",
    "execution_date",
    "value_date",
    "source_currency",
    "fee_amount_usd",
    "fx_execution_source_amount_usd",
    "executed_fx_rate",
    "settlement_currency",
    "settlement_amount_cny",
    "external_status",
)

CUSTOMER_BALANCE_FIELDS = (
    "balance_date",
    "customer_id",
    "entity",
    "currency",
    "opening_balance",
    "funding_inflows",
    "accepted_payment_debits",
    "customer_balance",
)

FORBIDDEN_ANSWER_KEY_FIELDS = {
    "error_type",
    "break_type",
    "expected_classification",
    "is_error",
    "classification",
    "match_status",
}


@dataclass(frozen=True)
class PartnerConfig:
    name: str
    instruction_prefix: str
    cutoff_local: time
    settlement_lag_business_days: int
    expected_fee_rate: Decimal
    expected_fixed_fee_usd: Decimal
    actual_fee_rate: Decimal
    actual_fixed_fee_usd: Decimal
    execution_spread_bps: Decimal
    processing_open_local: time
    processing_close_local: time
    service_minutes_min: int
    service_minutes_mode: int
    service_minutes_max: int


PARTNERS = {
    "PARTNER_A": PartnerConfig(
        name="PARTNER_A",
        instruction_prefix="PA",
        cutoff_local=time(16, 0),
        settlement_lag_business_days=1,
        expected_fee_rate=Decimal("0.0060"),
        expected_fixed_fee_usd=ZERO,
        actual_fee_rate=Decimal("0.0060"),
        actual_fixed_fee_usd=ZERO,
        execution_spread_bps=Decimal("4"),
        processing_open_local=time(9, 0),
        processing_close_local=time(17, 0),
        service_minutes_min=15,
        service_minutes_mode=45,
        service_minutes_max=240,
    ),
    "PARTNER_B": PartnerConfig(
        name="PARTNER_B",
        instruction_prefix="PB",
        cutoff_local=time(14, 0),
        settlement_lag_business_days=2,
        expected_fee_rate=Decimal("0.0035"),
        expected_fixed_fee_usd=Decimal("5.00"),
        actual_fee_rate=Decimal("0.0035"),
        actual_fixed_fee_usd=Decimal("5.00"),
        execution_spread_bps=Decimal("2"),
        processing_open_local=time(9, 0),
        processing_close_local=time(17, 0),
        service_minutes_min=30,
        service_minutes_mode=90,
        service_minutes_max=360,
    ),
}


@dataclass(frozen=True)
class SimulationConfig:
    seed: int
    payment_count: int
    customer_count: int
    start_date: date
    end_date: date
    as_of_date: date
    output_dir: Path
    us_bank_holidays: frozenset[date]
    china_bank_holidays: frozenset[date]


@dataclass(frozen=True)
class PaymentInstruction:
    payment_id: str
    partner_instruction_id: str
    customer_id: str
    partner: str
    payment_method: str
    booking_timestamp_utc: datetime
    source_amount_usd: Decimal


@dataclass(frozen=True)
class BookedPayment:
    """Terms frozen by GlobalPay when an instruction is accepted."""

    instruction: PaymentInstruction
    quoted_fx_rate: Decimal
    expected_partner_fee_usd: Decimal
    expected_net_source_amount_usd: Decimal
    expected_fx_execution_source_amount_usd: Decimal
    committed_destination_amount_cny: Decimal
    expected_settlement_date: date


@dataclass(frozen=True)
class SettlementCalendar:
    us_bank_holidays: frozenset[date]
    china_bank_holidays: frozenset[date]

    def is_business_day(self, value: date) -> bool:
        return (
            value.weekday() < 5
            and value not in self.us_bank_holidays
            and value not in self.china_bank_holidays
        )

    def next_business_day(self, value: date) -> date:
        candidate = value + timedelta(days=1)
        while not self.is_business_day(candidate):
            candidate += timedelta(days=1)
        return candidate

    def add_business_days(self, value: date, days: int) -> date:
        candidate = value
        for _ in range(days):
            candidate = self.next_business_day(candidate)
        return candidate


class MarketRatePath:
    """Seeded hourly USD/CNY observations, held flat on simulated closures."""

    def __init__(
        self,
        start_utc: datetime,
        end_utc: datetime,
        rng: random.Random,
        calendar: SettlementCalendar,
    ):
        self._rates: dict[datetime, Decimal] = {}
        observation = floor_to_hour(start_utc)
        final_observation = floor_to_hour(end_utc)
        rate = STARTING_MARKET_RATE

        while observation <= final_observation:
            market_date = observation.astimezone(NEW_YORK).date()
            if calendar.is_business_day(market_date):
                hourly_return = Decimal(f"{rng.gauss(0.0, 0.00055):.10f}")
                rate = max(
                    Decimal("6.500000"),
                    min(
                        Decimal("7.700000"),
                        rate * (Decimal("1") + hourly_return),
                    ),
                )
            self._rates[observation] = quantize_fx(rate)
            observation += timedelta(hours=1)

    def at(self, timestamp_utc: datetime) -> Decimal:
        observation = floor_to_hour(timestamp_utc.astimezone(timezone.utc))
        try:
            return self._rates[observation]
        except KeyError as exc:
            raise ValueError(f"No market observation for {timestamp_utc.isoformat()}") from exc


def quantize_usd(amount: Decimal) -> Decimal:
    return amount.quantize(USD_CENT, rounding=ROUND_HALF_UP)


def ceil_usd(amount: Decimal) -> Decimal:
    """Round a USD funding requirement upward so fixed CNY is fully funded."""

    return amount.quantize(USD_CENT, rounding=ROUND_CEILING)


def quantize_cny(amount: Decimal) -> Decimal:
    return amount.quantize(CNY_FEN, rounding=ROUND_HALF_UP)


def quantize_fx(rate: Decimal) -> Decimal:
    return rate.quantize(FX_PRECISION, rounding=ROUND_HALF_UP)


def floor_to_hour(value: datetime) -> datetime:
    return value.replace(minute=0, second=0, microsecond=0)


def format_timestamp(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def format_money(value: Decimal) -> str:
    return f"{value:.2f}"


def format_fx(value: Decimal) -> str:
    return f"{value:.6f}"


def named_rng(master_seed: int, stream_name: str) -> random.Random:
    """Create stable, independent random streams from one configurable seed."""

    digest = hashlib.sha256(f"{master_seed}:{stream_name}".encode("utf-8")).digest()
    return random.Random(int.from_bytes(digest[:8], byteorder="big", signed=False))


def expected_settlement_date_for_booking(
    booking_timestamp_utc: datetime,
    partner: PartnerConfig,
    calendar: SettlementCalendar,
) -> date:
    """Freeze the contractual expectation using booking-time information only."""

    booking_local = booking_timestamp_utc.astimezone(NEW_YORK)
    ready_on_booking_date = (
        calendar.is_business_day(booking_local.date())
        and booking_local.time() < partner.cutoff_local
    )
    readiness_date = (
        booking_local.date()
        if ready_on_booking_date
        else calendar.next_business_day(booking_local.date())
    )
    return calendar.add_business_days(
        readiness_date,
        partner.settlement_lag_business_days,
    )


def realized_execution_timestamp_for(
    booking_timestamp_utc: datetime,
    partner: PartnerConfig,
    calendar: SettlementCalendar,
    service_minutes: int,
) -> datetime:
    """Consume realized service time within the partner's banking hours."""

    booking_local = booking_timestamp_utc.astimezone(NEW_YORK)
    accepted_for_same_day_processing = (
        calendar.is_business_day(booking_local.date())
        and booking_local.time() < partner.cutoff_local
    )

    if accepted_for_same_day_processing:
        processing_open = datetime.combine(
            booking_local.date(), partner.processing_open_local, tzinfo=NEW_YORK
        )
        processing_cursor = max(booking_local, processing_open)
    else:
        processing_day = calendar.next_business_day(booking_local.date())
        processing_cursor = datetime.combine(
            processing_day, partner.processing_open_local, tzinfo=NEW_YORK
        )

    remaining_minutes = service_minutes
    while True:
        if not calendar.is_business_day(processing_cursor.date()):
            processing_cursor = datetime.combine(
                calendar.next_business_day(processing_cursor.date()),
                partner.processing_open_local,
                tzinfo=NEW_YORK,
            )

        processing_close = datetime.combine(
            processing_cursor.date(),
            partner.processing_close_local,
            tzinfo=NEW_YORK,
        )
        available_minutes = max(
            0,
            int((processing_close - processing_cursor).total_seconds() // 60),
        )
        if remaining_minutes <= available_minutes:
            execution_local = processing_cursor + timedelta(minutes=remaining_minutes)
            return execution_local.astimezone(timezone.utc)

        remaining_minutes -= available_minutes
        processing_cursor = datetime.combine(
            calendar.next_business_day(processing_cursor.date()),
            partner.processing_open_local,
            tzinfo=NEW_YORK,
        )


def sample_partner_service_minutes(
    partner: PartnerConfig,
    rng: random.Random,
) -> int:
    """Sample ordinary processing effort without selecting a target delay rate."""

    return max(
        1,
        round(
            rng.triangular(
                partner.service_minutes_min,
                partner.service_minutes_max,
                partner.service_minutes_mode,
            )
        ),
    )


def calculate_expected_fee(source_amount_usd: Decimal, partner: PartnerConfig) -> Decimal:
    """Freeze GlobalPay's contractual fee expectation at booking."""

    return quantize_usd(
        source_amount_usd * partner.expected_fee_rate + partner.expected_fixed_fee_usd
    )


def calculate_actual_partner_fee(source_amount_usd: Decimal, partner: PartnerConfig) -> Decimal:
    """Independently assess the fee in the external partner process."""

    return quantize_usd(source_amount_usd * partner.actual_fee_rate + partner.actual_fixed_fee_usd)


def quoted_fx_rate(market_rate: Decimal) -> Decimal:
    return quantize_fx(market_rate * (Decimal("1") - QUOTE_SPREAD_BPS / BASIS_POINTS))


def executed_fx_rate(market_rate: Decimal, partner: PartnerConfig) -> Decimal:
    return quantize_fx(
        market_rate * (Decimal("1") - partner.execution_spread_bps / BASIS_POINTS)
    )


def random_booking_timestamp(day: date, rng: random.Random) -> datetime:
    minute_of_day = rng.randrange(8 * 60, 20 * 60)
    booking_local = datetime.combine(day, time(0, 0), tzinfo=NEW_YORK) + timedelta(
        minutes=minute_of_day
    )
    return booking_local.astimezone(timezone.utc)


def desired_payment_amount(rng: random.Random) -> Decimal:
    sampled = Decimal(f"{rng.lognormvariate(8.55, 0.85):.2f}")
    return quantize_usd(max(MIN_PAYMENT_USD, min(MAX_PAYMENT_USD, sampled)))


def generate_customer_activity(
    config: SimulationConfig,
    calendar: SettlementCalendar,
) -> tuple[list[PaymentInstruction], list[dict[str, str]]]:
    """Generate customer funding, requested payments, and accepted instructions."""

    customer_rng = named_rng(config.seed, "customers")
    funding_rng = named_rng(config.seed, "funding")
    demand_rng = named_rng(config.seed, "payment_demand")
    customers = [f"CUST-{number:04d}" for number in range(1, config.customer_count + 1)]

    balances = {
        customer: quantize_usd(Decimal(f"{customer_rng.uniform(80000, 180000):.2f}"))
        for customer in customers
    }

    total_days = (config.end_date - config.start_date).days + 1
    booking_days = [
        config.start_date + timedelta(days=offset)
        for offset in range(total_days)
        if calendar.is_business_day(config.start_date + timedelta(days=offset))
    ]
    if not booking_days:
        raise ValueError("Simulation period has no configured business days")

    candidates: dict[date, list[tuple[datetime, str, str, str, Decimal]]] = {}
    for _ in range(config.payment_count):
        booking_day = demand_rng.choice(booking_days)
        booking_timestamp = random_booking_timestamp(booking_day, demand_rng)
        customer = demand_rng.choice(customers)
        partner = "PARTNER_A" if demand_rng.random() < 0.55 else "PARTNER_B"
        payment_method = PAYMENT_METHODS[0] if demand_rng.random() < 0.82 else PAYMENT_METHODS[1]
        amount = desired_payment_amount(demand_rng)
        candidates.setdefault(booking_day, []).append(
            (booking_timestamp, customer, partner, payment_method, amount)
        )

    instructions: list[PaymentInstruction] = []
    balance_rows: list[dict[str, str]] = []
    sequence = 0

    for day_offset in range(total_days):
        current_day = config.start_date + timedelta(days=day_offset)
        opening_balances = dict(balances)
        daily_funding = {customer: ZERO for customer in customers}
        daily_debits = {customer: ZERO for customer in customers}

        for customer in customers:
            if calendar.is_business_day(current_day) and funding_rng.random() < 0.06:
                funding = quantize_usd(Decimal(f"{funding_rng.uniform(10000, 60000):.2f}"))
                balances[customer] += funding
                daily_funding[customer] = funding

        daily_candidates = sorted(
            candidates.get(current_day, []),
            key=lambda item: item[0],
        )
        for (
            booking_timestamp,
            customer,
            partner_name,
            payment_method,
            requested_amount,
        ) in daily_candidates:
            if balances[customer] < requested_amount:
                continue

            balances[customer] -= requested_amount
            daily_debits[customer] += requested_amount

            sequence += 1
            prefix = PARTNERS[partner_name].instruction_prefix
            instructions.append(
                PaymentInstruction(
                    payment_id=f"PAY-{sequence:06d}",
                    partner_instruction_id=f"{prefix}-INS-{sequence:06d}",
                    customer_id=customer,
                    partner=partner_name,
                    payment_method=payment_method,
                    booking_timestamp_utc=booking_timestamp,
                    source_amount_usd=requested_amount,
                )
            )

        for customer in customers:
            balance_rows.append(
                {
                    "balance_date": current_day.isoformat(),
                    "customer_id": customer,
                    "entity": ENTITY,
                    "currency": SOURCE_CURRENCY,
                    "opening_balance": format_money(opening_balances[customer]),
                    "funding_inflows": format_money(daily_funding[customer]),
                    "accepted_payment_debits": format_money(daily_debits[customer]),
                    "customer_balance": format_money(balances[customer]),
                }
            )

    instructions.sort(key=lambda instruction: instruction.booking_timestamp_utc)
    return instructions, balance_rows


def build_market_path(
    config: SimulationConfig,
    calendar: SettlementCalendar,
) -> MarketRatePath:
    start_local = datetime.combine(config.start_date, time(0, 0), tzinfo=NEW_YORK)
    end_local = datetime.combine(
        config.end_date + timedelta(days=10), time(23, 59), tzinfo=NEW_YORK
    )
    return MarketRatePath(
        start_local.astimezone(timezone.utc),
        end_local.astimezone(timezone.utc),
        named_rng(config.seed, "fx_market"),
        calendar,
    )


def book_internal_payments(
    instructions: Iterable[PaymentInstruction],
    market: MarketRatePath,
    calendar: SettlementCalendar,
) -> list[BookedPayment]:
    """Freeze customer quote terms and contractual settlement expectations."""

    booked_payments: list[BookedPayment] = []
    for instruction in instructions:
        partner = PARTNERS[instruction.partner]
        fee = calculate_expected_fee(instruction.source_amount_usd, partner)
        net_source = quantize_usd(instruction.source_amount_usd - fee)
        quote = quoted_fx_rate(market.at(instruction.booking_timestamp_utc))
        committed_destination = quantize_cny(net_source * quote)
        expected_fx_execution_source = ceil_usd(committed_destination / quote)
        expected_settlement_date = expected_settlement_date_for_booking(
            instruction.booking_timestamp_utc,
            partner,
            calendar,
        )
        booked_payments.append(
            BookedPayment(
                instruction=instruction,
                quoted_fx_rate=quote,
                expected_partner_fee_usd=fee,
                expected_net_source_amount_usd=net_source,
                expected_fx_execution_source_amount_usd=(
                    expected_fx_execution_source
                ),
                committed_destination_amount_cny=committed_destination,
                expected_settlement_date=expected_settlement_date,
            )
        )
    return booked_payments


def build_ledger_rows(booked_payments: Iterable[BookedPayment]) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for booked in booked_payments:
        instruction = booked.instruction
        booking_local = instruction.booking_timestamp_utc.astimezone(NEW_YORK)

        rows.append(
            {
                "payment_id": instruction.payment_id,
                "partner_instruction_id": instruction.partner_instruction_id,
                "customer_id": instruction.customer_id,
                "entity": ENTITY,
                "partner": instruction.partner,
                "payment_method": instruction.payment_method,
                "booking_timestamp_utc": format_timestamp(instruction.booking_timestamp_utc),
                "booking_date": booking_local.date().isoformat(),
                "source_currency": SOURCE_CURRENCY,
                "source_amount_usd": format_money(instruction.source_amount_usd),
                "destination_currency": DESTINATION_CURRENCY,
                "quoted_fx_rate": format_fx(booked.quoted_fx_rate),
                "expected_partner_fee_usd": format_money(
                    booked.expected_partner_fee_usd
                ),
                "expected_net_source_amount_usd": format_money(
                    booked.expected_net_source_amount_usd
                ),
                "expected_fx_execution_source_amount_usd": format_money(
                    booked.expected_fx_execution_source_amount_usd
                ),
                "quoted_destination_amount_cny": format_money(
                    booked.committed_destination_amount_cny
                ),
                "expected_settlement_date": booked.expected_settlement_date.isoformat(),
                "ledger_status": "BOOKED",
            }
        )
    return rows


def build_bank_rows(
    booked_payments: Iterable[BookedPayment],
    market: MarketRatePath,
    calendar: SettlementCalendar,
    processing_rngs: dict[str, random.Random],
    as_of_date: date,
) -> list[dict[str, str]]:
    settled: list[tuple[date, datetime, PaymentInstruction, dict[str, str]]] = []

    for booked in booked_payments:
        instruction = booked.instruction
        partner = PARTNERS[instruction.partner]
        service_minutes = sample_partner_service_minutes(
            partner,
            processing_rngs[instruction.partner],
        )
        execution_timestamp = realized_execution_timestamp_for(
            instruction.booking_timestamp_utc,
            partner,
            calendar,
            service_minutes,
        )
        execution_date = execution_timestamp.astimezone(NEW_YORK).date()
        value_date = calendar.add_business_days(
            execution_date,
            partner.settlement_lag_business_days,
        )
        if value_date > as_of_date:
            continue

        fee = calculate_actual_partner_fee(instruction.source_amount_usd, partner)
        execution_rate = executed_fx_rate(market.at(execution_timestamp), partner)
        settlement_amount = booked.committed_destination_amount_cny
        fx_execution_source = ceil_usd(settlement_amount / execution_rate)

        row = {
            "bank_txn_id": "",
            "partner_instruction_id": instruction.partner_instruction_id,
            "bank_reference": "",
            "partner": instruction.partner,
            "payment_method": instruction.payment_method,
            "execution_timestamp_utc": format_timestamp(execution_timestamp),
            "execution_date": execution_date.isoformat(),
            "value_date": value_date.isoformat(),
            "source_currency": SOURCE_CURRENCY,
            "fee_amount_usd": format_money(fee),
            "fx_execution_source_amount_usd": format_money(fx_execution_source),
            "executed_fx_rate": format_fx(execution_rate),
            "settlement_currency": DESTINATION_CURRENCY,
            "settlement_amount_cny": format_money(settlement_amount),
            "external_status": "SETTLED",
        }
        settled.append((value_date, execution_timestamp, instruction, row))

    rows: list[dict[str, str]] = []
    settlement_order = sorted(
        settled,
        key=lambda item: (item[0], item[1], item[2].partner_instruction_id),
    )
    for bank_sequence, (_, _, instruction, row) in enumerate(settlement_order, start=1):
        prefix = PARTNERS[instruction.partner].instruction_prefix
        row["bank_txn_id"] = f"{prefix}-BNK-{bank_sequence:06d}"
        row["bank_reference"] = f"{prefix}-{bank_sequence:08d}"
        rows.append(row)
    return rows


def validate_outputs(
    config: SimulationConfig,
    booked_payments: list[BookedPayment],
    ledger_rows: list[dict[str, str]],
    bank_rows: list[dict[str, str]],
    balance_rows: list[dict[str, str]],
    calendar: SettlementCalendar,
) -> None:
    """Check simulator invariants without performing reconciliation."""

    assert len(ledger_rows) == len(booked_payments)
    assert len(ledger_rows) <= config.payment_count
    assert len({row["payment_id"] for row in ledger_rows}) == len(ledger_rows)
    assert len({row["partner_instruction_id"] for row in ledger_rows}) == len(ledger_rows)
    assert len({row["bank_txn_id"] for row in bank_rows}) == len(bank_rows)
    assert set(LEDGER_FIELDS).isdisjoint(FORBIDDEN_ANSWER_KEY_FIELDS)
    assert set(BANK_FIELDS).isdisjoint(FORBIDDEN_ANSWER_KEY_FIELDS)
    assert set(CUSTOMER_BALANCE_FIELDS).isdisjoint(FORBIDDEN_ANSWER_KEY_FIELDS)

    booked_by_instruction = {
        booked.instruction.partner_instruction_id: booked for booked in booked_payments
    }
    ledger_debits: dict[tuple[str, str], Decimal] = {}

    for row in ledger_rows:
        source = Decimal(row["source_amount_usd"])
        fee = Decimal(row["expected_partner_fee_usd"])
        net = Decimal(row["expected_net_source_amount_usd"])
        expected_fx_source = Decimal(
            row["expected_fx_execution_source_amount_usd"]
        )
        quote = Decimal(row["quoted_fx_rate"])
        destination = Decimal(row["quoted_destination_amount_cny"])
        assert row["ledger_status"] == "BOOKED"
        assert row["source_currency"] == SOURCE_CURRENCY
        assert row["destination_currency"] == DESTINATION_CURRENCY
        assert calendar.is_business_day(date.fromisoformat(row["booking_date"]))
        assert net == quantize_usd(source - fee)
        assert destination == quantize_cny(net * quote)
        assert expected_fx_source == ceil_usd(destination / quote)
        assert expected_fx_source * quote >= destination
        debit_key = (row["booking_date"], row["customer_id"])
        ledger_debits[debit_key] = ledger_debits.get(debit_key, ZERO) + source

    for row in bank_rows:
        fee = Decimal(row["fee_amount_usd"])
        fx_execution_source = Decimal(row["fx_execution_source_amount_usd"])
        rate = Decimal(row["executed_fx_rate"])
        settlement = Decimal(row["settlement_amount_cny"])
        execution_date = date.fromisoformat(row["execution_date"])
        value_date = date.fromisoformat(row["value_date"])
        partner = PARTNERS[row["partner"]]
        booked = booked_by_instruction[row["partner_instruction_id"]]
        assert row["external_status"] == "SETTLED"
        assert calendar.is_business_day(execution_date)
        assert calendar.is_business_day(value_date)
        assert value_date == calendar.add_business_days(
            execution_date, partner.settlement_lag_business_days
        )
        assert value_date <= config.as_of_date
        assert fee == calculate_actual_partner_fee(
            booked.instruction.source_amount_usd,
            partner,
        )
        assert settlement == booked.committed_destination_amount_cny
        assert fx_execution_source == ceil_usd(settlement / rate)
        assert fx_execution_source * rate >= settlement

    expected_balance_rows = config.customer_count * (
        (config.end_date - config.start_date).days + 1
    )
    assert len(balance_rows) == expected_balance_rows
    for row in balance_rows:
        opening = Decimal(row["opening_balance"])
        funding = Decimal(row["funding_inflows"])
        debits = Decimal(row["accepted_payment_debits"])
        closing = Decimal(row["customer_balance"])
        assert closing == quantize_usd(opening + funding - debits)
        assert closing >= ZERO
        assert debits == ledger_debits.get(
            (row["balance_date"], row["customer_id"]), ZERO
        )


def write_csv(path: Path, fieldnames: tuple[str, ...], rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as file_handle:
        writer = csv.DictWriter(file_handle, fieldnames=fieldnames, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def generate(config: SimulationConfig) -> tuple[int, int, int]:
    calendar = SettlementCalendar(
        us_bank_holidays=config.us_bank_holidays,
        china_bank_holidays=config.china_bank_holidays,
    )
    market = build_market_path(config, calendar)
    instructions, balance_rows = generate_customer_activity(config, calendar)
    booked_payments = book_internal_payments(instructions, market, calendar)
    ledger_rows = build_ledger_rows(booked_payments)
    processing_rngs = {
        partner_name: named_rng(config.seed, f"partner_processing:{partner_name}")
        for partner_name in PARTNERS
    }
    bank_rows = build_bank_rows(
        booked_payments,
        market,
        calendar,
        processing_rngs,
        config.as_of_date,
    )
    validate_outputs(
        config,
        booked_payments,
        ledger_rows,
        bank_rows,
        balance_rows,
        calendar,
    )

    write_csv(config.output_dir / "ledger.csv", LEDGER_FIELDS, ledger_rows)
    write_csv(config.output_dir / "bank_transactions.csv", BANK_FIELDS, bank_rows)
    write_csv(
        config.output_dir / "customer_balances.csv",
        CUSTOMER_BALANCE_FIELDS,
        balance_rows,
    )
    return len(ledger_rows), len(bank_rows), len(balance_rows)


def parse_date(value: str) -> date:
    try:
        return date.fromisoformat(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("Expected an ISO date in YYYY-MM-DD format") from exc


def parse_args() -> argparse.Namespace:
    project_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=20250301)
    parser.add_argument("--payments", type=int, default=500)
    parser.add_argument("--customers", type=int, default=25)
    parser.add_argument("--start-date", type=parse_date, default=date(2025, 1, 1))
    parser.add_argument("--end-date", type=parse_date, default=date(2025, 3, 31))
    parser.add_argument("--as-of-date", type=parse_date, default=date(2025, 3, 31))
    parser.add_argument("--output-dir", type=Path, default=project_root / "data")
    parser.add_argument(
        "--us-holiday",
        type=parse_date,
        action="append",
        default=[],
        help="Additional US bank holiday; may be supplied more than once",
    )
    parser.add_argument(
        "--china-holiday",
        type=parse_date,
        action="append",
        default=[],
        help="Additional China bank holiday; may be supplied more than once",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.payments <= 0 or args.customers <= 0:
        raise SystemExit("--payments and --customers must be positive")
    if args.start_date > args.end_date:
        raise SystemExit("--start-date must be on or before --end-date")
    if args.end_date > args.as_of_date:
        raise SystemExit("--end-date must be on or before --as-of-date")

    config = SimulationConfig(
        seed=args.seed,
        payment_count=args.payments,
        customer_count=args.customers,
        start_date=args.start_date,
        end_date=args.end_date,
        as_of_date=args.as_of_date,
        output_dir=args.output_dir,
        us_bank_holidays=DEFAULT_US_BANK_HOLIDAYS.union(args.us_holiday),
        china_bank_holidays=DEFAULT_CHINA_BANK_HOLIDAYS.union(args.china_holiday),
    )
    ledger_count, bank_count, balance_count = generate(config)
    pending_count = ledger_count - bank_count
    rejected_count = config.payment_count - ledger_count
    print(
        f"Wrote {ledger_count} accepted ledger rows to "
        f"{config.output_dir / 'ledger.csv'}"
    )
    print(f"Rejected {rejected_count} requested payments for insufficient funds")
    print(f"Wrote {bank_count} settled bank rows to {config.output_dir / 'bank_transactions.csv'}")
    print(f"Wrote {balance_count} customer balance rows to {config.output_dir / 'customer_balances.csv'}")
    print(f"As of {config.as_of_date}: {pending_count} booked payments have no settled bank row yet")


if __name__ == "__main__":
    main()
