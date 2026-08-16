# Order-to-Cash model — which build option

You cannot create or alter views, so nothing here is a database object. Every
query is a plain `SELECT` pasted into Power BI as a native query. There are two
ways to arrange that, and both are provided in full.

**The model is identical either way** — same twelve tables, same twelve
relationships, same 135 measures, same numbers. The choice is about where the
work happens and how often the database is queried.

---

## The trade-off

| | **Option A** — all objects in SQL | **Option B** — three source queries |
|---|---|---|
| SQL statements | 11, one per model table | 3, one per source system |
| Power Query does | Loads them, generates `dim_Date`, coerces flags | References each pull and fans it out into 12 objects |
| Database round trips | 11 per refresh | 3 per refresh |
| Sales order join runs | 6 times | Once |
| Logic lives | Almost entirely at source | Shaping in SQL, merges in M |
| Best when | Your team is stronger in SQL, or the warehouse is fast | The source view is large, or refresh time matters |

**If you are unsure, take Option B.** Three round trips instead of eleven is a
real difference on a large source view, and the sales order join running once
rather than six times is the bigger part of it.

**Take Option A if** your team maintains SQL more comfortably than M, or if
governance requires the transformation logic to be reviewable at source.

---

## Files

| Option A | Option B | Shared |
|---|---|---|
| `06A_SQL_AllObjects.sql` | `06B_SQL_ThreeQueries.sql` | `01_Architecture_Documentation.docx` |
| `02A_PowerQuery_AllInSQL.m` | `02B_PowerQuery_ThreeQueries.m` | `03_DAX_All.dax` |
| `01A_Build_Guide_AllInSQL.docx` | `01B_Build_Guide_ThreeQueries.docx` | `04_KPI_Catalogue.xlsx` |
| | | `05_Dashboard_Prototype.html` |
| | | `model_diagram.png` |

### Why the architecture document is not split

`01_Architecture_Documentation.docx` describes the model — the bridge design,
the currency handling, the data corrections, the measures, what the model cannot
answer. None of that changes between options, so duplicating ~5,000 words that
differ in one section would create a drift problem: someone updates section 5 in
one copy and not the other, and six months later the two disagree.

Everything option-specific lives in the two build guides, which are short and
have no overlap. Read the architecture document for *what* the model is, and the
build guide for *how* to assemble it.

---

## Before you start, either way

- **Turn off Autodetect new relationships.** File → Options → Current File →
  Data Load. Left on, Power BI wires `fact_Invoice` straight to `fact_Shipment`
  and every measure inflates.
- **Confirm whether `d_currency` and `d_exchange_rate` are queryable tables** or
  still spreadsheets. Both options handle either, but it changes which queries
  you run.
- **Apply the bracket fix to the invoice and shipment source queries.** Your v2
  sales order query has it; the other two still read
  `AND a AND b OR c`, which SQL evaluates as `(a AND b) OR c`. Both SQL files
  here have the corrected version.
- **Set `p_LastQuotedRateDate`** to the last real quote in `d_exchange_rate`.
  It drives the forward-rate flag, and a stale value makes the flag optimistic.
