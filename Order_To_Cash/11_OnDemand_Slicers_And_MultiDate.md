# Slicers on demand, and simultaneous date ranges

Two separate asks. The second one has a subtlety worth reading before you build it.

---

## Part 1 — Slicers on demand

Three patterns, each solving a different problem. They combine.

### A. Slide-out filter panel (bookmarks)

For "I don't want fourteen slicers cluttering the page."

1. Put every slicer in a rectangle, then group them in the Selection pane as
   `FilterPanel`.
2. Selection pane → hide `FilterPanel`. Bookmarks → Add → name it
   **Filters Hidden**. Untick *Data* so the bookmark only stores visibility, not
   the current selections — otherwise opening the panel resets what the user
   picked.
3. Unhide `FilterPanel`, add a second bookmark **Filters Shown**, same setting.
4. Add two buttons (a funnel icon and an X), each with Action → Bookmark.

**The one thing people get wrong:** leaving *Data* ticked on the bookmark. The
panel then silently reverts every slicer each time it is opened.

### B. Field parameters — let users choose what to slice by

For "different teams want to break the same measure by different things."

Modeling → New parameter → Fields. Add: `dim_Customer[Customer_Name]`,
`dim_Product[Product_Description]`, `dim_Organization[Operating_Unit]`,
`dim_SalesOrderLine[Region]`, `dim_SalesOrderLine[Incoterm]`,
`dim_Carrier[Carrier_Name]`, `dim_SalesOrderLine[Transport_Mode]`.

Drop the parameter on a slicer, and put it on the axis of a bar chart. One
visual then answers "revenue by X" for any X the user picks — instead of seven
near-identical visuals.

### C. Bookmark per audience

For "supply chain and finance want different default views."

Set the date basis, slicers and visible visuals for one team, capture a
bookmark, repeat. Then a small navigation strip: **Supply chain · Finance ·
Transportation**. Each lands on the right lens with the right filters, and users
can still change anything afterwards.

---

## Part 2 — Simultaneous date ranges

### Why the existing pattern cannot do it

`USERELATIONSHIP` activates **one** relationship at a time. It answers "revenue
by invoice date" or "revenue by shipping date" — never both at once. To ask
"shipped in Q1 **and** invoiced in Q1" the range has to arrive as a *value*
rather than as a filter. That is what a **disconnected** date table gives you.

### What to build

| Object | Type | Purpose |
|---|---|---|
| `dim_Period` | disconnected | Between slicer supplies the range |
| `dim_DateBasis` | disconnected | which date fields — set slicer to **multi-select** |
| `dim_DateCombine` | disconnected | AND or OR |

All three are in `10_MultiDate_Ranges.m`. The measures are in
`10_DAX_MultiDate.dax`.

### The caption you asked for

```dax
Report Period Caption =
    VAR MinD   = [Period Start]
    VAR MaxD   = [Period End]
    VAR Bases  = VALUES( dim_DateBasis[Basis_Label] )
    VAR Joiner = IF( [Combine Mode] = "OR", " or ", " and " )
    VAR Labels = CONCATENATEX( Bases, dim_DateBasis[Basis_Label], Joiner,
                               dim_DateBasis[Basis_Label], ASC )
    RETURN
        "This report displays " & Labels
            & " between " & FORMAT( MinD, "d/M/yyyy" )
            & " and "     & FORMAT( MaxD, "d/M/yyyy" )
```

Selecting Shipping Date + Invoice Date with a Jan–Mar range renders:

> This report displays Actual shipment date and Invoice date between 1/1/2026 and 31/3/2026

Put it in a Card at the top of the page. It is the cheapest defence against
someone screenshotting a number without its filter context.

### AND versus OR is a real decision

Measured on Q1 2026 with both dates selected:

| Filter | Net revenue |
|---|---|
| Invoice date in Q1 only | $5,674.1m |
| Shipping date in Q1 only | $5,445.3m |
| **AND** — shipped *and* invoiced in Q1 | **$5,421.1m** |
| **OR** — shipped *or* invoiced in Q1 | **$5,698.4m** |

The **$253.0m** gap between the invoice figure and AND is revenue billed in Q1
for goods that left the plant in a different quarter. Only $24.2m goes the other
way. Finance and supply chain will each argue their number is the right one —
which is exactly why the caption should say which was used.

Default to **AND**. It is the stricter reading and it matches the sentence
"displays Shipping Date **and** Invoice Date between X and Y".

### Independent ranges per field

If someone wants shipping date in Jan–Mar while invoice date runs Feb–Apr, give
each field its own disconnected table and its own slicer — `dim_Period_Ship` and
`dim_Period_Invoice` are both in `10_MultiDate_Ranges.m`, with a worked measure
in section 5 of the DAX file. The pattern is identical; only where `MIN` and
`MAX` come from changes.

---

## What to watch

**Mixed scopes.** Selecting Invoice date together with Drop-off actual mixes
"Invoice only" with "Shipment only". Each measure is filtered only by the bases
that reach its own table, so revenue responds to the invoice date and ignores
the drop-off date. That is correct, and it is confusing without a warning —
`Multi Basis Warning` puts it on screen.

**Performance.** The row-set measures scan whole tables with `FILTER`. At
69k bridge rows, 80k invoice rows and 85k shipment rows that is comfortable. If
you later add years of history, replace `FILTER( ALL( t ), ... )` with
`CALCULATETABLE( t, ... )` on the columns being tested, which lets the engine
use the column store rather than a row scan.

**Reconciliation.** `Period Reconciliation Check` compares the multi-date
measure against the single-lens equivalent whenever exactly one basis is
selected. They must match. If they do not, a column in one of the three row-set
measures is pointing at the wrong table — that is the failure this pattern is
prone to, and it is silent without the check.

---

## In the prototype

`05_Dashboard_Prototype.html` now carries all of it, live:

- **Period range** — two month pickers; every trend re-cuts to the range
- **Basis selection** — Single or Multi-select
- **Combine** — AND / OR, which genuinely changes the numbers when Actual
  shipment date and Invoice date are both selected
- **Caption bar** — the sentence above, updating as you change anything
- **Scope note** — what the current lens can and cannot reach

Pick *Multi-select*, then *Actual shipment date* and *Invoice date*, then toggle
AND / OR with the range on Jan–Mar. January revenue moves between $1,693.9m and
$1,728.5m. That difference is the whole argument between the two teams, on
screen.
