/*  ==========================================================================
    ORDER-TO-CASH SEMANTIC MODEL  —  POWER QUERY (M)
    ==========================================================================
    14 queries: 2 parameters, 1 bridge, 3 facts, 8 dimensions.

    SETUP
      1. Create a Text parameter named  p_SourceFolder  pointing at the folder
         holding f_SalesOrder.csv, f_Invoice.csv, f_Shipment.csv and
         d_currency.xlsx.
      2. Paste each block below into Home > Transform data > New Source >
         Blank Query > Advanced Editor, and rename the query to the name in
         its header.
      3. Build in the order printed. Later queries reference earlier ones.

    THE FOUR CORRECTIONS BUILT IN HERE
      A. 48 malformed f_Shipment rows removed        (else tonnage x13)
      B. Return quantities sign-normalised           (else volume +4%)
      C. Sentinel dates beyond 2030 nulled           (else axes reach 2400)
      D. Non-breaking spaces stripped from reasons   (else 13 reasons look like 15)

    CURRENCY
      dim_ExchangeRate (query 13) reads the real d_exchange_rate.xlsx, filtered
      to Conversion_Type = "Corporate" and To_Currency_Code = "USD", keyed on
      currency + region + date. Conversion is struck at ACTUAL SHIPMENT DATE,
      which is what the source does — verified on 25,601 rows carrying both a
      local and a USD price. Unshipped lines fall to PROMISE DATE, which was
      tested the same way and beats every other forward date available.
      Coverage is 99.999%: one line of 68,469 has no local price to convert.
    ========================================================================== */


/*  ==========================================================================
    01 · p_SourceFolder            PARAMETER — create this first
    ========================================================================== */
"C:\Data\OrderToCash"


/*  ==========================================================================
    01b · p_LastQuotedRateDate     PARAMETER — the last real quote in d_exchange_rate
    --------------------------------------------------------------------------
    Anything converted at a date after this is using the last known rate carried
    forward, not a quoted one. Used only to set FX_Rate_Is_Forward.
    Refresh this whenever d_exchange_rate is refreshed.
    ========================================================================== */
#date(2026, 8, 31)


/*  ==========================================================================
    02 · dim_SalesOrderLine        THE BRIDGE — one row per sales order line
    --------------------------------------------------------------------------
    Every fact filters through this table. Nothing joins fact-to-fact.
    Grain confirmed against the source: LineKey = Data_Source_Region + '-' +
    Line_Id, unique across all 68,469 rows with zero nulls.
    ========================================================================== */
let
    Source = Csv.Document(
        File.Contents(p_SourceFolder & "\f_SalesOrder.csv"),
        [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]
    ),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),

    // ---- CORRECTION B (flag only; the signing happens in fact_SalesOrder) ----
    // Four indicators exist and they disagree. Line_Category_Code and
    // Line_Return_Reason_Code each catch all 608 returns and agree on every
    // row. Line_Type_Name catches 165 (27%), Quick_RMA catches 8 (1.3%).
    // ORed together so the definition survives a source change.
    AddIsReturn = Table.AddColumn(Promoted, "Is_Return", each
        [Line_Category_Code] = "RETURN"
        or ([Line_Return_Reason_Code] <> null and [Line_Return_Reason_Code] <> "")
        or Text.Contains(Text.Upper([Line_Type_Name] ?? ""), "RMA")
        or Text.Contains(Text.Upper([Line_Type_Name] ?? ""), "RETURN")
        or ([Line_DFF_Quick_RMA_Original_Line_Id] <> null
            and [Line_DFF_Quick_RMA_Original_Line_Id] <> ""),
        type logical),

    // ---- CORRECTION D ----
    // Trailing U+00A0 makes INPUT ERROR/CORRECTION and PRICE ADJUSTMENTS each
    // appear twice, so 13 real reasons render as 15 categories on every visual.
    CleanReason = Table.AddColumn(AddIsReturn, "Return_Reason", each
        if [Is_Return]
        then Text.Trim(Text.Replace(
                [Line_Return_Reason_Code] ?? "Not specified",
                Character.FromNumber(160), " "))
        else "Not a return", type text),

    Flags = Table.AddColumn(
        Table.AddColumn(
            Table.AddColumn(CleanReason, "Is_Open",      each [Line_Open_Flag]      = "Y", type logical),
                                        "Is_Cancelled",  each [Line_Cancelled_Flag] = "Y", type logical),
                                        "Is_Fulfilled",  each [Line_Fulfilled_Flag] = "Y", type logical),

    Renamed = Table.RenameColumns(Flags, {
        {"Data_Source_Region",            "Region"},
        {"Customer_Number",               "CustomerKey"},
        {"Operating_Unit_Name",           "Operating_Unit"},
        {"Line_Shipping_Transport_Mode",  "Transport_Mode"},
        {"Transactional_Currency_Code",   "Currency_Code"},
        {"Line_Ship_To_Country",          "Ship_To_Country"},
        {"Line_Ship_To_City",             "Ship_To_City"},
        {"Line_Schedule_Ship_Date",       "Schedule_Ship_Date"},
        {"Line_Schedule_Arrival_Date",    "Schedule_Arrival_Date"},
        {"Line_Promise_Date",             "Promise_Date"},
        {"Line_Request_Date",             "Request_Date"},
        {"Line_Actual_Shipment_Date",     "Actual_Shipment_Date"},
        {"Line_Fulfillment_Date",         "Fulfillment_Date"},
        {"Line_Price_List_Name",          "Price_List"},
        {"Line_Customer_PO_Number",       "Customer_PO"},
        {"Line_Status",                   "Line_Status"},
        {"Line_Category_Code",            "Line_Category"}
    }),

    // CurrencyKey is composite. d_currency is grained Code x Region — the same
    // code carries a different description per region — so a code-only join
    // would fan out four ways.
    AddCurrencyKey = Table.AddColumn(Renamed, "CurrencyKey", each
        [Currency_Code] & "|" & [Region], type text),

    Selected = Table.SelectColumns(AddCurrencyKey, {
        "LineKey", "DP_Key", "ProductKey", "OrgKey",
        "Order_Number", "Order_Status", "Line_Status", "Line_Category",
        "Line_Shipment_Num", "Order_Type_Name",
        "Region", "CustomerKey", "Operating_Unit", "CurrencyKey", "Currency_Code",
        "Incoterm", "Transport_Mode", "Sales_Rep", "CSR", "Sales_Type",
        "Price_List", "Customer_PO", "Customer_Contract",
        "Ship_To_Country", "Ship_To_City",
        "Ordered_Date", "Schedule_Ship_Date", "Schedule_Arrival_Date",
        "Promise_Date", "Request_Date", "Actual_Shipment_Date", "Fulfillment_Date",
        "Is_Return", "Return_Reason", "Is_Open", "Is_Cancelled", "Is_Fulfilled"
    }),

    Typed = Table.TransformColumnTypes(Selected, {
        {"Ordered_Date",          type datetime},
        {"Schedule_Ship_Date",    type datetime},
        {"Schedule_Arrival_Date", type datetime},
        {"Promise_Date",          type datetime},
        {"Request_Date",          type datetime},
        {"Actual_Shipment_Date",  type datetime},
        {"Fulfillment_Date",      type datetime}
    }),

    // ---- CORRECTION C ----
    // Schedule and request dates carry placeholders out to the year 2400.
    // Left in, every date axis in the report stretches to meet them.
    CapDate = (d as nullable datetime) as nullable datetime =>
        if d = null or d > #datetime(2030, 12, 30, 0, 0, 0) then null else d,

    CapDates = Table.TransformColumns(Typed, {
        {"Schedule_Ship_Date",    CapDate, type nullable datetime},
        {"Schedule_Arrival_Date", CapDate, type nullable datetime},
        {"Promise_Date",          CapDate, type nullable datetime},
        {"Request_Date",          CapDate, type nullable datetime}
    }),

    NoBlankKeys = Table.SelectRows(CapDates, each [LineKey] <> null and [LineKey] <> "")
in
    NoBlankKeys


/*  ==========================================================================
    03 · fact_SalesOrder           GRAIN: one sales order line
    --------------------------------------------------------------------------
    Measures only. Every descriptive column already lives on the bridge —
    carrying it twice doubles the memory for nothing.
    ========================================================================== */
let
    Source = Csv.Document(
        File.Contents(p_SourceFolder & "\f_SalesOrder.csv"),
        [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]
    ),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),

    IsRet = Table.AddColumn(Promoted, "IsRet", each
        [Line_Category_Code] = "RETURN"
        or ([Line_Return_Reason_Code] <> null and [Line_Return_Reason_Code] <> "")
        or Text.Contains(Text.Upper([Line_Type_Name] ?? ""), "RMA")
        or Text.Contains(Text.Upper([Line_Type_Name] ?? ""), "RETURN"),
        type logical),

    Num = Table.TransformColumnTypes(IsRet, {
        {"Line_Ordered_Qty_Metric_Ton",  type number},
        {"Line_Shipped_Qty_Metric_Ton",  type number},
        {"Line_Invoiced_Qty_Metric_Ton", type number},
        {"Line_Ordered_Qty",             type number},
        {"Line_Unit_List_Price",         type number},
        {"Line_Unit_List_Price_USD",     type number},
        {"Line_Unit_Selling_Price",      type number},
        {"Line_Unit_Selling_Price_USD",  type number},
        {"Ordered_Date",                 type datetime}
    }),

    // ---- CORRECTION A ----
    // The source stores ordered and shipped POSITIVE but invoiced NEGATIVE on
    // the same 608 return lines. Loaded untouched, ordered volume inflates
    // 4.11% and shipped 4.30%. Invoiced is already signed — do not flip it.
    Signed = Table.AddColumn(
        Table.AddColumn(Num, "Ordered_MT_Signed", each
            if [IsRet] then -1 * ([Line_Ordered_Qty_Metric_Ton] ?? 0)
            else ([Line_Ordered_Qty_Metric_Ton] ?? 0), type number),
        "Shipped_MT_Signed", each
            if [IsRet] then -1 * ([Line_Shipped_Qty_Metric_Ton] ?? 0)
            else ([Line_Shipped_Qty_Metric_Ton] ?? 0), type number),

    // ---- CURRENCY ----
    // WHICH DATE THE CONVERSION IS STRUCK AT — tested, not assumed.
    // Comparing the rate implied by the source (USD price / local price) to
    // the Corporate rate on each candidate date, across 25,601 SHIPPED rows
    // that already carry both prices:
    //     Actual shipment date   100.0% within 0.5%   <- what the source uses
    //     Fulfilment date         99.4%
    //     Scheduled ship date     76.1%
    //     Order date              28.2%
    //
    // Unshipped lines have no actual date, so the ladder continues. Tested
    // again on the 1,662 UNSHIPPED rows that do carry a source USD price:
    //     Promise date           77.2% within 0.5%,  median error 0.173%  <- best
    //     Requested date         53.7%               median error 0.339%
    //     Scheduled ship date    53.0%               median error 0.354%
    //     Order date             57.3%               median error 0.353%
    //
    // So promise date sits third: it is the forward commitment the business
    // actually made, and it predicts the rate better than any other available
    // date on open lines. Scheduled ship stays as the backstop because promise
    // date is only 60.8% populated on unshipped lines.
    AddFXDate = Table.AddColumn(AddCurrencyKey, "FX_Date", each
        DateTime.Date(
            [Line_Actual_Shipment_Date]
            ?? [Line_Fulfillment_Date]
            ?? (if [Line_Promise_Date] <> null
                    and [Line_Promise_Date] <= #datetime(2030,12,30,0,0,0)
                then [Line_Promise_Date] else null)
            ?? (if [Line_Schedule_Ship_Date] <> null
                    and [Line_Schedule_Ship_Date] <= #datetime(2030,12,30,0,0,0)
                then [Line_Schedule_Ship_Date] else null)
            ?? [Ordered_Date]), type date),

    // Kept so a reader can see which rung each row used, and therefore whether
    // a figure is realised or forward-looking.
    AddFXBasis = Table.AddColumn(AddFXDate, "FX_Date_Basis", each
        if [Line_Actual_Shipment_Date] <> null then "1 - Actual shipment"
        else if [Line_Fulfillment_Date] <> null then "2 - Fulfilment"
        else if [Line_Promise_Date] <> null
                and [Line_Promise_Date] <= #datetime(2030,12,30,0,0,0)
             then "3 - Promise date (forward)"
        else if [Line_Schedule_Ship_Date] <> null
                and [Line_Schedule_Ship_Date] <= #datetime(2030,12,30,0,0,0)
             then "4 - Scheduled ship (forward)"
        else "5 - Order date", type text),

    JoinRate = Table.NestedJoin(AddFXBasis, {"CurrencyKey", "FX_Date"},
        dim_ExchangeRate, {"CurrencyKey", "Rate_Date"}, "fx", JoinKind.LeftOuter),
    ExpandRate = Table.ExpandTableColumn(JoinRate, "fx",
        {"Rate_USD_per_Local", "Rate_Source"}, {"FX_Rate", "FX_Rate_Source"}),

    // A promise date can sit past the last quoted rate. Those rows carry the
    // last known rate carried forward, which is the right behaviour for a
    // forward valuation but must not be mistaken for a quoted one.
    // Update p_LastQuotedRateDate whenever d_exchange_rate is refreshed.
    AddForwardFlag = Table.AddColumn(ExpandRate, "FX_Rate_Is_Forward", each
        [FX_Date] > p_LastQuotedRateDate, type logical),

    // Source USD always wins. Only fill where the source left a gap.
    FillSelling = Table.AddColumn(AddForwardFlag, "Unit_Selling_Price_USD", each
        if [Line_Unit_Selling_Price_USD] <> null then [Line_Unit_Selling_Price_USD]
        else if [FX_Rate] <> null and [Line_Unit_Selling_Price] <> null
             then [Line_Unit_Selling_Price] * [FX_Rate]
        else null, type nullable number),

    FillList = Table.AddColumn(FillSelling, "Unit_List_Price_USD", each
        if [Line_Unit_List_Price_USD] <> null then [Line_Unit_List_Price_USD]
        else if [FX_Rate] <> null and [Line_Unit_List_Price] <> null
             then [Line_Unit_List_Price] * [FX_Rate]
        else null, type nullable number),

    // A converted number must never be indistinguishable from a source one.
    // Converted values reproduce the source exactly on 93.9% of testable rows
    // and land within 0.5% on 96.9% — but they are still labelled.
    Quality = Table.AddColumn(FillList, "Price_USD_Quality", each
        if [Line_Unit_Selling_Price_USD] <> null then "1 - Source"
        else if [Unit_Selling_Price_USD] <> null then "2 - Converted at Corporate rate"
        else "3 - Not convertible", type text),

    Renamed = Table.RenameColumns(Quality, {
        {"Line_Invoiced_Qty_Metric_Ton", "Invoiced_MT"},
        {"Line_Ordered_Qty",             "Ordered_Qty_Native"},
        {"Line_Unit_Selling_Price",      "Unit_Selling_Price_Local"},
        {"Line_Unit_List_Price",         "Unit_List_Price_Local"}
    }),

    Selected = Table.SelectColumns(Renamed, {
        "LineKey", "CurrencyKey", "Price_USD_Quality",
        "Ordered_MT_Signed", "Shipped_MT_Signed", "Invoiced_MT", "Ordered_Qty_Native",
        "Unit_List_Price_USD", "Unit_Selling_Price_USD",
        "Unit_List_Price_Local", "Unit_Selling_Price_Local",
        "FX_Rate", "FX_Rate_Source", "FX_Date", "FX_Date_Basis", "FX_Rate_Is_Forward"
    })
in
    Selected


/*  ==========================================================================
    04 · fact_Invoice              GRAIN: one invoice line
    --------------------------------------------------------------------------
    Unique on (LineKey, Invoice_Number, Line_Number) — 79,576 distinct across
    79,576 rows, so no deduplication is needed or wanted.
    ========================================================================== */
let
    Source = Csv.Document(
        File.Contents(p_SourceFolder & "\f_Invoice.csv"),
        [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]
    ),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),

    Num = Table.TransformColumnTypes(Promoted, {
        {"Line_Revenue_Amount_USD",       type number},
        {"Line_Quantity_Invoiced_MT",     type number},
        {"Line_Quantity_Credited_MT",     type number},
        {"Line_Base_Amount",              type number},
        {"Line_Regional_Premium_Amount",  type number},
        {"Line_Product_Premium_Amount",   type number},
        {"Line_Green_Premium_Amount",     type number},
        {"Line_Other_Premium_Amount",     type number},
        {"Line_Tariff_Amount",            type number},
        {"Line_Alloy_Amount",             type number},
        {"Line_Unit_Selling_Price_USD",   type number},
        {"Line_Unit_Standard_Price_USD",  type number},
        {"Invoice_Date",                  type datetime},
        {"Ship_Date_Actual",              type datetime},
        {"Batch_GL_Date",                 type datetime}
    }),

    // Credit memos are a separate, larger population than sales-order returns.
    // Only 475 invoice lines tie back to a return order; 4,925 are credits.
    // Filtering by the SO return flag finds under 10% of them.
    // Verified: this rule leaves exactly zero negative revenue outside it.
    AddCM = Table.AddColumn(Num, "Is_Credit_Memo", each
        Text.Contains(Text.Upper([Transaction_Type] ?? ""), "CM")
        or Text.Contains(Text.Upper([Transaction_Type] ?? ""), "CRD")
        or Text.Contains(Text.Upper([Transaction_Type] ?? ""), "_NC")
        or ([Line_Revenue_Amount_USD] ?? 0) < 0
        or [Line_Quantity_Credited_MT] <> null,
        type logical),

    AddCat = Table.AddColumn(AddCM, "Transaction_Category", each
        if [Is_Credit_Memo] then "Credit memo" else "Invoice", type text),

    // The premium breakdown is only populated on NAM and EUR lines (76%).
    // SAM and AUS have none, so any bridge visual must be filtered to this flag
    // or it silently reports on three-quarters of the business.
    AddBridge = Table.AddColumn(AddCat, "Has_Price_Bridge", each
        [Line_Base_Amount] <> null, type logical),

    Renamed = Table.RenameColumns(AddBridge, {
        {"Data_Source_Region",             "Region"},
        {"Legal_Entity_Name",              "Legal_Entity"},
        {"Operating_Unit_Name",            "Operating_Unit"},
        {"Line_Revenue_Amount_USD",        "Revenue_USD"},
        {"Line_Quantity_Invoiced_MT",      "Qty_Invoiced_MT"},
        {"Line_Quantity_Credited_MT",      "Qty_Credited_MT"},
        {"Line_Base_Amount",               "Base_Amount"},
        {"Line_Regional_Premium_Amount",   "Regional_Premium"},
        {"Line_Product_Premium_Amount",    "Product_Premium"},
        {"Line_Green_Premium_Amount",      "Green_Premium"},
        {"Line_Other_Premium_Amount",      "Other_Premium"},
        {"Line_Tariff_Amount",             "Tariff_Amount"},
        {"Line_Alloy_Amount",              "Alloy_Amount"},
        {"Line_Unit_Selling_Price_USD",    "Unit_Selling_Price_USD"},
        {"Line_Unit_Standard_Price_USD",   "Unit_Standard_Price_USD"},
        {"Sold_To_Customer_Id",            "Sold_To_CustomerKey"}
    }),

    Selected = Table.SelectColumns(Renamed, {
        "LineKey", "Invoice_Number", "Transaction_Number", "Line_Number",
        "Invoice_Date", "Ship_Date_Actual", "Batch_GL_Date",
        "Region", "Legal_Entity", "Operating_Unit", "Term_Name", "Incoterm",
        "Transaction_Type", "Transaction_Status",
        "Is_Credit_Memo", "Transaction_Category", "Has_Price_Bridge",
        "Sold_To_CustomerKey",
        "Revenue_USD", "Qty_Invoiced_MT", "Qty_Credited_MT",
        "Unit_Selling_Price_USD", "Unit_Standard_Price_USD",
        "Base_Amount", "Regional_Premium", "Product_Premium", "Green_Premium",
        "Other_Premium", "Tariff_Amount", "Alloy_Amount"
    })
in
    Selected


/*  ==========================================================================
    05 · fact_Shipment             GRAIN: one delivery detail line
    --------------------------------------------------------------------------
    283 source columns reduced to 30. Of the rest: 21 are completely empty,
    11 are populated but all-zero, 27 too sparse, 70 redundant twins,
    38 audit plumbing, 10 parser artefacts, 35 belong on a dimension.
    ========================================================================== */
let
    Source = Csv.Document(
        File.Contents(p_SourceFolder & "\f_Shipment.csv"),
        [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]
    ),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),

    // ---- CORRECTION A — the single most important line in this file ----
    // 48 rows have shifted columns, leaving values like "PER2" and "9.6" in
    // Data_Source_Region and pushing data into trailing Unnamed columns.
    // Left in they report 282.5m MT against a true 21.2m MT — one row alone
    // contributes 39.5m. Costs at most 3 valid LineKeys.
    Clean = Table.SelectRows(Promoted, each
        List.Contains({"NAM", "EUR", "SAM", "AUS"}, [Data_Source_Region])),

    Num = Table.TransformColumnTypes(Clean, {
        {"Delivery_Detail_Shipped_Qty_MT",              type number},
        {"Delivery_Detail_Requested_Qty_MT",            type number},
        {"Delivery_Detail_Src_Requested_Qty_MT",        type number},
        {"Delivery_Detail_Picked_Qty_MT",               type number},
        {"Delivery_Detail_Cancelled_Qty_MT",            type number},
        {"Delivery_Gross_Weight_MT",                    type number},
        {"Delivery_Net_Weight_MT",                      type number},
        {"Delivery_Detail_Ship_Tolerance_Above",        type number},
        {"Delivery_Detail_Ship_Tolerance_Below",        type number},
        {"Delivery_Confirm_Date",                       type datetime},
        {"Delivery_Detail_Date_Requested",              type datetime},
        {"Delivery_Detail_Date_Scheduled",              type datetime},
        {"Trip_Stop_Pick_Up_Planned_Arrival_Date",      type datetime},
        {"Trip_Stop_Pick_Up_Actual_Arrival_Date",       type datetime},
        {"Trip_Stop_Drop_Off_Planned_Arrival_Date",     type datetime},
        {"Trip_Stop_Drop_Off_Actual_Arrival_Date",      type datetime},
        {"Trip_Stop_Drop_Off_Actual_Departure_Date",    type datetime}
    }),

    Renamed = Table.RenameColumns(Num, {
        {"Data_Source_Region",                        "Region"},
        {"Delivery_Carrier_Id",                       "CarrierKey"},
        {"Delivery_Mode_Of_Transport",                "Mode_Of_Transport"},
        {"Delivery_Service_Level",                    "Service_Level"},
        {"Ship_From_Organization_Code",               "Ship_From_Site"},
        {"Delivery_Detail_Released_Status",           "Released_Status"},
        {"Delivery_Detail_Customer_PO_Number",        "Customer_PO"},
        {"Delivery_Bill_Of_Lading_Number",            "BOL_Number"},
        {"Delivery_Freight_Terms_Code",               "Freight_Terms"},
        {"Delivery_FOB_Code",                         "FOB_Code"},
        {"Trip_Stop_Drop_Off_Planned_Arrival_Date",   "Planned_Arrival"},
        {"Trip_Stop_Drop_Off_Actual_Arrival_Date",    "Actual_Arrival"},
        {"Trip_Stop_Drop_Off_Actual_Departure_Date",  "Actual_Departure"},
        {"Trip_Stop_Pick_Up_Planned_Arrival_Date",    "Planned_Pickup"},
        {"Trip_Stop_Pick_Up_Actual_Arrival_Date",     "Actual_Pickup"},
        {"Delivery_Detail_Date_Requested",            "Date_Requested"},
        {"Delivery_Detail_Date_Scheduled",            "Date_Scheduled"},
        {"Delivery_Detail_Shipped_Qty_MT",            "Shipped_MT"},
        {"Delivery_Detail_Requested_Qty_MT",          "Requested_MT"},
        {"Delivery_Detail_Src_Requested_Qty_MT",      "Src_Requested_MT"},
        {"Delivery_Detail_Picked_Qty_MT",             "Picked_MT"},
        {"Delivery_Detail_Cancelled_Qty_MT",          "Cancelled_MT"},
        {"Delivery_Gross_Weight_MT",                  "Gross_Weight_MT"},
        {"Delivery_Net_Weight_MT",                    "Net_Weight_MT"},
        {"Delivery_Detail_Ship_Tolerance_Above",      "Tolerance_Above_Pct"},
        {"Delivery_Detail_Ship_Tolerance_Below",      "Tolerance_Below_Pct"}
    }),

    // Unknown member so orphan rows stay visible instead of silently vanishing.
    // 23.5% of delivery records carry no carrier at all.
    FixCarrier = Table.ReplaceValue(Renamed, null, "-1",
        Replacer.ReplaceValue, {"CarrierKey"}),

    Selected = Table.SelectColumns(FixCarrier, {
        "LineKey", "TripKey", "Region", "Delivery_Id", "Trip_Id",
        "Delivery_Name", "Trip_Name", "CarrierKey",
        "Mode_Of_Transport", "Service_Level", "Released_Status",
        "Delivery_Status", "Trip_Status", "Customer_PO", "BOL_Number",
        "Freight_Terms", "FOB_Code", "Ship_From_Site",
        "Ship_From_Country", "Ship_To_Country",
        "Delivery_Confirm_Date", "Date_Requested", "Date_Scheduled",
        "Planned_Pickup", "Actual_Pickup",
        "Planned_Arrival", "Actual_Arrival", "Actual_Departure",
        "Shipped_MT", "Requested_MT", "Src_Requested_MT", "Picked_MT", "Cancelled_MT",
        "Gross_Weight_MT", "Net_Weight_MT",
        "Tolerance_Above_Pct", "Tolerance_Below_Pct"
    })
in
    Selected


/*  ==========================================================================
    06 · dim_Date                  Marked as the model date table
    --------------------------------------------------------------------------
    Anchored to Ordered_Date. Invoice date and delivery confirm date are wired
    as INACTIVE relationships and activated inside specific measures.
    Is_Complete_Month exists because the extract ends mid-August — every trend
    chart otherwise shows a false collapse in the final month.
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
        "Year",              each Date.Year([Date]),                                  Int64.Type),
        "Month_Number",      each Date.Month([Date]),                                 Int64.Type),
        "Month_Short",       each Date.ToText([Date], "MMM"),                         type text),
        "Year_Month",        each Date.ToText([Date], "MMM yyyy"),                    type text),
        "Year_Month_Sort",   each Date.Year([Date]) * 100 + Date.Month([Date]),       Int64.Type),
        "Quarter",           each "Q" & Text.From(Date.QuarterOfYear([Date])),        type text),
        "Year_Quarter",      each Text.From(Date.Year([Date])) & " Q"
                                  & Text.From(Date.QuarterOfYear([Date])),            type text),
        "Is_Complete_Month", each Date.EndOfMonth([Date]) <= LastFullMonthEnd,        type logical),

    Final = Table.TransformColumnTypes(Cols, {{"Date", type datetime}})
in
    Final


/*  ==========================================================================
    07 · dim_Customer
    --------------------------------------------------------------------------
    Conformed across all three facts. Sales order uses Customer_Number,
    invoice uses Sold_To_Customer_Id, shipment uses Customer_Account_Number —
    verified as the same 749-value domain with 100% overlap.
    ========================================================================== */
let
    Source = Csv.Document(
        File.Contents(p_SourceFolder & "\f_SalesOrder.csv"),
        [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]
    ),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    Picked = Table.SelectColumns(Promoted, {
        "Customer_Number", "Customer_Name", "Customer_Type",
        "Line_Ship_To_Country", "Line_Ship_To_City", "Line_Ship_To_State"}),
    Renamed = Table.RenameColumns(Picked, {
        {"Customer_Number",      "CustomerKey"},
        {"Line_Ship_To_Country", "Country"},
        {"Line_Ship_To_City",    "City"},
        {"Line_Ship_To_State",   "State"}}),
    NoBlank = Table.SelectRows(Renamed, each [CustomerKey] <> null and [CustomerKey] <> ""),
    Deduped = Table.Distinct(NoBlank, {"CustomerKey"}),
    WithUnknown = Table.InsertRows(Deduped, 0, {[
        CustomerKey = "-1", Customer_Name = "Unknown", Customer_Type = "Unknown",
        Country = null, City = null, State = null]})
in
    WithUnknown


/*  ==========================================================================
    08 · dim_Product
    --------------------------------------------------------------------------
    ProductKey = Line_Inventory_Item_Id + '.' + Line_Ship_From_Inventory_Org_Id,
    exactly as your SQL defines it. 1,722 distinct combinations — the same item
    made at a different plant is a different ProductKey, which is correct for
    a manufacturer.
    ========================================================================== */
let
    Source = Csv.Document(
        File.Contents(p_SourceFolder & "\f_SalesOrder.csv"),
        [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]
    ),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    Picked = Table.SelectColumns(Promoted, {
        "ProductKey", "Line_Inventory_Item_Id", "Line_Product_Item_Number",
        "Line_Product_Item_Description", "Inventory_Id"}),
    Renamed = Table.RenameColumns(Picked, {
        {"Line_Inventory_Item_Id",        "Item_Id"},
        {"Line_Product_Item_Number",      "Item_Number"},
        {"Line_Product_Item_Description", "Product_Description"},
        {"Inventory_Id",                  "Inventory_Org_Id"}}),
    NoBlank = Table.SelectRows(Renamed, each [ProductKey] <> null and [ProductKey] <> ""),
    Deduped = Table.Distinct(NoBlank, {"ProductKey"}),
    WithUnknown = Table.InsertRows(Deduped, 0, {[
        ProductKey = "-1", Item_Id = null, Item_Number = "Unknown",
        Product_Description = "Unknown", Inventory_Org_Id = null]})
in
    WithUnknown


/*  ==========================================================================
    09 · dim_Organization
    --------------------------------------------------------------------------
    OrgKey = Data_Source_Region + '-' + Line_Ship_From_Inventory_Org_Id,
    per your SQL. 70 distinct manufacturing / dispatch organisations.
    ========================================================================== */
let
    Source = Csv.Document(
        File.Contents(p_SourceFolder & "\f_SalesOrder.csv"),
        [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]
    ),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    Picked = Table.SelectColumns(Promoted, {
        "OrgKey", "Data_Source_Region", "Operating_Unit_Id",
        "Operating_Unit_Name", "Inventory_Id"}),
    Renamed = Table.RenameColumns(Picked, {
        {"Data_Source_Region",  "Region"},
        {"Operating_Unit_Name", "Operating_Unit"},
        {"Inventory_Id",        "Inventory_Org_Id"}}),
    NoBlank = Table.SelectRows(Renamed, each [OrgKey] <> null and [OrgKey] <> ""),
    Deduped = Table.Distinct(NoBlank, {"OrgKey"}),
    WithUnknown = Table.InsertRows(Deduped, 0, {[
        OrgKey = "-1", Region = "Unknown", Operating_Unit_Id = null,
        Operating_Unit = "Unknown", Inventory_Org_Id = null]})
in
    WithUnknown


/*  ==========================================================================
    10 · dim_Carrier
    --------------------------------------------------------------------------
    173 carriers. Note 23.5% of delivery records carry no carrier at all —
    they map to the Unknown member so the gap stays visible on the scorecard
    instead of quietly shrinking the denominator.
    ========================================================================== */
let
    Source = Csv.Document(
        File.Contents(p_SourceFolder & "\f_Shipment.csv"),
        [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]
    ),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    Clean = Table.SelectRows(Promoted, each
        List.Contains({"NAM", "EUR", "SAM", "AUS"}, [Data_Source_Region])),
    Picked = Table.SelectColumns(Clean, {
        "Delivery_Carrier_Id", "Delivery_Carrier_Name", "Delivery_Carrier_SCAC"}),
    Renamed = Table.RenameColumns(Picked, {
        {"Delivery_Carrier_Id",   "CarrierKey"},
        {"Delivery_Carrier_Name", "Carrier_Name"},
        {"Delivery_Carrier_SCAC", "SCAC"}}),
    NoBlank = Table.SelectRows(Renamed, each [CarrierKey] <> null and [CarrierKey] <> ""),
    Deduped = Table.Distinct(NoBlank, {"CarrierKey"}),
    WithUnknown = Table.InsertRows(Deduped, 0, {[
        CarrierKey = "-1", Carrier_Name = "Not recorded", SCAC = null]})
in
    WithUnknown


/*  ==========================================================================
    11 · dim_ReturnReason
    --------------------------------------------------------------------------
    Reason_Group is the column that matters. Only 38 of 608 returns are
    genuinely rejected inventory — the rest are billing corrections, so a
    metric named "return rate" on the raw flag reports invoicing accuracy,
    not product quality.
    ========================================================================== */
let
    Source = Csv.Document(
        File.Contents(p_SourceFolder & "\f_SalesOrder.csv"),
        [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]
    ),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    Returns = Table.SelectRows(Promoted, each [Line_Category_Code] = "RETURN"),

    // ---- CORRECTION D ----
    Cleaned = Table.AddColumn(Returns, "Return_Reason", each
        Text.Trim(Text.Replace([Line_Return_Reason_Code] ?? "Not specified",
            Character.FromNumber(160), " ")), type text),

    Grouped = Table.AddColumn(Cleaned, "Reason_Group", each
        let r = Text.Upper([Return_Reason]) in
        if List.Contains({"PRICE ADJUSTMENTS", "ADHOC ADJUSTMENT",
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
        Text.Upper([Return_Reason]) = "RETURNED/REJECTED INVENTORY", type logical),

    Picked  = Table.SelectColumns(Physical, {"Return_Reason", "Reason_Group", "Is_Physical_Return"}),
    Deduped = Table.Distinct(Picked, {"Return_Reason"}),
    WithNonReturn = Table.InsertRows(Deduped, 0, {[
        Return_Reason = "Not a return", Reason_Group = "Not a return",
        Is_Physical_Return = false]})
in
    WithNonReturn


/*  ==========================================================================
    12 · dim_Currency              from d_currency.xlsx
    --------------------------------------------------------------------------
    IMPORTANT — the grain is Currency_Code x Region, not Currency_Code.
    1,000 rows, 308 codes, 4 regions. The same code carries a different
    description per region ("US dollar" in NAM, "US Dollar" in EUR), so a
    code-only join fans out up to four ways and quadruples every amount.
    CurrencyKey = Code|Region is the join key.

    USC = "Dolar Compra" — SAM only, 2,960 lines. The rate table resolves it
    as 1:1 with USD (direct USC -> USD rows read exactly 1.000000, and
    BRL -> USC tracks BRL -> USD within 0.011% across 591 dates). It is NOT
    US cents. All 2,960 lines are now convertible.
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

    // Marks the codes that need no conversion at all.
    AddIsUSD = Table.AddColumn(AddKey, "Is_USD", each
        [Currency_Code] = "USD", type logical),

    // Every code in use now converts. USC ("Dolar Compra") resolves 1:1 with
    // USD — see the evidence in query 13. Add a code here only if the rate
    // table genuinely cannot reach USD for it.
    AddConvertible = Table.AddColumn(AddIsUSD, "Is_Convertible", each
        not List.Contains({}, [Currency_Code]), type logical),

    Deduped = Table.Distinct(AddConvertible, {"CurrencyKey"}),
    WithUnknown = Table.InsertRows(Deduped, 0, {[
        Currency_PK_Key = -1, Currency_Code = "UNK", Currency_Desc = "Unknown",
        Region = "Unknown", CurrencyKey = "UNK|Unknown",
        Is_USD = false, Is_Convertible = false]})
in
    WithUnknown


/*  ==========================================================================
    13 · dim_ExchangeRate          from d_exchange_rate.xlsx
    --------------------------------------------------------------------------
    112,877 source rows reduced to a daily USD conversion spine.

    WHAT THE SOURCE CONTAINS
      Data_Source_Region, From_Currency_Code, To_Currency_Code, Conversion_Date
      (daily), Conversion_Type, Conversion_Rate. Direction is From -> To, so
      AUD -> BRL at 3.843 means 1 AUD buys 3.843 BRL.

    THREE DECISIONS MADE HERE, EACH CHECKED AGAINST THE DATA

    1. Conversion_Type = "Corporate" only.
       The file holds 55 conversion types. Corporate is the only one with
       complete daily coverage — 225 of 225 days in the reporting window for
       every currency in use, with no weekend gaps. The numeric types (1000,
       1621, 1740 ...) and the Period Average / Period End variants are
       partial and inconsistent between currencies.

    2. Region is part of the key, not decoration.
       For the same currency pair and the same date, the rate DIFFERS between
       regions on 80.5% of overlapping rows. AUD -> BRL on 2025-01-01 is
       3.84344254 in AUS but 3.83922654 in EUR. Joining on currency alone
       would silently pick an arbitrary regional rate.

    3. USD and USC are identity rows, added here.
       The source carries no USD -> USD row, so it is created.
       USC ("Dolar Compra") is 1:1 with USD, evidenced three ways:
         · direct USC -> USD rows exist and read exactly 1.000000
         · BRL -> USC and BRL -> USD track each other across 591 shared
           dates with a median ratio of 1.000111 — a 0.011% difference
         · USC -> BRL is the exact reciprocal of BRL -> USC to 8 decimals
       This resolves the 2,960 USC lines that previously had no USD price.

    The spine is forward- and back-filled so every fact row resolves even
    where its date falls outside the quoted window — 1,214 order lines carry
    dates back to 2005 and 405 sit beyond the last quote.
    ========================================================================== */
let
    Source = Excel.Workbook(
        File.Contents(p_SourceFolder & "\d_exchange_rate.xlsx"), null, true),
    Sheet  = Source{[Item = "d_exchange_rate", Kind = "Sheet"]}[Data],
    Promoted = Table.PromoteHeaders(Sheet, [PromoteAllScalars = true]),

    Typed = Table.TransformColumnTypes(Promoted, {
        {"Data_Source_Region",  type text},
        {"From_Currency_Code",  type text},
        {"To_Currency_Code",    type text},
        {"Conversion_Date",     type datetime},
        {"Conversion_Rate",     type number},
        {"Status_Code",         type text}}),

    // Decision 1 — Corporate, converting into USD, confirmed rows only
    Corporate = Table.SelectRows(Typed, each
        Text.From([Conversion_Type]) = "Corporate"
        and [To_Currency_Code] = "USD"
        and [Status_Code] = "C"
        and [Conversion_Rate] <> null
        and [Conversion_Rate] > 0),

    Dated = Table.AddColumn(Corporate, "Rate_Date", each
        DateTime.Date([Conversion_Date]), type date),

    // Decision 2 — the key is currency + region + date
    Keyed = Table.AddColumn(Dated, "CurrencyKey", each
        [From_Currency_Code] & "|" & [Data_Source_Region], type text),

    // A handful of pair-date-region combinations appear more than once.
    // Median rather than first, so a stray outlier cannot win.
    Deduped = Table.Group(Keyed, {"CurrencyKey", "Rate_Date"}, {
        {"Rate_USD_per_Local", each List.Median([Conversion_Rate]), type number}}),
    TagReal = Table.AddColumn(Deduped, "Rate_Source", each "Corporate", type text),

    // Decision 3 — identity rows for USD and for USC
    Regions   = {"NAM", "EUR", "SAM", "AUS"},
    IdentCurr = {"USD", "USC"},
    DateSpan  = List.Dates(#date(2005, 1, 1),
                    Duration.Days(#date(2030, 12, 31) - #date(2005, 1, 1)) + 1,
                    #duration(1, 0, 0, 0)),
    IdentityRows = List.Combine(
        List.Transform(IdentCurr, (c) =>
            List.Combine(
                List.Transform(Regions, (r) =>
                    List.Transform(DateSpan, (dt) =>
                        [CurrencyKey        = c & "|" & r,
                         Rate_Date          = dt,
                         Rate_USD_per_Local = 1.0,
                         Rate_Source        = if c = "USD" then "Identity"
                                              else "Identity - USC is 1:1 with USD"]))))),
    Identity = Table.FromRecords(IdentityRows,
        type table [CurrencyKey = text, Rate_Date = date,
                    Rate_USD_per_Local = number, Rate_Source = text]),

    Combined = Table.Combine({TagReal, Identity}),

    // Fill every calendar day per currency-region so no fact row misses.
    // Quotes are daily with no weekend gaps, but order dates run outside the
    // quoted window at both ends.
    Keys = List.Distinct(Combined[CurrencyKey]),
    Spine = Table.Combine(
        List.Transform(Keys, (k) =>
            let
                Slice  = Table.SelectRows(Combined, each [CurrencyKey] = k),
                Sorted = Table.Sort(Slice, {{"Rate_Date", Order.Ascending}}),
                Grid   = Table.FromList(DateSpan, Splitter.SplitByNothing(), {"Rate_Date"}),
                GridT  = Table.TransformColumnTypes(Grid, {{"Rate_Date", type date}}),
                Joined = Table.NestedJoin(GridT, {"Rate_Date"}, Sorted, {"Rate_Date"},
                            "r", JoinKind.LeftOuter),
                Exp    = Table.ExpandTableColumn(Joined, "r",
                            {"Rate_USD_per_Local", "Rate_Source"}),
                Down   = Table.FillDown(Exp, {"Rate_USD_per_Local", "Rate_Source"}),
                Up     = Table.FillUp(Down,  {"Rate_USD_per_Local", "Rate_Source"}),
                AddKey = Table.AddColumn(Up, "CurrencyKey", each k, type text)
            in
                Table.SelectRows(AddKey, each [Rate_USD_per_Local] <> null))),

    Final = Table.SelectColumns(Spine,
        {"CurrencyKey", "Rate_Date", "Rate_USD_per_Local", "Rate_Source"}),
    Result = Table.TransformColumnTypes(Final, {
        {"CurrencyKey",        type text},
        {"Rate_Date",          type date},
        {"Rate_USD_per_Local", type number},
        {"Rate_Source",        type text}})
in
    Result


/*  ==========================================================================
    RELATIONSHIPS TO CREATE  (Model view — all Single direction, no exceptions)
    ==========================================================================

      FROM (1 side)              TO (* side)              KEY            ACTIVE
      ------------------------------------------------------------------------
      dim_SalesOrderLine   ->    fact_SalesOrder          LineKey        Yes  (1:1)
      dim_SalesOrderLine   ->    fact_Invoice             LineKey        Yes
      dim_SalesOrderLine   ->    fact_Shipment            LineKey        Yes
      dim_Date             ->    dim_SalesOrderLine       Ordered_Date   Yes
      dim_Date             ->    fact_Invoice             Invoice_Date   NO
      dim_Date             ->    fact_Shipment            Delivery_Confirm_Date  NO
      dim_Customer         ->    dim_SalesOrderLine       CustomerKey    Yes
      dim_Product          ->    dim_SalesOrderLine       ProductKey     Yes
      dim_Organization     ->    dim_SalesOrderLine       OrgKey         Yes
      dim_Currency         ->    dim_SalesOrderLine       CurrencyKey    Yes
      dim_ExchangeRate     ->    (no relationship - merged in Power Query)   -
      dim_ReturnReason     ->    dim_SalesOrderLine       Return_Reason  Yes
      dim_Carrier          ->    fact_Shipment            CarrierKey     Yes

    The two inactive date relationships are activated inside measures with
    USERELATIONSHIP. That is what lets "revenue by invoice month" coexist with
    "orders by order month" in the same model.

    NEVER create a relationship between two fact tables. One order line can
    carry 4 invoice lines and up to 115 shipment rows; joining them directly
    fans out and multiplies every number. The Fan Out Alert measure exists to
    catch it if someone tries.

    Turn OFF File > Options > Current File > Data Load > Autodetect new
    relationships BEFORE the first refresh, or Power BI will create exactly
    that relationship for you.
    ========================================================================== */
