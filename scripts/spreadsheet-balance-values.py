#!/usr/bin/env python3
"""Corrected account balances from the source spreadsheet, for CorrectSpreadsheetBalances
(spec docs/superpowers/specs/2026-10-15-spreadsheet-balance-correction-design.md).

Usage: python3 -I scripts/spreadsheet-balance-values.py "<path>/Budget copy.numbers" > values.json
Needs numbers_parser (pip install numbers-parser). Reads the file only.

What it emits (JSON on stdout; evidence and warnings on stderr):
- snapshots: one per account per month column M up to the column before the "Date updated"
  month (that column is a partial reading plus forecasts), dated the 1st of M+1 — column M is
  the balance at the END of M. Lloyds Classic adds that column's Income + Bonus + Other income
  (its formula is balance(M) = balance(M-1) + income(M-1) - outgoings(M), so the salary
  received late in M is only counted in M+1). Lloyds International Account (EUR) comes from the
  EUR row ("Balance EUR International"), not the GBP-converted row.
- deleteTransactions: the partial month's spreadsheet Income (a duplicate of the real salary
  later that month) and the bank rows proven to be inside the partial month's figures.
- unproven: bank rows that could not be proven to be included (never deleted).
"""
import datetime
import json
import re
import sys

from numbers_parser import Document

# Row indices (0-based) in Budget › Table 1, checked against their labels below.
ROWS = {
    "Lloyds Classic": 77,
    "Lloyds International Premier GBP": 78,
    "Lloyds Club Joint": 79,
    "Lloyds Advantage ISA Saver": 80,
    "Lloyds International Account (EUR)": 81,
    "Lloyds Investment ISA": 82,
}
EUR_ROW = (62, "Balance EUR International")
INCOME_ROWS = [(65, "Income"), (66, "Bonus"), (68, "Other income/refunds:")]
NOW_ROW = (11, "NOW")
GROCERIES_ROW = (42, "Groceries")
LABEL_COL = 2
HEADER_ROW = 2

CANDIDATE_BANK_ROWS = [
    # (description, amount in pence, the spreadsheet row and term that should hold it)
    ("SAINSBURYS S/MKTS", -4564),
    ("MARKS&SPENCER PLC", -3360),
    ("NOW AF2B5 Sky Cine", -399),
]


def fail(message):
    sys.stderr.write("ERROR: " + message + "\n")
    sys.exit(1)


def pence(value):
    if value is None:
        return 0
    if not isinstance(value, (int, float)):
        fail(f"not a number: {value!r}")
    return int(round(value * 100))


def terms(formula):
    """The numeric terms of a formula like '46.85+3+4.3+33.6+45.64', in pence."""
    if not formula:
        return []
    return [int(round(float(x) * 100)) for x in re.findall(r"(?<![A-Z0-9.])\d+(?:\.\d+)?", formula)]


def main():
    if len(sys.argv) != 2:
        fail("usage: spreadsheet-balance-values.py <Budget copy.numbers>")
    path = sys.argv[1]
    doc = Document(path)
    sheet = next(s for s in doc.sheets if s.name == "Budget")
    table = next(t for t in sheet.tables if t.name == "Table 1")
    info = next(t for t in sheet.tables if t.name == "Table 2")

    def label(row):
        return table.cell(row, LABEL_COL).value

    for name, row in ROWS.items():
        if label(row) != name:
            fail(f"row {row} is {label(row)!r}, expected {name!r}")
    for row, expected in [EUR_ROW, NOW_ROW, GROCERIES_ROW] + INCOME_ROWS:
        if label(row) != expected:
            fail(f"row {row} is {label(row)!r}, expected {expected!r}")

    info_rows = {info.cell(r, 0).value: (info.cell(r, 1).value, info.cell(r, 2).value) for r in range(info.num_rows)}
    updated = info_rows.get("Date updated", (None, None))[1]
    if not isinstance(updated, datetime.datetime):
        fail("no 'Date updated' in Table 2")
    last_imported = info_rows.get("Last Imported", (None, None))

    columns = {}
    for c in range(table.num_cols):
        header = table.cell(HEADER_ROW, c).value
        if isinstance(header, datetime.datetime):
            if header.day != 1:
                fail(f"column {c} header {header} is not the 1st of a month")
            columns[(header.year, header.month)] = c
    partial = (updated.year, updated.month)
    if partial not in columns:
        fail(f"no column for the 'Date updated' month {partial}")
    partial_col = columns[partial]

    snapshots = []
    for (year, month), c in sorted(columns.items()):
        if (year, month) >= partial:
            continue  # the partial month (a reading plus forecasts) and the forecast months after it
        next_year, next_month = (year + 1, 1) if month == 12 else (year, month + 1)
        date = f"{next_year:04d}-{next_month:02d}-01"
        column = f"{year:04d}-{month:02d}"
        for name, row in ROWS.items():
            if name == "Lloyds International Account (EUR)":
                raw = table.cell(EUR_ROW[0], c).value
                if raw is None:
                    continue
                value, currency, source = pence(raw), "eur", f"row {EUR_ROW[0]} ({EUR_ROW[1]}, EUR)"
            else:
                raw = table.cell(row, c).value
                if raw is None:
                    continue
                value, currency, source = pence(raw), "gbp", f"row {row}"
                if name == "Lloyds Classic":
                    extra = sum(pence(table.cell(r, c).value) for r, _ in INCOME_ROWS)
                    value += extra
                    source += " + Income + Bonus + Other income"
            snapshots.append({"account": name, "column": column, "date": date, "valueMinorUnits": value,
                              "currency": currency, "source": source})

    # The partial month's figures.
    evidence_base = f"'Date updated' {updated:%Y-%m-%d}; 'Last Imported' {last_imported[0]!r} {last_imported[1]!r}"
    delete = []
    income = pence(table.cell(INCOME_ROWS[0][0], partial_col).value)
    if income > 0 and updated.day < 25:
        delete.append({
            "account": "Lloyds Classic", "date": f"{updated.year:04d}-{updated.month:02d}-14", "description": "Income",
            "amountMinorUnits": income, "sourceFileName": "Budget copy.numbers",
            "evidence": f"{partial[0]}-{partial[1]:02d} column Income {income / 100:.2f} is a forecast: {evidence_base}, before the ~25th payday",
        })

    groceries = table.cell(GROCERIES_ROW[0], partial_col)
    grocery_terms = terms(groceries.formula)
    now_cell = table.cell(NOW_ROW[0], partial_col)
    now_value = pence(now_cell.value)
    previous_col = columns[(partial[0] - 1, 12) if partial[1] == 1 else (partial[0], partial[1] - 1)]
    now_previous_terms = terms(table.cell(NOW_ROW[0], previous_col).formula)
    updated_day = f"{updated:%Y-%m-%d}"

    unproven = []
    for description, amount in CANDIDATE_BANK_ROWS:
        proof = None
        if description.startswith("SAINSBURYS") or description.startswith("MARKS&SPENCER"):
            if -amount in grocery_terms:
                proof = f"Groceries {partial[0]}-{partial[1]:02d} formula '{groceries.formula}' has the term {-amount / 100:.2f}"
                if description.startswith("SAINSBURYS") and last_imported[0] == "Sainsbury" and pence(last_imported[1]) == -amount:
                    proof += f"; Table 2 'Last Imported' = Sainsbury {last_imported[1]}"
        elif description.startswith("NOW"):
            # NOW holds two subscriptions (3.99 Sky Cinema + 4.99 Entertainment, '3.99+4.99' the
            # month before); the partial month holds exactly the 3.99 one, charged monthly (~16th).
            if now_value == -amount and -amount in now_previous_terms and now_cell.formula is None:
                proof = (f"NOW {partial[0]}-{partial[1]:02d} cell = {now_value / 100:.2f} (a constant) while the previous month was "
                         f"'{table.cell(NOW_ROW[0], previous_col).formula}': the monthly {-amount / 100:.2f} subscription is in, the other one isn't")
        if proof:
            delete.append({"account": "Lloyds Classic", "date": updated_day, "description": description,
                           "amountMinorUnits": amount, "sourceFileName": None, "evidence": proof + f" ({evidence_base})"})
        else:
            unproven.append({"account": "Lloyds Classic", "date": updated_day, "description": description, "amountMinorUnits": amount})

    out = {
        "source": path,
        "dateUpdated": updated_day,
        "partialColumn": f"{partial[0]}-{partial[1]:02d}",
        "snapshots": snapshots,
        "deleteTransactions": delete,
        "unproven": unproven,
    }
    json.dump(out, sys.stdout, indent=1)
    sys.stdout.write("\n")
    sys.stderr.write(f"{len(snapshots)} snapshots (columns before {out['partialColumn']}).\n")
    for d in delete:
        sys.stderr.write(f"DELETE {d['date']} {d['description']} {d['amountMinorUnits'] / 100:.2f}: {d['evidence']}\n")
    for u in unproven:
        sys.stderr.write(f"UNPROVEN (kept) {u['date']} {u['description']} {u['amountMinorUnits'] / 100:.2f}\n")


if __name__ == "__main__":
    main()
