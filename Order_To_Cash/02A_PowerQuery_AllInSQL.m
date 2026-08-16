/*  ==========================================================================
    ORDER-TO-CASH SEMANTIC MODEL  —  OPTION A: POWER QUERY
    ==========================================================================
    Pairs with 06A_SQL_AllObjects.sql. Option B is 02B_PowerQuery_ThreeQueries.m.
    See 00_README_Which_Option.md for the trade-off.

    In this option the database returns every table already shaped, so Power
    Query does almost nothing. There are 15 queries: 4 parameters, 11 native
    SQL loads, plus dim_Date which has no source and must be generated.

    WHAT IS LEFT FOR POWER QUERY
      · dim_Date, generated
      · type coercion — SQL returns 1/0, Power BI slicers read better on
        booleans
      · dim_Currency and dim_ExchangeRate IF those two spreadsheets have not
        been loaded into the warehouse (queries 14 and 15 below)
      · the tier-3 FX merge IF d_exchange_rate is not queryable (query 16)

    If all sources are in the warehouse, queries 14-16 are unnecessary and
    the model is eleven SQL loads plus a calendar.

    ALL FIVE CORRECTIONS HAPPEN IN SQL in this option. See 06A.
    ========================================================================== */


/*  ==========================================================================
    1 · p_Server                   PARAMETER (Text)
    ========================================================================== */
"your-sql-server.database.windows.net"


/*  ==========================================================================
    2 · p_Database                 PARAMETER (Text)
    ========================================================================== */
"your_database"


/*  ==========================================================================
    3 · p_SourceFolder             PARAMETER (Text)
    --------------------------------------------------------------------------
    Only needed if d_currency.xlsx and d_exchange_rate.xlsx are still files.
    ========================================================================== */
"C:\Data\OrderToCash"


/*  ==========================================================================
    4 · p_LastQuotedRateDate       PARAMETER (Date)
    --------------------------------------------------------------------------
    The last real quote in d_exchange_rate. Anything converted after this uses
    the last known rate carried forward, not a quoted one. Refresh whenever
    d_exchange_rate is refreshed — a stale value makes the forward flag
    optimistic, which is the dangerous direction.
    ========================================================================== */
#date(2026, 8, 31)


/*  ==========================================================================
    5-13 · THE NINE SQL LOADS
    --------------------------------------------------------------------------
    One query each, same pattern. Paste the matching statement from
    06A_SQL_AllObjects.sql into the Query field and name the query after the
    object it returns.

      5   dim_SalesOrderLine     <- QUERY 1
      6   fact_SalesOrder        <- QUERY 2
      7   fact_Invoice           <- QUERY 3
      8   fact_Shipment          <- QUERY 4
      9   dim_Customer           <- QUERY 5
      10  dim_Product            <- QUERY 6
      11  dim_Organization       <- QUERY 7
      12  dim_ReturnReason       <- QUERY 8
      13  dim_Carrier            <- QUERY 9

    Template — substitute the object name and the statement:
    ========================================================================== */
let
    Source = Sql.Database(p_Server, p_Database, [
        Query = "-- paste the matching QUERY from 06A_SQL_AllObjects.sql here",
        CreateNavigationProperties = false
    ]),

    // SQL returns flags as 1/0. Booleans slice better and take less memory.
    // Apply only the columns that exist on the object being loaded:
    //   dim_SalesOrderLine  Is_Return, Is_Open, Is_Cancelled, Is_Booked, Is_Fulfilled
    //   fact_SalesOrder     FX_Rate_Is_Forward
    //   fact_Invoice        Is_Credit_Memo, Has_Price_Bridge
    //   fact_Shipment       Is_Export
    //   dim_Currency        Is_USD, Is_Identity_Rate
    //   dim_ReturnReason    Is_Physical_Return
    ToBool = Table.TransformColumnTypes(Source, {
        {"Is_Return", type logical}
    })
in
    ToBool


/*  ==========================================================================
    14 · dim_Date                  generated — no source table exists
    --------------------------------------------------------------------------
    Mark as the date table in Power BI. Anchored to Ordered_Date; invoice and
    delivery dates are wired as INACTIVE relationships and activated inside
    measures with USERELATIONSHIP.

    Is_Complete_Month exists because the extract ends mid-August — without it
    every trend chart shows a false collapse in the final month.
    ========================================================================== */
let
    StartDate = #date(2025, 1, 1),
    EndDate   = #date(2027, 12, 31),
    LastFullMonthEnd = Date.EndOfMonth(Date.AddMonths(DateTime.Date(DateTime.LocalNow()), -1)),

    Days    = List.Dates(StartDate, Duration.Days(EndDate - StartDate) + 1, #duration(1,0,0,0)),
    ToTable = Table.FromList(Days, Splitter.SplitByNothing(), {"Date"}),
    Typed   = Table.TransformColumnTypes(ToTable, {{"Date", type date}}),

    Cols =
      Table.AddColumn(
      Table.AddColumn(
      Table.AddColumn(
      Table.AddColumn(
      Table.AddColumn(
      Table.AddColumn(
      Table.AddColumn(
      Table.AddColumn(Typed,
        "Year",              each Date.Year([Date]),                            Int64.Type),
        "Month_Number",      each Date.Month([Date]),                           Int64.Type),
        "Month_Short",       each Date.ToText([Date], "MMM"),                   type text),
        "Year_Month",        each Date.ToText([Date], "MMM yyyy"),              type text),
        "Year_Month_Sort",   each Date.Year([Date]) * 100 + Date.Month([Date]), Int64.Type),
        "Quarter",           each "Q" & Text.From(Date.QuarterOfYear([Date])),  type text),
        "Year_Quarter",      each Text.From(Date.Year([Date])) & " Q"
                                  & Text.From(Date.QuarterOfYear([Date])),      type text),
        "Is_Complete_Month", each Date.EndOfMonth([Date]) <= LastFullMonthEnd,  type logical),

    Final = Table.TransformColumnTypes(Cols, {{"Date", type datetime}})
in
    Final


/*  ==========================================================================
    15 · dim_Currency              FALLBACK — only if d_currency is still a file
    --------------------------------------------------------------------------
    If QUERY 10 in the SQL file works, delete this.

    THE GRAIN IS Currency_Code x Region, NOT Currency_Code. 1,000 rows, 308
    codes, 4 regions, 230 codes in all four. The description even varies by
    region — USD reads "US dollar" in NAM and "US Dollar" in EUR. A code-only
    join fans out up to four ways and multiplies every amount it touches.
    ========================================================================== */
let
    Source = Excel.Workbook(
        File.Contents(p_SourceFolder & "\d_currency.xlsx"), null, true),
    Sheet  = Source{[Item = "Sheet1", Kind = "Sheet"]}[Data],
    Promoted = Table.PromoteHeaders(Sheet, [PromoteAllScalars = true]),
    Typed = Table.TransformColumnTypes(Promoted, {
        {"Currency_PK_Key", Int64.Type}, {"Currency_Code", type text},
        {"Currency_Desc",   type text},  {"Region",        type text}}),
    AddKey = Table.AddColumn(Typed, "CurrencyKey", each
        [Currency_Code] & "|" & [Region], type text),
    AddIsUSD = Table.AddColumn(AddKey, "Is_USD", each
        [Currency_Code] = "USD", type logical),
    AddIdentity = Table.AddColumn(AddIsUSD, "Is_Identity_Rate", each
        List.Contains({"USD", "USC"}, [Currency_Code]), type logical),
    Deduped = Table.Distinct(AddIdentity, {"CurrencyKey"}),
    WithUnknown = Table.InsertRows(Deduped, 0, {[
        Currency_PK_Key = -1, Currency_Code = "UNK", Currency_Desc = "Unknown",
        Region = "Unknown", CurrencyKey = "UNK|Unknown",
        Is_USD = false, Is_Identity_Rate = false]})
in
    WithUnknown


/*  ==========================================================================
    16 · dim_ExchangeRate          FALLBACK — only if d_exchange_rate is a file
    --------------------------------------------------------------------------
    If QUERY 11 in the SQL file works, delete this.

    If you need this, you ALSO need to strip the OUTER APPLY out of QUERY 2
    and do the tier-3 merge here instead — see 02B_PowerQuery_ThreeQueries.m
    query 12, which carries that step in full.

    Conversion_Type = "Corporate" only: of 55 types it is the only one with
    complete daily coverage. Region belongs in the key — the rate differs
    between regions on 80.5% of overlapping pair-dates.
    ========================================================================== */
let
    Source = Excel.Workbook(
        File.Contents(p_SourceFolder & "\d_exchange_rate.xlsx"), null, true),
    Sheet  = Source{[Item = "d_exchange_rate", Kind = "Sheet"]}[Data],
    Promoted = Table.PromoteHeaders(Sheet, [PromoteAllScalars = true]),
    Typed = Table.TransformColumnTypes(Promoted, {
        {"Data_Source_Region", type text}, {"From_Currency_Code", type text},
        {"To_Currency_Code",   type text}, {"Conversion_Type",    type text},
        {"Conversion_Date", type datetime},{"Conversion_Rate",    type number},
        {"Status_Code",        type text}}),
    Corporate = Table.SelectRows(Typed, each
        [Conversion_Type]  = "Corporate" and [To_Currency_Code] = "USD"
        and [Status_Code]  = "C" and [Conversion_Rate] <> null and [Conversion_Rate] > 0),
    Keyed = Table.AddColumn(
        Table.AddColumn(Corporate, "CurrencyKey", each
            [From_Currency_Code] & "|" & [Data_Source_Region], type text),
        "Rate_Date", each DateTime.Date([Conversion_Date]), type date),
    Grouped = Table.Group(Keyed, {"CurrencyKey", "Rate_Date"}, {
        {"Rate_USD_per_Local", each List.Average([Conversion_Rate]), type number}}),
    Tagged = Table.AddColumn(Grouped, "Rate_Source", each "Corporate", type text)
in
    Tagged


/*  ==========================================================================
    RELATIONSHIPS TO CREATE  (Model view — all Single direction, no exceptions)
    ==========================================================================
    Identical in both options — the model is the same, only the build differs.

      FROM (1 side)              TO (* side)              KEY            ACTIVE
      ------------------------------------------------------------------------
      dim_SalesOrderLine   ->    fact_SalesOrder          LineKey        Yes (1:1)
      dim_SalesOrderLine   ->    fact_Invoice             LineKey        Yes
      dim_SalesOrderLine   ->    fact_Shipment            LineKey        Yes
      dim_Date             ->    dim_SalesOrderLine       Ordered_Date   Yes
      dim_Date             ->    fact_Invoice             Invoice_Date   NO
      dim_Date             ->    fact_Shipment            Delivery_Confirm_Date  NO
      dim_Customer         ->    dim_SalesOrderLine       CustomerKey    Yes
      dim_Product          ->    dim_SalesOrderLine       ProductKey     Yes
      dim_Organization     ->    dim_SalesOrderLine       OrgKey         Yes
      dim_Currency         ->    dim_SalesOrderLine       CurrencyKey    Yes
      dim_ReturnReason     ->    dim_SalesOrderLine       Return_Reason  Yes
      dim_Carrier          ->    fact_Shipment            CarrierKey     Yes

    dim_ExchangeRate relates to nothing — fact_SalesOrder resolves its own
    rate. Load it only if you want the history visible for audit.

    NEVER relate two fact tables. Turn OFF File > Options > Current File >
    Data Load > Autodetect new relationships BEFORE the first refresh.
    ========================================================================== */
