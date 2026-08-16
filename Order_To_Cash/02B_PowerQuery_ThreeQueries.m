/*  ==========================================================================
    ORDER-TO-CASH SEMANTIC MODEL  —  OPTION B: POWER QUERY
    ==========================================================================
    Pairs with 06B_SQL_ThreeQueries.sql. Option A is 02A_PowerQuery_AllInSQL.m.
    See 00_README_Which_Option.md for the trade-off.

    19 queries: 4 parameters, 3 SQL staging queries, 12 model objects.

    THE SHAPE, AND WHY
      You cannot create views, so the three SQL statements in
      06B_SQL_ThreeQueries.sql are pasted straight into Power BI as native
      queries. Everything else REFERENCES those three.

        qry_SalesOrder_Source  ->  dim_SalesOrderLine, fact_SalesOrder,
                                   dim_Customer, dim_Product,
                                   dim_Organization, dim_ReturnReason
        qry_Invoice_Source     ->  fact_Invoice
        qry_Shipment_Source    ->  fact_Shipment, dim_Carrier

      Reference, not duplicate. Duplicating a query re-runs the SQL; referencing
      it reuses the result. That is the difference between 3 database round
      trips per refresh and 12.

      Set all three staging queries to Enable load = OFF. They exist to feed
      the model, not to sit in it.

    SETUP ORDER
      1. Create the four parameters (queries 1-4).
      2. Paste the three SQL statements as native queries (5-7).
      3. Build 8-10, which have no dependencies.
      4. Build 11-19 in order.

    THE FIVE CORRECTIONS
      A, B, C, D and E all happen in SQL — see 06B_SQL_ThreeQueries.sql.
      This file does the things a single SELECT cannot: the FX rate merge,
      dimension de-duplication, and the calendar.
    ========================================================================== */


/*  ==========================================================================
    1 · p_Server                   PARAMETER  (Text)
    ========================================================================== */
"your-sql-server.database.windows.net"


/*  ==========================================================================
    2 · p_Database                 PARAMETER  (Text)
    ========================================================================== */
"your_database"


/*  ==========================================================================
    3 · p_SourceFolder             PARAMETER  (Text)
    --------------------------------------------------------------------------
    Folder holding d_currency.xlsx and d_exchange_rate.xlsx. Only needed if
    those two live as spreadsheets rather than as tables you can query.
    ========================================================================== */
"C:\Data\OrderToCash"


/*  ==========================================================================
    4 · p_LastQuotedRateDate       PARAMETER  (Date)
    --------------------------------------------------------------------------
    The last real quote in d_exchange_rate. Anything converted at a date after
    this uses the last known rate carried forward, not a quoted one. Drives
    FX_Rate_Is_Forward. Refresh this whenever d_exchange_rate is refreshed —
    a stale value makes the flag optimistic, which is the dangerous direction.
    ========================================================================== */
#date(2026, 8, 31)


/*  ==========================================================================
    5 · qry_SalesOrder_Source      SQL STAGING  ·  Enable load = OFF
    --------------------------------------------------------------------------
    Paste QUERY 1 from 06B_SQL_ThreeQueries.sql into the Query field below,
    replacing the placeholder text. Keep it on one native query — six model
    objects reference this result.
    ========================================================================== */
let
    Source = Sql.Database(p_Server, p_Database, [
        Query = "-- paste QUERY 1 of 3 from 06B_SQL_ThreeQueries.sql here",
        CreateNavigationProperties = false
    ])
in
    Source


/*  ==========================================================================
    6 · qry_Invoice_Source         SQL STAGING  ·  Enable load = OFF
    ========================================================================== */
let
    Source = Sql.Database(p_Server, p_Database, [
        Query = "-- paste QUERY 2 of 3 from 06B_SQL_ThreeQueries.sql here",
        CreateNavigationProperties = false
    ])
in
    Source


/*  ==========================================================================
    7 · qry_Shipment_Source        SQL STAGING  ·  Enable load = OFF
    ========================================================================== */
let
    Source = Sql.Database(p_Server, p_Database, [
        Query = "-- paste QUERY 3 of 3 from 06B_SQL_ThreeQueries.sql here",
        CreateNavigationProperties = false
    ])
in
    Source


/*  ==========================================================================
    8 · dim_ExchangeRate           from d_exchange_rate.xlsx
    --------------------------------------------------------------------------
    112,877 source rows reduced to the daily USD conversion spine.

    THREE DECISIONS, EACH TESTED AGAINST THE DATA

    Conversion_Type = "Corporate" only. The file holds 55 types; Corporate is
    the only one with complete daily coverage — 225 of 225 days in the window
    for every currency in use, with no weekend gaps. The numeric types (1000,
    1621, 1740 ...) and the Period Average / Period End variants are partial.

    Region belongs in the key. For the same pair on the same date the rate
    DIFFERS between regions on 80.5% of overlapping rows. AUD -> BRL on
    2025-01-01 is 3.84344254 in AUS and 3.83922654 in EUR.

    USD and USC are handled as identity in fact_SalesOrder rather than
    materialised here — generating an identity spine would add ~76,000 rows
    carrying a constant of 1.0.

    If these ever become queryable tables, swap the Source step for a
    Sql.Database call. Nothing downstream changes.
    ========================================================================== */
let
    Source = Excel.Workbook(
        File.Contents(p_SourceFolder & "\d_exchange_rate.xlsx"), null, true),
    Sheet  = Source{[Item = "d_exchange_rate", Kind = "Sheet"]}[Data],
    Promoted = Table.PromoteHeaders(Sheet, [PromoteAllScalars = true]),

    Typed = Table.TransformColumnTypes(Promoted, {
        {"Data_Source_Region", type text},
        {"From_Currency_Code", type text},
        {"To_Currency_Code",   type text},
        {"Conversion_Type",    type text},
        {"Conversion_Date",    type datetime},
        {"Conversion_Rate",    type number},
        {"Status_Code",        type text}}),

    Corporate = Table.SelectRows(Typed, each
        [Conversion_Type]  = "Corporate"
        and [To_Currency_Code] = "USD"
        and [Status_Code]      = "C"
        and [Conversion_Rate] <> null
        and [Conversion_Rate]  > 0),

    Keyed = Table.AddColumn(
        Table.AddColumn(Corporate, "CurrencyKey", each
            [From_Currency_Code] & "|" & [Data_Source_Region], type text),
        "Rate_Date", each DateTime.Date([Conversion_Date]), type date),

    // A few pair-date-region combinations appear more than once. Average, so
    // a stray duplicate cannot swing the result the way picking one can.
    Grouped = Table.Group(Keyed, {"CurrencyKey", "Rate_Date"}, {
        {"Rate_USD_per_Local", each List.Average([Conversion_Rate]), type number}}),
    Tagged = Table.AddColumn(Grouped, "Rate_Source", each "Corporate", type text)
in
    Tagged


/*  ==========================================================================
    9 · dim_Currency               from d_currency.xlsx
    --------------------------------------------------------------------------
    THE GRAIN IS Currency_Code x Region, NOT Currency_Code.
    1,000 rows, 308 codes, 4 regions, and 230 codes exist in all four. The
    description even varies by region — USD reads "US dollar" in NAM and
    "US Dollar" in EUR. Joining on the code alone fans out up to four ways and
    multiplies every amount it touches.

    USC = "Dolar Compra", SAM only, 2,976 lines. The rate table resolves it
    1:1 with USD: direct USC -> USD quotes read exactly 1.000000, BRL -> USC
    tracks BRL -> USD within 0.011% across 591 dates, and the source supplies
    no Exchange_Rate for it. It is NOT US cents.
    ========================================================================== */
let
    Source = Excel.Workbook(
        File.Contents(p_SourceFolder & "\d_currency.xlsx"), null, true),
    Sheet  = Source{[Item = "Sheet1", Kind = "Sheet"]}[Data],
    Promoted = Table.PromoteHeaders(Sheet, [PromoteAllScalars = true]),

    Typed = Table.TransformColumnTypes(Promoted, {
        {"Currency_PK_Key", Int64.Type},
        {"Currency_Code",   type text},
        {"Currency_Desc",   type text},
        {"Region",          type text}}),

    AddKey = Table.AddColumn(Typed, "CurrencyKey", each
        [Currency_Code] & "|" & [Region], type text),
    AddIsUSD = Table.AddColumn(AddKey, "Is_USD", each
        [Currency_Code] = "USD", type logical),
    // Codes needing no conversion at all
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
    10 · dim_Date                  generated, no source needed
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
    11 · dim_SalesOrderLine        THE BRIDGE  ·  references query 5
    --------------------------------------------------------------------------
    One row per sales order line. Every fact filters through this; no fact ever
    joins to another fact. One order line carries up to 4 invoice lines and up
    to 115 shipment rows, so a direct fact-to-fact join fans out 4 x 115 on the
    worst key and multiplies every measure.

    Right-click qry_SalesOrder_Source > Reference. Do NOT duplicate — that
    re-runs the SQL.

    All the derivation already happened in SQL. This query only selects and
    types. Grain verified on v2: 68,977 rows, 68,977 distinct LineKey.
    ========================================================================== */
let
    Source = qry_SalesOrder_Source,

    Selected = Table.SelectColumns(Source, {
        "LineKey", "DP_Key", "ProductKey", "OrgKey", "CustomerKey", "CurrencyKey",
        "Region", "Order_Number", "Order_Status", "Order_Type_Name", "Line_Id",
        "Line_Shipment_Num", "Line_Status", "Line_Category", "Line_Type_Name",
        "Currency_Code", "Operating_Unit", "Incoterm", "Transport_Mode",
        "Sales_Rep", "CSR", "Sales_Type", "Price_List", "Customer_PO",
        "Customer_Contract", "Line_Agreement_Number",
        "Ship_To_City", "Ship_To_State", "Ship_To_Country",
        "Ordered_Date", "Creation_Date", "Schedule_Ship_Date", "Schedule_Arrival_Date",
        "Promise_Date", "Request_Date", "Actual_Shipment_Date", "Fulfillment_Date",
        "FX_Date", "FX_Date_Basis", "Exchange_Rate_Type",
        "Is_Return", "Return_Reason", "Is_Open", "Is_Cancelled", "Is_Booked", "Is_Fulfilled",
        "Days_Order_To_Ship", "Ship_Delay_Days", "Delay_Bucket", "Cycle_Bucket",
        "Last_Update"}),

    // SQL returns the flags as 1/0. Power BI slicers read better on booleans.
    ToBool = Table.TransformColumnTypes(Selected, {
        {"Is_Return",    type logical}, {"Is_Open",      type logical},
        {"Is_Cancelled", type logical}, {"Is_Booked",    type logical},
        {"Is_Fulfilled", type logical}}),

    Renamed = Table.RenameColumns(ToBool, {{"Exchange_Rate_Type", "FX_Rate_Type"}}),
    NoBlankKeys = Table.SelectRows(Renamed, each [LineKey] <> null and [LineKey] <> "")
in
    NoBlankKeys


/*  ==========================================================================
    12 · fact_SalesOrder           references query 5  ·  merges query 8
    --------------------------------------------------------------------------
    Measures only. Every descriptive column already lives on the bridge, so
    carrying it twice doubles memory for nothing.

    RATE PRECEDENCE — three tiers, in this order

      1  IDENTITY for USD and USC. USC is 1:1 with USD; the source supplies
         no Exchange_Rate for either code.                    48.0% of rows

      2  THE SOURCE'S OWN RATE. Exchange_Rate reproduces the USD price EXACTLY
         on 100% of 25,834 testable rows, and the list price on 100% of
         23,602. When the source has already done the arithmetic there is no
         reason to redo it.                                   44.3% of rows

      3  THE CORPORATE RATE TABLE for what is left, looked up at FX_Date.
                                                               7.7% of rows

    Result: 100.000% coverage. Nothing is unconvertible.

    This merge is the one thing that genuinely cannot be done in a single
    SELECT without referencing another query — which is why it lives here.
    ========================================================================== */
let
    Source = qry_SalesOrder_Source,

    // Tier 3 lookup. Left join, so rows with no matching quote stay and fall
    // through to the null handling below.
    JoinRate = Table.NestedJoin(Source, {"CurrencyKey", "FX_Date"},
        dim_ExchangeRate, {"CurrencyKey", "Rate_Date"}, "fx", JoinKind.LeftOuter),
    ExpandRate = Table.ExpandTableColumn(JoinRate, "fx",
        {"Rate_USD_per_Local"}, {"Table_FX_Rate"}),

    ApplyTiers = Table.AddColumn(ExpandRate, "FX_Rate", each
        if List.Contains({"USD", "USC"}, [Currency_Code]) then 1.0
        else if [Exchange_Rate] <> null then [Exchange_Rate]
        else [Table_FX_Rate], type nullable number),

    TagSource = Table.AddColumn(ApplyTiers, "FX_Rate_Source", each
        if List.Contains({"USD", "USC"}, [Currency_Code]) then "Identity (USD/USC)"
        else if [Exchange_Rate]  <> null then "Source Exchange_Rate"
        else if [Table_FX_Rate]  <> null then "Corporate rate table"
        else "Unresolved", type text),

    // Only a tier-3 rate can be forward. A source-supplied rate never is.
    AddForward = Table.AddColumn(TagSource, "FX_Rate_Is_Forward", each
        [FX_Rate_Source] = "Corporate rate table"
        and [FX_Date] > p_LastQuotedRateDate, type logical),

    // Source USD always wins. Only fill where the source left a gap.
    FillSelling = Table.AddColumn(AddForward, "Unit_Selling_Price_USD", each
        if [Line_Unit_Selling_Price_USD] <> null then [Line_Unit_Selling_Price_USD]
        else if [FX_Rate] <> null and [Unit_Selling_Price_Local] <> null
             then [Unit_Selling_Price_Local] * [FX_Rate]
        else null, type nullable number),

    FillList = Table.AddColumn(FillSelling, "Unit_List_Price_USD", each
        if [Line_Unit_List_Price_USD] <> null then [Line_Unit_List_Price_USD]
        else if [FX_Rate] <> null and [Unit_List_Price_Local] <> null
             then [Unit_List_Price_Local] * [FX_Rate]
        else null, type nullable number),

    // A converted number must never be indistinguishable from a source one.
    Quality = Table.AddColumn(FillList, "Price_USD_Quality", each
        if [Line_Unit_Selling_Price_USD] <> null then "1 - Source"
        else if [Unit_Selling_Price_USD] <> null then "2 - Converted"
        else "3 - Not convertible", type text),

    Selected = Table.SelectColumns(Quality, {
        "LineKey", "CurrencyKey", "Price_USD_Quality",
        "Ordered_MT_Signed", "Shipped_MT_Signed", "Invoiced_MT", "Ordered_Qty_Native",
        "Unit_List_Price_USD", "Unit_Selling_Price_USD",
        "Unit_List_Price_Local", "Unit_Selling_Price_Local",
        "FX_Rate", "FX_Rate_Source", "FX_Date", "FX_Date_Basis", "FX_Rate_Is_Forward"})
in
    Selected


/*  ==========================================================================
    13 · fact_Invoice              references query 6
    --------------------------------------------------------------------------
    Grain: one invoice line. Unique on (LineKey, Transaction_Number,
    Line_Number), so no deduplication. Duplicate LineKeys are legitimate —
    one order line can be invoiced in instalments.
    ========================================================================== */
let
    Source = qry_Invoice_Source,
    ToBool = Table.TransformColumnTypes(Source, {
        {"Is_Credit_Memo",   type logical},
        {"Has_Price_Bridge", type logical}})
in
    ToBool


/*  ==========================================================================
    14 · fact_Shipment             references query 7
    --------------------------------------------------------------------------
    Grain: one delivery detail line. The malformed-row filter and the column
    reduction both happened in SQL — 283 columns down to 40.
    ========================================================================== */
let
    Source = qry_Shipment_Source,
    ToBool = Table.TransformColumnTypes(Source, {{"Is_Export", type logical}}),
    Selected = Table.SelectColumns(ToBool, {
        "LineKey", "TripKey", "Region", "Delivery_Id", "Trip_Id",
        "Delivery_Name", "Trip_Name", "CarrierKey",
        "Mode_Of_Transport", "Service_Level", "Released_Status",
        "Delivery_Status", "Trip_Status", "Customer_PO", "BOL_Number",
        "Freight_Terms", "FOB_Code", "Ship_From_Site",
        "Ship_From_Country", "Ship_To_Country", "Ship_To_LocationKey",
        "Delivery_Confirm_Date", "Date_Requested", "Date_Scheduled",
        "Planned_Pickup", "Actual_Pickup",
        "Planned_Arrival", "Actual_Arrival", "Actual_Departure",
        "Shipped_MT", "Requested_MT", "Src_Requested_MT", "Picked_MT", "Cancelled_MT",
        "Gross_Weight_MT", "Net_Weight_MT",
        "Tolerance_Above_Pct", "Tolerance_Below_Pct",
        "Delivery_Delay_Days", "Is_Export"})
in
    Selected


/*  ==========================================================================
    15 · dim_Customer              references query 5
    --------------------------------------------------------------------------
    Conformed across all three facts. Sales order uses Customer_Number,
    invoice uses Sold_To_Customer_Id, shipment uses Customer_Account_Number —
    verified as the same 750-value domain with 100% overlap.

    Sorting by Ordered_Date descending before de-duplicating means the most
    recent attributes win. Table.Distinct on its own would keep whichever row
    happened to come first, which is arbitrary when a customer's address has
    changed.
    ========================================================================== */
let
    Source = qry_SalesOrder_Source,
    Picked = Table.SelectColumns(Source, {
        "CustomerKey", "Customer_Name", "Customer_Type",
        "Ship_To_Country", "Ship_To_City", "Ship_To_State", "Ordered_Date"}),
    NoBlank = Table.SelectRows(Picked, each [CustomerKey] <> null and [CustomerKey] <> ""),
    Sorted  = Table.Sort(NoBlank, {{"Ordered_Date", Order.Descending}}),
    Deduped = Table.Distinct(Table.Buffer(Sorted), {"CustomerKey"}),
    Renamed = Table.RenameColumns(Deduped, {
        {"Ship_To_Country", "Country"}, {"Ship_To_City", "City"}, {"Ship_To_State", "State"}}),
    Dropped = Table.RemoveColumns(Renamed, {"Ordered_Date"}),
    // Unknown member so an unmatched fact row stays visible rather than vanishing
    WithUnknown = Table.InsertRows(Dropped, 0, {[
        CustomerKey = "-1", Customer_Name = "Unknown", Customer_Type = "Unknown",
        Country = null, City = null, State = null]})
in
    WithUnknown


/*  ==========================================================================
    16 · dim_Product               references query 5
    --------------------------------------------------------------------------
    ProductKey = Line_Inventory_Item_Id + '.' + Line_Ship_From_Inventory_Org_Id,
    exactly as your SQL defines it. 1,726 distinct — the same item made at a
    different plant is a different ProductKey, which is correct for a
    manufacturer.
    ========================================================================== */
let
    Source = qry_SalesOrder_Source,
    Picked = Table.SelectColumns(Source, {
        "ProductKey", "Item_Id", "Item_Number", "Product_Description",
        "Inventory_Org_Id", "Ordered_Date"}),
    NoBlank = Table.SelectRows(Picked, each [ProductKey] <> null and [ProductKey] <> ""),
    Sorted  = Table.Sort(NoBlank, {{"Ordered_Date", Order.Descending}}),
    Deduped = Table.Distinct(Table.Buffer(Sorted), {"ProductKey"}),
    Dropped = Table.RemoveColumns(Deduped, {"Ordered_Date"}),
    WithUnknown = Table.InsertRows(Dropped, 0, {[
        ProductKey = "-1", Item_Id = null, Item_Number = "Unknown",
        Product_Description = "Unknown", Inventory_Org_Id = null]})
in
    WithUnknown


/*  ==========================================================================
    17 · dim_Organization          references query 5
    --------------------------------------------------------------------------
    OrgKey = Data_Source_Region + '-' + Line_Ship_From_Inventory_Org_Id.
    70 distinct manufacturing / dispatch organisations.
    ========================================================================== */
let
    Source = qry_SalesOrder_Source,
    Picked = Table.SelectColumns(Source, {
        "OrgKey", "Region", "Operating_Unit_Id", "Operating_Unit",
        "Inventory_Org_Id", "Ordered_Date"}),
    NoBlank = Table.SelectRows(Picked, each [OrgKey] <> null and [OrgKey] <> ""),
    Sorted  = Table.Sort(NoBlank, {{"Ordered_Date", Order.Descending}}),
    Deduped = Table.Distinct(Table.Buffer(Sorted), {"OrgKey"}),
    Dropped = Table.RemoveColumns(Deduped, {"Ordered_Date"}),
    WithUnknown = Table.InsertRows(Dropped, 0, {[
        OrgKey = "-1", Region = "Unknown", Operating_Unit_Id = null,
        Operating_Unit = "Unknown", Inventory_Org_Id = null]})
in
    WithUnknown


/*  ==========================================================================
    18 · dim_ReturnReason          references query 5
    --------------------------------------------------------------------------
    Reason_Group is the column that matters. Only 36 of 576 returns are
    genuinely rejected inventory — the rest are price adjustments, freight and
    demurrage, and input errors. A metric named "return rate" on the raw flag
    reports invoicing accuracy, not product quality. Label it Credit Note Rate.

    The non-breaking space strip already happened in SQL; without it 13 real
    reasons render as 15 categories.
    ========================================================================== */
let
    Source = qry_SalesOrder_Source,
    Picked = Table.SelectColumns(Source, {"Return_Reason"}),
    Deduped = Table.Distinct(Picked),

    Grouped = Table.AddColumn(Deduped, "Reason_Group", each
        let r = Text.Upper([Return_Reason]) in
        if r = "NOT A RETURN"                                      then "Not a return"
        else if List.Contains({"PRICE ADJUSTMENTS", "ADHOC ADJUSTMENT",
                          "QUARTERLY RECONS/TRUE UP", "TAX ADJUSTMENT",
                          "BCS-CREDITS"}, r)                       then "Commercial adjustment"
        else if List.Contains({"FREIGHT/DEMURRAGE/DENTENTION",
                          "SHIP REVERSAL BY PLANT",
                          "WAREHOUSE CHARGES"}, r)                 then "Logistics / service"
        else if r = "RETURNED/REJECTED INVENTORY"                  then "Product quality"
        else if r = "INPUT ERROR/CORRECTION"                       then "Process error"
        else                                                            "Uncategorised",
        type text),

    Physical = Table.AddColumn(Grouped, "Is_Physical_Return", each
        Text.Upper([Return_Reason]) = "RETURNED/REJECTED INVENTORY", type logical)
in
    Physical


/*  ==========================================================================
    19 · dim_Carrier               references query 7
    --------------------------------------------------------------------------
    173 carriers. 23.5% of delivery records carry none — those map to the
    Unknown member so the blind spot stays visible on the scorecard.
    On-time performance ranges from 39.7% to 90.6% between carriers, so this
    dimension is a negotiating position as much as a lookup.
    ========================================================================== */
let
    Source = qry_Shipment_Source,
    Picked = Table.SelectColumns(Source, {
        "CarrierKey", "Carrier_Name", "Carrier_SCAC", "Delivery_Confirm_Date"}),
    NoBlank = Table.SelectRows(Picked, each [CarrierKey] <> null and [CarrierKey] <> "-1"),
    Sorted  = Table.Sort(NoBlank, {{"Delivery_Confirm_Date", Order.Descending}}),
    Deduped = Table.Distinct(Table.Buffer(Sorted), {"CarrierKey"}),
    Renamed = Table.RenameColumns(Deduped, {{"Carrier_SCAC", "SCAC"}}),
    Dropped = Table.RemoveColumns(Renamed, {"Delivery_Confirm_Date"}),
    WithUnknown = Table.InsertRows(Dropped, 0, {[
        CarrierKey = "-1", Carrier_Name = "Not recorded", SCAC = null]})
in
    WithUnknown


/*  ==========================================================================
    RELATIONSHIPS TO CREATE  (Model view — all Single direction, no exceptions)
    ==========================================================================

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

    dim_ExchangeRate is consumed inside fact_SalesOrder and is NOT related to
    anything. Load it only if you want the rate history visible for audit.

    The two inactive date relationships are activated inside measures with
    USERELATIONSHIP. That is what lets "revenue by invoice month" coexist with
    "orders by order month". It matters more than it sounds: the credit-rate
    spike is invisible on the order-date timeline.

    NEVER create a relationship between two fact tables. Turn OFF
    File > Options > Current File > Data Load > Autodetect new relationships
    BEFORE the first refresh, or Power BI will create exactly that for you.
    ========================================================================== */
