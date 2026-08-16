/* ============================================================================
   ORDER-TO-CASH MODEL  —  OPTION B: THREE SOURCE QUERIES
   ============================================================================
   Pairs with 02B_PowerQuery_ThreeQueries.m and 01B_Build_Guide_ThreeQueries.docx.
   Option A (every object as its own SELECT) is in 06A_SQL_AllObjects.sql —
   see 00_README_Which_Option.md for the trade-off.

   Three plain SELECT statements. No CREATE, no ALTER, no DDL of any kind.
   Paste each into Power BI:  Get Data > SQL Server > Advanced options >
   SQL statement, then name the query as shown in its header.

   WHY ONLY THREE
     Twelve model objects are built from three source pulls. Power Query then
     REFERENCES each pull and fans it out into the bridge, the fact and the
     dimensions that come from it. The database is queried three times per
     refresh instead of twelve, and the join logic lives in one place.

       qry_SalesOrder_Source  ->  dim_SalesOrderLine, fact_SalesOrder,
                                  dim_Customer, dim_Product,
                                  dim_Organization, dim_ReturnReason
       qry_Invoice_Source     ->  fact_Invoice
       qry_Shipment_Source    ->  fact_Shipment, dim_Carrier

     The remaining objects need no database at all: dim_Date is generated,
     dim_Currency and dim_ExchangeRate come from the two spreadsheets. All of
     that is in 02B_PowerQuery_ThreeQueries.m.

   WHAT IS DONE HERE VS IN POWER QUERY
     Here      joins, filters, key construction, string cleaning, date capping,
               flags, buckets, signed quantities — anything a single SELECT can
               do without referencing another query.
     Power BI  anything needing a second query: the FX rate merge, the
               dimension de-duplication, the calendar.

   THE FIVE CORRECTIONS
     A  48 malformed shipment rows filtered       query 3
     B  return quantities sign-normalised         query 1
     C  sentinel dates capped at 2030             query 1
     D  non-breaking spaces stripped              query 1
     E  WHERE-clause precedence                   already fixed in your v2
                                                  sales query; queries 2 and 3
                                                  still need the same brackets
                                                  and they are applied below.
   ========================================================================= */


/* ============================================================================
   QUERY 1 of 3   ·   qry_SalesOrder_Source
   ----------------------------------------------------------------------------
   Feeds six model objects. One row per sales order line — 68,977 rows,
   68,977 distinct LineKey, zero nulls on the v2 extract.

   In Power BI set this query to  Enable load = OFF.  It is a staging query;
   only the objects that reference it should load into the model.
   ========================================================================= */
SELECT
    -- ---- KEYS ----
    CONCAT(sofv.[Data_Source_Region], '-', sofv.[Line_Id])              AS LineKey,
    CONCAT(sofv.[Order_Number], '-',
           CONCAT(sofv.[Line_Number], '.', sofv.[Shipment_Number]))     AS DP_Key,
    CONCAT(sofv.[Line_Inventory_Item_Id], '.',
           sofv.[Line_Ship_From_Inventory_Org_Id])                      AS ProductKey,
    CONCAT(sofv.[Data_Source_Region], '-',
           sofv.[Line_Ship_From_Inventory_Org_Id])                      AS OrgKey,
    sofv.[Customer_Account_Number]                                      AS CustomerKey,
    -- Composite by design. d_currency is grained Currency_Code x Region and
    -- most codes exist in all four regions, so a code-only join fans out four
    -- ways and multiplies every amount it touches.
    CONCAT(sofv.[Transactional_Currency_Code], '|',
           sofv.[Data_Source_Region])                                   AS CurrencyKey,

    -- ---- DESCRIPTORS (land on dim_SalesOrderLine) ----
    sofv.[Data_Source_Region]                                           AS Region,
    sofv.[Order_Number],
    sofv.[Order_Status],
    sofv.[Order_Type_Name],
    sofv.[Line_Id],
    CONCAT(sofv.[Line_Number], '.', sofv.[Shipment_Number])             AS Line_Shipment_Num,
    sofv.[Line_Status],
    sofv.[Line_Category_Code]                                           AS Line_Category,
    sofv.[Line_Type_Name],
    sofv.[Transactional_Currency_Code]                                  AS Currency_Code,
    sofv.[Operating_Unit_Id],
    sofv.[Operating_Unit_Name]                                          AS Operating_Unit,
    sofv.[Line_Ship_From_Inventory_Org_Id]                              AS Inventory_Org_Id,
    sofv.[Line_FOB_Point_Code]                                          AS Incoterm,
    sofv.[Line_Shipping_Transport_Mode]                                 AS Transport_Mode,
    sofv.[Header_Sales_Rep_Name]                                        AS Sales_Rep,
    sofv.[DFF_Customer_Service_Rep_Name]                                AS CSR,
    sofv.[Line_DFF_Sales_Type]                                          AS Sales_Type,
    sofv.[Line_Price_List_Name]                                         AS Price_List,
    sofv.[Line_Customer_PO_Number]                                      AS Customer_PO,
    sofv.[Line_DFF_Customer_Contract]                                   AS Customer_Contract,
    sofv.[Line_Agreement_Number],

    -- ---- CUSTOMER / PRODUCT ATTRIBUTES (feed the dimensions) ----
    sofv.[Customer_Name],
    sofv.[Customer_Type],
    sofv.[Line_Ship_To_City]                                            AS Ship_To_City,
    sofv.[Line_Ship_To_State]                                           AS Ship_To_State,
    sofv.[Line_Ship_To_Country]                                         AS Ship_To_Country,
    sofv.[Line_Inventory_Item_Id]                                       AS Item_Id,
    sofv.[Line_Product_Item_Number]                                     AS Item_Number,
    sofv.[Line_Product_Item_Description]                                AS Product_Description,

    -- ---- CORRECTION C: sentinel dates ----
    -- Schedule, promise, request and arrival carry placeholders in 2032, 2047,
    -- 2062, 2099 and one 2400. Left in, every date axis stretches to meet them.
    -- Ordered_Date is never a sentinel and passes through untouched.
    CAST(sofv.[Ordered_Date]  AS date)                                  AS Ordered_Date,
    CAST(sofv.[Creation_Date] AS date)                                  AS Creation_Date,
    CASE WHEN sofv.[Line_Schedule_Ship_Date]    <= '2030-12-30'
         THEN CAST(sofv.[Line_Schedule_Ship_Date]    AS date) END       AS Schedule_Ship_Date,
    CASE WHEN sofv.[Line_Schedule_Arrival_Date] <= '2030-12-30'
         THEN CAST(sofv.[Line_Schedule_Arrival_Date] AS date) END       AS Schedule_Arrival_Date,
    CASE WHEN sofv.[Line_Promise_Date]          <= '2030-12-30'
         THEN CAST(sofv.[Line_Promise_Date]          AS date) END       AS Promise_Date,
    CASE WHEN sofv.[Line_Request_Date]          <= '2030-12-30'
         THEN CAST(sofv.[Line_Request_Date]          AS date) END       AS Request_Date,
    CAST(sofv.[Line_Actual_Shipment_Date] AS date)                      AS Actual_Shipment_Date,
    CAST(sofv.[Line_Fulfillment_Date]     AS date)                      AS Fulfillment_Date,

    -- ---- FX, straight from Sales_Order_V ----
    -- Tested on the v2 extract: Exchange_Rate reproduces the USD price EXACTLY
    -- on 100% of 25,834 rows and the list price on 100% of 23,602, and
    -- Exchange_Date equals Line_Actual_Shipment_Date on 100% of the 28,719
    -- shipped rows carrying one. Exchange_Rate_Type is 'Corporate' throughout.
    CAST(sov.[Exchange_Date] AS date)                                   AS Exchange_Date,
    sov.[Exchange_Rate],
    sov.[Exchange_Rate_Type],

    -- FX_Date: source date first, then the ladder for rows it leaves blank.
    -- Rung 2 is proven equal to rung 1 wherever both exist, which is what
    -- makes the fallback trustworthy. Distribution on the v2 extract:
    --   1 Source Exchange_Date  30,541  44.3%   4 Promise date   3,168  4.6%
    --   2 Actual shipment       30,617  44.4%   5 Scheduled ship   483  0.7%
    --   3 Fulfilment            4,168    6.0%   6 Order date         0  0.0%
    CAST(COALESCE(
        sov.[Exchange_Date],
        sofv.[Line_Actual_Shipment_Date],
        sofv.[Line_Fulfillment_Date],
        CASE WHEN sofv.[Line_Promise_Date]       <= '2030-12-30'
             THEN sofv.[Line_Promise_Date]       END,
        CASE WHEN sofv.[Line_Schedule_Ship_Date] <= '2030-12-30'
             THEN sofv.[Line_Schedule_Ship_Date] END,
        sofv.[Ordered_Date]) AS date)                                   AS FX_Date,

    CASE
        WHEN sov.[Exchange_Date]              IS NOT NULL   THEN '1 - Source Exchange_Date'
        WHEN sofv.[Line_Actual_Shipment_Date] IS NOT NULL   THEN '2 - Actual shipment'
        WHEN sofv.[Line_Fulfillment_Date]     IS NOT NULL   THEN '3 - Fulfilment'
        WHEN sofv.[Line_Promise_Date]       <= '2030-12-30' THEN '4 - Promise date (forward)'
        WHEN sofv.[Line_Schedule_Ship_Date] <= '2030-12-30' THEN '5 - Scheduled ship (forward)'
        ELSE '6 - Order date'
    END                                                                 AS FX_Date_Basis,

    -- ---- CORRECTION B, detection half ----
    -- Four indicators exist and they disagree:
    --   Line_Category_Code = 'RETURN'        576   Line_Type_Name ~ RMA   142
    --   Return_Reason_Code populated         576   Quick_RMA populated      8
    -- Every RMA row is a return but most returns are not RMA-flagged. ORing
    -- all four keeps the definition stable if the source changes which one it
    -- populates. On the v2 extract the OR still lands on exactly 576.
    CASE WHEN sofv.[Line_Category_Code] = 'RETURN'
              OR NULLIF(LTRIM(RTRIM(sofv.[Line_Return_Reason_Code])), '') IS NOT NULL
              OR UPPER(ISNULL(sofv.[Line_Type_Name], '')) LIKE '%RMA%'
              OR UPPER(ISNULL(sofv.[Line_Type_Name], '')) LIKE '%RETURN%'
              OR sofv.[Line_DFF_Quick_RMA_Original_Line_Id] IS NOT NULL
         THEN 1 ELSE 0 END                                              AS Is_Return,

    -- ---- CORRECTION D ----
    -- Trailing CHAR(160) appears in 132 of the 576 reason values, which makes
    -- 13 real reasons render as 15 categories. INPUT ERROR/CORRECTION and
    -- PRICE ADJUSTMENTS each split in two.
    CASE
        WHEN sofv.[Line_Category_Code] = 'RETURN'
             OR NULLIF(LTRIM(RTRIM(sofv.[Line_Return_Reason_Code])), '') IS NOT NULL
        THEN ISNULL(NULLIF(LTRIM(RTRIM(
                REPLACE(sofv.[Line_Return_Reason_Code], NCHAR(160), N' '))), ''),
             'Not specified')
        ELSE 'Not a return'
    END                                                                 AS Return_Reason,

    -- ---- FLAGS ----
    -- Line_Fulfilled_Flag is NULL on ~5,400 rows rather than 'N', so the
    -- ISNULL matters — without it the flag inherits the null.
    CASE WHEN sofv.[Line_Open_Flag]      = 'Y' THEN 1 ELSE 0 END        AS Is_Open,
    CASE WHEN sofv.[Line_Cancelled_Flag] = 'Y' THEN 1 ELSE 0 END        AS Is_Cancelled,
    CASE WHEN sofv.[Line_Booked_Flag]    = 'Y' THEN 1 ELSE 0 END        AS Is_Booked,
    CASE WHEN ISNULL(sofv.[Line_Fulfilled_Flag], 'N') = 'Y'
         THEN 1 ELSE 0 END                                              AS Is_Fulfilled,

    -- ---- CORRECTION B, signing half ----
    -- The source stores ordered and shipped POSITIVE but invoiced NEGATIVE on
    -- the same 576 return lines. Untouched, ordered volume inflates ~4% and
    -- shipped ~4%. Invoiced is already signed — it is passed through as is.
    CASE WHEN sofv.[Line_Category_Code] = 'RETURN'
              OR NULLIF(LTRIM(RTRIM(sofv.[Line_Return_Reason_Code])), '') IS NOT NULL
              OR UPPER(ISNULL(sofv.[Line_Type_Name], '')) LIKE '%RMA%'
              OR UPPER(ISNULL(sofv.[Line_Type_Name], '')) LIKE '%RETURN%'
         THEN -1 * ISNULL(sofv.[Line_Ordered_Qty_Metric_Ton], 0)
         ELSE      ISNULL(sofv.[Line_Ordered_Qty_Metric_Ton], 0)
    END                                                                 AS Ordered_MT_Signed,
    CASE WHEN sofv.[Line_Category_Code] = 'RETURN'
              OR NULLIF(LTRIM(RTRIM(sofv.[Line_Return_Reason_Code])), '') IS NOT NULL
              OR UPPER(ISNULL(sofv.[Line_Type_Name], '')) LIKE '%RMA%'
              OR UPPER(ISNULL(sofv.[Line_Type_Name], '')) LIKE '%RETURN%'
         THEN -1 * ISNULL(sofv.[Line_Shipped_Qty_Metric_Ton], 0)
         ELSE      ISNULL(sofv.[Line_Shipped_Qty_Metric_Ton], 0)
    END                                                                 AS Shipped_MT_Signed,
    sofv.[Line_Invoiced_Qty_Metric_Ton]                                 AS Invoiced_MT,
    sofv.[Line_Ordered_Qty]                                             AS Ordered_Qty_Native,

    -- ---- PRICES ----
    -- Local prices are for audit only. Averaging them mixes nine currencies
    -- and always returns a plausible number; they are hidden in the model.
    sofv.[Line_Unit_List_Price]                                         AS Unit_List_Price_Local,
    sofv.[Line_Unit_Selling_Price]                                      AS Unit_Selling_Price_Local,
    sov.[Line_Unit_List_Price_USD],
    sov.[Line_Unit_Selling_Price_USD],

    -- ---- DURATIONS AND BUCKETS ----
    -- Median cycle is 27 days against a mean of 56 — report the median.
    DATEDIFF(day, sofv.[Ordered_Date], sofv.[Line_Actual_Shipment_Date]) AS Days_Order_To_Ship,
    CASE WHEN sofv.[Line_Schedule_Ship_Date] <= '2030-12-30'
         THEN DATEDIFF(day, sofv.[Line_Schedule_Ship_Date],
                            sofv.[Line_Actual_Shipment_Date]) END        AS Ship_Delay_Days,

    CASE
        WHEN sofv.[Line_Actual_Shipment_Date] IS NULL
          OR sofv.[Line_Schedule_Ship_Date]   IS NULL
          OR sofv.[Line_Schedule_Ship_Date]    > '2030-12-30'                  THEN '0 - Not shipped'
        WHEN DATEDIFF(day, sofv.[Line_Schedule_Ship_Date],
                           sofv.[Line_Actual_Shipment_Date]) <= -8             THEN '1 - >7d early'
        WHEN DATEDIFF(day, sofv.[Line_Schedule_Ship_Date],
                           sofv.[Line_Actual_Shipment_Date]) <= -1             THEN '2 - 1-7d early'
        WHEN DATEDIFF(day, sofv.[Line_Schedule_Ship_Date],
                           sofv.[Line_Actual_Shipment_Date])  =  0             THEN '3 - On time'
        WHEN DATEDIFF(day, sofv.[Line_Schedule_Ship_Date],
                           sofv.[Line_Actual_Shipment_Date])  =  1             THEN '4 - 1d late'
        WHEN DATEDIFF(day, sofv.[Line_Schedule_Ship_Date],
                           sofv.[Line_Actual_Shipment_Date]) <=  7             THEN '5 - 2-7d late'
        WHEN DATEDIFF(day, sofv.[Line_Schedule_Ship_Date],
                           sofv.[Line_Actual_Shipment_Date]) <= 14             THEN '6 - 8-14d late'
        WHEN DATEDIFF(day, sofv.[Line_Schedule_Ship_Date],
                           sofv.[Line_Actual_Shipment_Date]) <= 30             THEN '7 - 15-30d late'
        ELSE '8 - 30d+ late'
    END                                                                 AS Delay_Bucket,

    CASE
        WHEN sofv.[Line_Actual_Shipment_Date] IS NULL                          THEN '0 - Not shipped'
        WHEN DATEDIFF(day, sofv.[Ordered_Date], sofv.[Line_Actual_Shipment_Date]) <=   7 THEN '1 - 0-7d'
        WHEN DATEDIFF(day, sofv.[Ordered_Date], sofv.[Line_Actual_Shipment_Date]) <=  14 THEN '2 - 8-14d'
        WHEN DATEDIFF(day, sofv.[Ordered_Date], sofv.[Line_Actual_Shipment_Date]) <=  21 THEN '3 - 15-21d'
        WHEN DATEDIFF(day, sofv.[Ordered_Date], sofv.[Line_Actual_Shipment_Date]) <=  30 THEN '4 - 22-30d'
        WHEN DATEDIFF(day, sofv.[Ordered_Date], sofv.[Line_Actual_Shipment_Date]) <=  45 THEN '5 - 31-45d'
        WHEN DATEDIFF(day, sofv.[Ordered_Date], sofv.[Line_Actual_Shipment_Date]) <=  60 THEN '6 - 46-60d'
        WHEN DATEDIFF(day, sofv.[Ordered_Date], sofv.[Line_Actual_Shipment_Date]) <=  90 THEN '7 - 61-90d'
        WHEN DATEDIFF(day, sofv.[Ordered_Date], sofv.[Line_Actual_Shipment_Date]) <= 120 THEN '8 - 91-120d'
        ELSE '9 - 120d+'
    END                                                                 AS Cycle_Bucket,

    CAST(sofv.[EDW_Update_Datetime] AS date)                            AS Last_Update

FROM cml.[Sales_Order_F_V] AS sofv
LEFT JOIN cml.[Sales_Order_V] AS sov
       ON sofv.[Data_Source_Region] = sov.[Data_Source_Region]
      AND sofv.[Line_Id]            = sov.[Line_Id]
WHERE 1 = 1
    /* ---- CORRECTION E — already applied in your v2 query -------------------
       The brackets are what make the cancelled filter bind. Without them AND
       binds tighter than OR and SQL evaluates
           (cancelled = 'N' AND schedule >= X) OR (actual >= X)
       bypassing every filter left of the OR. Confirmed fixed: cancelled lines
       went 39 -> 0 and the extract grew 68,469 -> 68,977 rows. Keep them.
       --------------------------------------------------------------------- */
    AND sofv.[Line_Cancelled_Flag] = 'N'
    AND (
            sofv.[Line_Schedule_Ship_Date]   >= '2026-01-01'
         OR sofv.[Line_Actual_Shipment_Date] >= '2026-01-01'
        )
    AND sofv.[Line_Id] IS NOT NULL


/* ============================================================================
   QUERY 2 of 3   ·   qry_Invoice_Source
   ----------------------------------------------------------------------------
   Feeds fact_Invoice only. One row per invoice line — unique on
   (LineKey, Transaction_Number, Line_Number), so no deduplication is needed.
   Duplicate LineKeys are legitimate: one order line can be invoiced in
   instalments.

   Enable load = OFF. fact_Invoice references this.
   ========================================================================= */
SELECT
    CONCAT(ctfv.[Data_Source_Region], '-', ctfv.[Line_DFF_Order_Line_Id])   AS LineKey,
    CONCAT(ctfv.[Transaction_Number], '.', ctfv.[Line_Number])              AS Invoice_Number,
    ctfv.[Transaction_Number],
    ctfv.[Line_Number],
    ctfv.[Data_Source_Region]                                               AS Region,
    CAST(ctfv.[Transaction_Date] AS date)                                   AS Invoice_Date,
    CAST(ctfv.[Ship_Date_Actual] AS date)                                   AS Ship_Date_Actual,
    CAST(ctfv.[Batch_GL_Date]    AS date)                                   AS Batch_GL_Date,
    ctfv.[Legal_Entity_Name]                                                AS Legal_Entity,
    ctfv.[Operating_Unit_Name]                                              AS Operating_Unit,
    ctfv.[Term_Name],
    ctfv.[FOB_Point]                                                        AS Incoterm,
    ctfv.[Transaction_Type],
    ctfv.[Transaction_Status],
    ctfv.[Sold_To_Customer_Id]                                              AS Sold_To_CustomerKey,

    -- ---- CREDIT MEMO DETECTION ----
    -- Credit memos are a separate, larger population than sales-order returns.
    -- Only 475 invoice lines tie back to a return order; 4,925 are credits.
    -- Filtering the invoice fact by the SO return flag finds under 10% of them.
    -- Verified: this rule leaves exactly zero negative revenue outside it.
    CASE WHEN UPPER(ISNULL(ctfv.[Transaction_Type], '')) LIKE '%CM%'
              OR UPPER(ISNULL(ctfv.[Transaction_Type], '')) LIKE '%CRD%'
              OR UPPER(ISNULL(ctfv.[Transaction_Type], '')) LIKE '%[_]NC%'
              OR ISNULL(ctfv.[Line_Revenue_Amount_USD], 0) < 0
              OR ctfv.[Line_Quantity_Credited_MT] IS NOT NULL
         THEN 1 ELSE 0 END                                                  AS Is_Credit_Memo,

    CASE WHEN UPPER(ISNULL(ctfv.[Transaction_Type], '')) LIKE '%CM%'
              OR UPPER(ISNULL(ctfv.[Transaction_Type], '')) LIKE '%CRD%'
              OR UPPER(ISNULL(ctfv.[Transaction_Type], '')) LIKE '%[_]NC%'
              OR ISNULL(ctfv.[Line_Revenue_Amount_USD], 0) < 0
              OR ctfv.[Line_Quantity_Credited_MT] IS NOT NULL
         THEN 'Credit memo' ELSE 'Invoice' END                              AS Transaction_Category,

    -- The premium breakdown is populated on NAM and EUR lines only — 76.2% of
    -- rows, 78.3% of revenue. SAM and AUS carry none, so any bridge visual
    -- must filter on this flag or it silently reports on part of the business.
    CASE WHEN ctpfv.[Line_Base_Amount] IS NOT NULL THEN 1 ELSE 0 END        AS Has_Price_Bridge,

    -- ---- MEASURES ----
    ctfv.[Line_Revenue_Amount_USD]                                          AS Revenue_USD,
    -- These two are MUTUALLY EXCLUSIVE: of the 4,569 rows carrying a credited
    -- quantity, not one carries an invoiced quantity. Any net volume measure
    -- must add both — summing only the first silently drops every credit.
    ctfv.[Line_Quantity_Invoiced_MT]                                        AS Qty_Invoiced_MT,
    ctfv.[Line_Quantity_Credited_MT]                                        AS Qty_Credited_MT,
    ctfv.[Line_Unit_Selling_Price_USD]                                      AS Unit_Selling_Price_USD,
    ctfv.[Line_Unit_Standard_Price_USD]                                     AS Unit_Standard_Price_USD,

    -- ---- PRICE BRIDGE ----
    -- Reconciles to realised price within 0.71% on covered rows.
    ctpfv.[Line_Base_Amount]                                                AS Base_Amount,
    ctpfv.[Line_Regional_Premium_Amount]                                    AS Regional_Premium,
    ctpfv.[Line_Product_Premium_Amount]                                     AS Product_Premium,
    ctpfv.[Line_Green_Premium_Amount]                                       AS Green_Premium,
    ctpfv.[Line_Other_Premium_Amount]                                       AS Other_Premium,
    ctpfv.[Line_Tariff_Amount]                                              AS Tariff_Amount,
    ctpfv.[Line_Alloy_Amount]                                               AS Alloy_Amount

FROM cml.[Customer_Transaction_F_V] AS ctfv
LEFT JOIN cml.[Sales_Order_V] AS sov
       ON ctfv.[Data_Source_Region]     = sov.[Data_Source_Region]
      AND ctfv.[Line_DFF_Order_Line_Id] = sov.[Line_Id]
LEFT JOIN cml.[Customer_Transaction_Price_F_V] AS ctpfv
       ON ctfv.[Data_Source_Region] = ctpfv.[Data_Source_Region]
      AND ctfv.[Transaction_Id]     = ctpfv.[Transaction_Id]
      AND ctfv.[Line_Id]            = ctpfv.[Line_Id]
WHERE 1 = 1
    AND ctfv.[Line_Type] = 'LINE'
    -- CORRECTION E — your invoice query still has the unbracketed version.
    -- These brackets are the fix.
    AND (
            sov.[Line_Schedule_Ship_Date]   >= '2026-01-01'
         OR sov.[Line_Actual_Shipment_Date] >= '2026-01-01'
        )


/* ============================================================================
   QUERY 3 of 3   ·   qry_Shipment_Source
   ----------------------------------------------------------------------------
   Feeds fact_Shipment and dim_Carrier. One row per delivery detail line.
   283 source columns reduced to 40.

   Of the columns not selected: 21 are completely empty, 11 are populated but
   every value is zero, 27 are under 1% populated, 70 are redundant twins,
   38 are audit plumbing, 10 are parser artefacts.

   THE ALL-ZERO TRAP — Delivered_Qty_MT, Received_Qty_MT and Scheduled_Qty_MT
   are populated on 78% of rows and every single value is zero. They look real
   in a column list and will silently return zero in any measure built on them.
   Excluded deliberately; delivery-confirmation KPIs are blocked, not broken.

   Enable load = OFF.
   ========================================================================= */
SELECT
    CONCAT(sosfv.[Data_Source_Region], '-',
           sosfv.[Delivery_Detail_Source_Line_Id])                      AS LineKey,
    CONCAT(sosfv.[Delivery_Id], '-', sosfv.[Trip_Id])                   AS TripKey,
    sosfv.[Data_Source_Region]                                          AS Region,
    sosfv.[Delivery_Id],
    sosfv.[Trip_Id],
    sosfv.[Delivery_Name],
    sosfv.[Trip_Name],

    -- 23.5% of delivery records carry no carrier at all. Mapping the null to
    -- the Unknown member keeps that blind spot visible on the scorecard
    -- instead of quietly shrinking the denominator.
    ISNULL(CAST(sosfv.[Delivery_Carrier_Id] AS varchar(50)), '-1')      AS CarrierKey,
    sosfv.[Delivery_Carrier_Name]                                       AS Carrier_Name,
    sosfv.[Delivery_Carrier_SCAC]                                       AS Carrier_SCAC,

    sosfv.[Delivery_Mode_Of_Transport]                                  AS Mode_Of_Transport,
    sosfv.[Delivery_Service_Level]                                      AS Service_Level,
    sosfv.[Delivery_Detail_Released_Status]                             AS Released_Status,
    sosfv.[Delivery_Status],
    sosfv.[Trip_Status],
    sosfv.[Delivery_Detail_Customer_PO_Number]                          AS Customer_PO,
    sosfv.[Delivery_Bill_Of_Lading_Number]                              AS BOL_Number,
    sosfv.[Delivery_Freight_Terms_Code]                                 AS Freight_Terms,
    sosfv.[Delivery_FOB_Code]                                           AS FOB_Code,
    sosfv.[Ship_From_Organization_Code]                                 AS Ship_From_Site,
    sosfv.[Ship_From_Country],
    sosfv.[Ship_To_Country],
    sosfv.[Delivery_Detail_Ship_To_Location_Id]                         AS Ship_To_LocationKey,

    -- ---- DATES ----
    CAST(sosfv.[Delivery_Confirm_Date]                    AS date)      AS Delivery_Confirm_Date,
    CAST(sosfv.[Delivery_Detail_Date_Requested]           AS date)      AS Date_Requested,
    CAST(sosfv.[Delivery_Detail_Date_Scheduled]           AS date)      AS Date_Scheduled,
    sosfv.[Trip_Stop_Pick_Up_Planned_Arrival_Date]                      AS Planned_Pickup,
    sosfv.[Trip_Stop_Pick_Up_Actual_Arrival_Date]                       AS Actual_Pickup,
    sosfv.[Trip_Stop_Drop_Off_Planned_Arrival_Date]                     AS Planned_Arrival,
    sosfv.[Trip_Stop_Drop_Off_Actual_Arrival_Date]                      AS Actual_Arrival,
    sosfv.[Trip_Stop_Drop_Off_Actual_Departure_Date]                    AS Actual_Departure,

    -- ---- MEASURES ----
    sosfv.[Delivery_Detail_Shipped_Qty_MT]                              AS Shipped_MT,
    sosfv.[Delivery_Detail_Requested_Qty_MT]                            AS Requested_MT,
    sosfv.[Delivery_Detail_Src_Requested_Qty_MT]                        AS Src_Requested_MT,
    sosfv.[Delivery_Detail_Picked_Qty_MT]                               AS Picked_MT,
    sosfv.[Delivery_Detail_Cancelled_Qty_MT]                            AS Cancelled_MT,
    sosfv.[Delivery_Gross_Weight_MT]                                    AS Gross_Weight_MT,
    sosfv.[Delivery_Net_Weight_MT]                                      AS Net_Weight_MT,
    sosfv.[Delivery_Detail_Ship_Tolerance_Above]                        AS Tolerance_Above_Pct,
    sosfv.[Delivery_Detail_Ship_Tolerance_Below]                        AS Tolerance_Below_Pct,

    -- ---- DERIVED ----
    -- Transit time is NOT derivable: trip stop arrival and departure carry
    -- identical timestamps, so computed transit is 0.00 days across 63,969
    -- rows. Delay against plan is the usable measure.
    DATEDIFF(day, sosfv.[Trip_Stop_Drop_Off_Planned_Arrival_Date],
                  sosfv.[Trip_Stop_Drop_Off_Actual_Arrival_Date])       AS Delivery_Delay_Days,
    CASE WHEN sosfv.[Ship_From_Country] <> sosfv.[Ship_To_Country]
         THEN 1 ELSE 0 END                                              AS Is_Export

FROM cml.[Sales_Order_Shipment_F_V] AS sosfv
LEFT JOIN cml.[Sales_Order_V] AS sov
       ON sosfv.[Data_Source_Region]             = sov.[Data_Source_Region]
      AND sosfv.[Delivery_Detail_Source_Line_Id] = sov.[Line_Id]
WHERE 1 = 1
    /* ---- CORRECTION A — the single most important predicate in this file ---
       48 rows have shifted columns, leaving values like 'PER2', '9.6' and
       'XPO1' in Data_Source_Region and pushing data into trailing columns.
       Left in they report 282.5m MT against a true 21.2m MT — one row alone
       contributes 39.5m. Costs at most 3 valid LineKeys.

       Root cause is almost certainly an unescaped comma or embedded newline
       in a text field upstream. Worth fixing there, since the same defect
       recurs on every refresh and may next time land on rows without an
       obviously wrong region value.
       --------------------------------------------------------------------- */
    AND sosfv.[Data_Source_Region] IN ('NAM', 'EUR', 'SAM', 'AUS')
    AND sosfv.[Delivery_Detail_Released_Status] <> 'Cancelled'
    -- CORRECTION E — brackets, so the status filter above actually applies
    AND (
            sov.[Line_Schedule_Ship_Date]   >= '2026-01-01'
         OR sov.[Line_Actual_Shipment_Date] >= '2026-01-01'
        )
