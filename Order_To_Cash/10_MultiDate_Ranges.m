/*  ==========================================================================
    DISCONNECTED PERIOD TABLES  —  for simultaneous, independent date ranges
    ==========================================================================
    dim_Date stays exactly as it is: related, marked as the date table, driving
    time intelligence. These new tables are DISCONNECTED — no relationship to
    anything — and exist only so a slicer can hand a date range to a measure.

    WHY A SECOND CALENDAR
      A related dim_Date can only filter through one relationship at a time.
      To apply the same range to Shipping Date AND Invoice Date simultaneously
      you need the range as a VALUE, not as a filter — which is what a
      disconnected table gives you. The measures in 10_DAX_MultiDate.dax
      read MIN and MAX from it and push the test into each chosen column.

    HOW MANY YOU NEED
      One shared range across several date fields   ->  dim_Period only
      A different range per date field              ->  one table per field

    Both are below. Load dim_Period always; load the two role-specific ones
    only if you want independent ranges.
    ========================================================================== */


/*  ==========================================================================
    1 · dim_Period                 the shared range picker
    --------------------------------------------------------------------------
    Put a Between slicer on dim_Period[Date]. It filters nothing by itself —
    every measure that honours it does so explicitly.

    Keep the range identical to dim_Date so the two never disagree at the edges.
    ========================================================================== */
let
    StartDate = #date(2025, 1, 1),
    EndDate   = #date(2027, 12, 31),
    Days    = List.Dates(StartDate, Duration.Days(EndDate - StartDate) + 1, #duration(1,0,0,0)),
    ToTable = Table.FromList(Days, Splitter.SplitByNothing(), {"Date"}),
    Typed   = Table.TransformColumnTypes(ToTable, {{"Date", type date}}),
    Cols =
      Table.AddColumn(
      Table.AddColumn(
      Table.AddColumn(Typed,
        "Year",            each Date.Year([Date]),                            Int64.Type),
        "Year_Month",      each Date.ToText([Date], "MMM yyyy"),              type text),
        "Year_Month_Sort", each Date.Year([Date]) * 100 + Date.Month([Date]), Int64.Type)
in
    Cols


/*  ==========================================================================
    2 · dim_Period_Ship            independent range #1  (optional)
    --------------------------------------------------------------------------
    Only needed if a user wants, say, shipping date in Jan-Mar while invoice
    date runs Feb-Apr. Same shape as dim_Period; the measures reference it by
    name, which is the only thing that makes it "the shipping one".
    ========================================================================== */
let
    StartDate = #date(2025, 1, 1),
    EndDate   = #date(2027, 12, 31),
    Days    = List.Dates(StartDate, Duration.Days(EndDate - StartDate) + 1, #duration(1,0,0,0)),
    ToTable = Table.FromList(Days, Splitter.SplitByNothing(), {"Date"}),
    Typed   = Table.TransformColumnTypes(ToTable, {{"Date", type date}}),
    Renamed = Table.RenameColumns(Typed, {{"Date", "Ship_Date"}})
in
    Renamed


/*  ==========================================================================
    3 · dim_Period_Invoice         independent range #2  (optional)
    ========================================================================== */
let
    StartDate = #date(2025, 1, 1),
    EndDate   = #date(2027, 12, 31),
    Days    = List.Dates(StartDate, Duration.Days(EndDate - StartDate) + 1, #duration(1,0,0,0)),
    ToTable = Table.FromList(Days, Splitter.SplitByNothing(), {"Date"}),
    Typed   = Table.TransformColumnTypes(ToTable, {{"Date", type date}}),
    Renamed = Table.RenameColumns(Typed, {{"Date", "Invoice_Date_Range"}})
in
    Renamed


/*  ==========================================================================
    4 · dim_DateCombine            AND / OR selector
    --------------------------------------------------------------------------
    When more than one date basis is selected, this decides how they combine.
    It matters more than it sounds. Measured on Q1 2026:

        Invoice date in Q1 only                   $5,674.1m
        Shipping date in Q1 only                  $5,445.3m
        BOTH  shipped AND invoiced in Q1          $5,421.1m
        EITHER shipped OR invoiced in Q1          $5,698.4m

    AND is 95.5% of the invoice-date figure. The $253m difference is revenue
    billed in Q1 for goods that left the plant in a different quarter — a real
    question, and one finance and supply chain will answer differently.
    Default to AND: it is the stricter reading and matches "displays Shipping
    Date and Invoice Date between X and Y".
    ========================================================================== */
let
    Rows = #table(
        type table [Combine_Key = text, Combine_Label = text, Sort_Order = Int64.Type],
        {
            {"AND", "All selected dates in range",      1},
            {"OR",  "Any selected date in range",       2}
        })
in
    Rows
