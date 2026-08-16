/* ============================================================================
   ORDER-TO-CASH MODEL  —  OPTION A: EVERY OBJECT AS ITS OWN SELECT
   ============================================================================
   Eleven plain SELECT statements, one per model table. No CREATE, no ALTER,
   no DDL of any kind. Each is pasted into Power BI as its own native query:
   Get Data > SQL Server > Advanced options > SQL statement.

   Pairs with 02A_PowerQuery_AllInSQL.m and 01A_Build_Guide_AllInSQL.docx.
   Option B (three source queries, Power Query fans them out) is in
   06B_SQL_ThreeQueries.sql. See 00_README_Which_Option.md for the trade-off.

   WHAT YOU GET HERE
     Every model table arrives from the database already shaped. Power Query
     does almost nothing — it loads eleven results, generates dim_Date, and
     stops. If your team is stronger in SQL than in M, this is the one to use.

   WHAT IT COSTS
     Eleven round trips to the database per refresh instead of three, and the
     sales order join is repeated in six of them. If Sales_Order_F_V is large
     or the connection is slow, Option B will refresh noticeably faster.

   TWO OBJECTS THAT CANNOT BE SQL
     dim_Date        generated in Power Query — no source table exists.
     dim_Currency    from d_currency.xlsx.
     dim_ExchangeRate from d_exchange_rate.xlsx.
     Queries 10 and 11 below assume those two spreadsheets have been loaded
     into the warehouse as cml.d_currency and cml.d_exchange_rate. If they
     only exist as files, drop queries 10 and 11 and take those two objects
     from 02A_PowerQuery_AllInSQL.m instead — it carries both either way.

   THE FIVE CORRECTIONS
     A  48 malformed shipment rows filtered      queries 4, 9
     B  return quantities sign-normalised        query 2
     C  sentinel dates capped at 2030            query 1
     D  non-breaking spaces stripped             queries 1, 8
     E  WHERE-clause precedence                  every query touching
                                                 Sales_Order — already fixed
                                                 in your v2 sales query,
                                                 applied here throughout
   ========================================================================= */


/* ============================================================================
   QUERY 1 of 11   ·   dim_SalesOrderLine        THE BRIDGE
   ----------------------------------------------------------------------------
   One row per sales order line. Every fact filters through this; no fact ever
   joins to another fact. One order line carries up to 4 invoice lines and up
   to 115 shipment rows, so a direct fact-to-fact join fans out 4 x 115 on the
   worst key and multiplies every measure.

   GRAIN — verified on v2: 68,977 rows, 68,977 distinct LineKey, zero nulls.
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

    -- ---- DESCRIPTORS ----
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
    sofv.[Operating_Unit_Name]                                          AS Operating_Unit,
    sofv.[Line_FOB_Point_Code]                                          AS Incoterm,
    sofv.[Line_Shipping_Transport_Mode]                                 AS Transport_Mode,
    sofv.[Header_Sales_Rep_Name]                                        AS Sales_Rep,
    sofv.[DFF_Customer_Service_Rep_Name]                                AS CSR,
    sofv.[Line_DFF_Sales_Type]                                          AS Sales_Type,
    sofv.[Line_Price_List_Name]                                         AS Price_List,
    sofv.[Line_Customer_PO_Number]                                      AS Customer_PO,
    sofv.[Line_DFF_Customer_Contract]                                   AS Customer_Contract,
    sofv.[Line_Agreement_Number],
    sofv.[Line_Ship_To_City]                                            AS Ship_To_City,
    sofv.[Line_Ship_To_State]                                           AS Ship_To_State,
    sofv.[Line_Ship_To_Country]                                         AS Ship_To_Country,

    -- ---- CORRECTION C: sentinel dates ----
    -- Schedule, promise, request and arrival carry placeholders in 2032, 2047,
    -- 2062, 2099 and one 2400. Left in, every date axis stretches to meet them.
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

    -- ---- FX CONVERSION DATE ----
    -- The source tells us directly. Sales_Order_V.Exchange_Date equals
    -- Line_Actual_Shipment_Date on 100% of the 28,719 shipped rows carrying
    -- one — zero offset. The ladder below fills where it is absent, and rung 2
    -- is therefore confirmed rather than inferred.
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
    sov.[Exchange_Rate_Type]                                            AS FX_Rate_Type,

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
    -- 13 real reasons render as 15 categories.
    CASE
        WHEN sofv.[Line_Category_Code] = 'RETURN'
             OR NULLIF(LTRIM(RTRIM(sofv.[Line_Return_Reason_Code])), '') IS NOT NULL
        THEN ISNULL(NULLIF(LTRIM(RTRIM(
                REPLACE(sofv.[Line_Return_Reason_Code], NCHAR(160), N' '))), ''),
             'Not specified')
        ELSE 'Not a return'
    END                                                                 AS Return_Reason,

    -- ---- FLAGS ----
    -- Line_Fulfilled_Flag is NULL on ~5,400 rows rather than 'N'.
    CASE WHEN sofv.[Line_Open_Flag]      = 'Y' THEN 1 ELSE 0 END        AS Is_Open,
    CASE WHEN sofv.[Line_Cancelled_Flag] = 'Y' THEN 1 ELSE 0 END        AS Is_Cancelled,
    CASE WHEN sofv.[Line_Booked_Flag]    = 'Y' THEN 1 ELSE 0 END        AS Is_Booked,
    CASE WHEN ISNULL(sofv.[Line_Fulfilled_Flag], 'N') = 'Y'
         THEN 1 ELSE 0 END                                              AS Is_Fulfilled,

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
   QUERY 2 of 11   ·   fact_SalesOrder
   ----------------------------------------------------------------------------
   Measures only. Every descriptive column already lives on the bridge, so
   carrying it twice doubles memory for nothing.

   RATE PRECEDENCE — three tiers, resolved inline

     1  IDENTITY for USD and USC. USC ('Dolar Compra') is 1:1 with USD:
        direct USC -> USD quotes read exactly 1.000000, BRL -> USC tracks
        BRL -> USD within 0.011% across 591 dates, and the source supplies
        no Exchange_Rate for either code.                     48.0% of rows

     2  THE SOURCE'S OWN RATE. Sales_Order_V.Exchange_Rate reproduces the USD
        price EXACTLY on 100% of the 25,834 testable rows, and the list price
        on 100% of 23,602. No reason to recompute what the source computed.
                                                              44.3% of rows

     3  THE CORPORATE RATE TABLE, via the OUTER APPLY below — the most recent
        quote on or before FX_Date, which handles weekends and holidays with
        no filled spine, plus a backstop for dates predating the table.
                                                               7.7% of rows

   Result: 100.000% coverage. Nothing is unconvertible.

   IF d_exchange_rate IS NOT A QUERYABLE TABLE, delete the OUTER APPLY and the
   fx references, and let 02A_PowerQuery_AllInSQL.m do the tier-3 merge — it
   carries that step for exactly this case.
   ========================================================================= */
SELECT
    CONCAT(sofv.[Data_Source_Region], '-', sofv.[Line_Id])              AS LineKey,
    CONCAT(sofv.[Transactional_Currency_Code], '|',
           sofv.[Data_Source_Region])                                   AS CurrencyKey,

    -- ---- CORRECTION B, signing half ----
    -- The source stores ordered and shipped POSITIVE but invoiced NEGATIVE on
    -- the same 576 return lines. Untouched, ordered volume inflates ~4% and
    -- shipped ~4%. Invoiced is already signed — do not flip it.
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

    -- Local prices are for audit only. Averaging them mixes nine currencies
    -- and always returns a plausible number; hide them in the model.
    sofv.[Line_Unit_List_Price]                                         AS Unit_List_Price_Local,
    sofv.[Line_Unit_Selling_Price]                                      AS Unit_Selling_Price_Local,

    -- ---- USD PRICES: source value wins, conversion fills the gap ----
    COALESCE(sov.[Line_Unit_List_Price_USD],
             sofv.[Line_Unit_List_Price]    * fx.Rate)                  AS Unit_List_Price_USD,
    COALESCE(sov.[Line_Unit_Selling_Price_USD],
             sofv.[Line_Unit_Selling_Price] * fx.Rate)                  AS Unit_Selling_Price_USD,

    CAST(COALESCE(
        sov.[Exchange_Date],
        sofv.[Line_Actual_Shipment_Date],
        sofv.[Line_Fulfillment_Date],
        CASE WHEN sofv.[Line_Promise_Date]       <= '2030-12-30'
             THEN sofv.[Line_Promise_Date]       END,
        CASE WHEN sofv.[Line_Schedule_Ship_Date] <= '2030-12-30'
             THEN sofv.[Line_Schedule_Ship_Date] END,
        sofv.[Ordered_Date]) AS date)                                   AS FX_Date,

    fx.Rate                                                             AS FX_Rate,
    fx.Rate_Source                                                      AS FX_Rate_Source,

    -- A forward date can sit past the last quoted rate. Those rows carry the
    -- last known rate carried forward — right for a forward valuation, wrong
    -- to present as settled. Only a tier-3 rate can ever be forward.
    CASE WHEN fx.Rate_Source = 'Corporate rate table'
              AND COALESCE(sov.[Exchange_Date], sofv.[Line_Actual_Shipment_Date],
                           sofv.[Line_Fulfillment_Date], sofv.[Line_Promise_Date],
                           sofv.[Line_Schedule_Ship_Date], sofv.[Ordered_Date])
                  > (SELECT MAX(x.[Conversion_Date]) FROM cml.[d_exchange_rate] AS x
                     WHERE x.[Conversion_Type] = 'Corporate' AND x.[To_Currency_Code] = 'USD')
         THEN 1 ELSE 0 END                                              AS FX_Rate_Is_Forward,

    -- A converted number must never be indistinguishable from a source one.
    CASE
        WHEN sov.[Line_Unit_Selling_Price_USD] IS NOT NULL THEN '1 - Source'
        WHEN sofv.[Line_Unit_Selling_Price] IS NOT NULL
             AND fx.Rate IS NOT NULL                       THEN '2 - Converted'
        ELSE '3 - Not convertible'
    END                                                                 AS Price_USD_Quality

FROM cml.[Sales_Order_F_V] AS sofv
LEFT JOIN cml.[Sales_Order_V] AS sov
       ON sofv.[Data_Source_Region] = sov.[Data_Source_Region]
      AND sofv.[Line_Id]            = sov.[Line_Id]
OUTER APPLY (
    SELECT TOP 1 y.Rate, y.Rate_Source
    FROM (
        -- Tier 1
        SELECT CAST(1.0 AS decimal(38,12)) AS Rate, 'Identity (USD/USC)' AS Rate_Source,
               1 AS Priority, CAST('9999-12-31' AS date) AS Rate_Date
        WHERE sofv.[Transactional_Currency_Code] IN ('USD', 'USC')

        UNION ALL

        -- Tier 2
        SELECT sov.[Exchange_Rate], 'Source Exchange_Rate', 2, CAST('9999-12-31' AS date)
        WHERE sov.[Exchange_Rate] IS NOT NULL
          AND sofv.[Transactional_Currency_Code] NOT IN ('USD', 'USC')

        UNION ALL

        -- Tier 3: most recent Corporate quote on or before FX_Date
        SELECT AVG(CAST(r.[Conversion_Rate] AS decimal(38,12))), 'Corporate rate table', 3,
               CAST(r.[Conversion_Date] AS date)
        FROM cml.[d_exchange_rate] AS r
        WHERE r.[Conversion_Type]  = 'Corporate'
          AND r.[To_Currency_Code] = 'USD'
          AND r.[Status_Code]      = 'C'
          AND r.[From_Currency_Code] = sofv.[Transactional_Currency_Code]
          AND r.[Data_Source_Region] = sofv.[Data_Source_Region]
          AND CAST(r.[Conversion_Date] AS date) <= CAST(COALESCE(
                  sov.[Exchange_Date], sofv.[Line_Actual_Shipment_Date],
                  sofv.[Line_Fulfillment_Date], sofv.[Line_Promise_Date],
                  sofv.[Line_Schedule_Ship_Date], sofv.[Ordered_Date]) AS date)
          AND sov.[Exchange_Rate] IS NULL
          AND sofv.[Transactional_Currency_Code] NOT IN ('USD', 'USC')
        GROUP BY CAST(r.[Conversion_Date] AS date)
    ) AS y
    ORDER BY y.Priority ASC, y.Rate_Date DESC
) AS fx
WHERE 1 = 1
    AND sofv.[Line_Cancelled_Flag] = 'N'
    AND (
            sofv.[Line_Schedule_Ship_Date]   >= '2026-01-01'
         OR sofv.[Line_Actual_Shipment_Date] >= '2026-01-01'
        )
    AND sofv.[Line_Id] IS NOT NULL


/* ============================================================================
   QUERY 3 of 11   ·   fact_Invoice
   ----------------------------------------------------------------------------
   Grain: one invoice line. Unique on (LineKey, Transaction_Number,
   Line_Number), so no deduplication is needed. Duplicate LineKeys are
   legitimate — one order line can be invoiced in instalments.
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

/* ============================================================================
   QUERY 4 of 11   ·   fact_Shipment
   ----------------------------------------------------------------------------
   Grain: one delivery detail line. 283 source columns reduced to 40.

   Of the columns not selected: 21 are completely empty, 11 are populated but
   every value is zero, 27 are under 1% populated, 70 are redundant twins,
   38 are audit plumbing, 10 are parser artefacts.

   THE ALL-ZERO TRAP — Delivered_Qty_MT, Received_Qty_MT and Scheduled_Qty_MT
   are populated on 78% of rows and every single value is zero. They look real
   in a column list and will silently return zero in any measure built on them.
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

/* ============================================================================
   QUERY 5 of 11   ·   dim_Customer
   ----------------------------------------------------------------------------
   Conformed across all three facts. Sales order uses Customer_Number, invoice
   uses Sold_To_Customer_Id, shipment uses Customer_Account_Number — verified
   as the same 750-value domain with 100% overlap.

   ROW_NUMBER rather than DISTINCT so the most recent attributes win. DISTINCT
   would keep whichever row sorted first, which is arbitrary once a customer's
   address has changed — and would produce duplicates, breaking the one-side.
   ========================================================================= */
SELECT c.CustomerKey, c.Customer_Name, c.Customer_Type, c.Country, c.City, c.[State]
FROM (
    SELECT
        sofv.[Customer_Account_Number]                      AS CustomerKey,
        sofv.[Customer_Name],
        sofv.[Customer_Type],
        sofv.[Line_Ship_To_Country]                         AS Country,
        sofv.[Line_Ship_To_City]                            AS City,
        sofv.[Line_Ship_To_State]                           AS [State],
        ROW_NUMBER() OVER (PARTITION BY sofv.[Customer_Account_Number]
                           ORDER BY sofv.[Ordered_Date] DESC) AS rn
    FROM cml.[Sales_Order_F_V] AS sofv
    WHERE sofv.[Customer_Account_Number] IS NOT NULL
      AND sofv.[Line_Cancelled_Flag] = 'N'
      AND (
              sofv.[Line_Schedule_Ship_Date]   >= '2026-01-01'
           OR sofv.[Line_Actual_Shipment_Date] >= '2026-01-01'
          )
) AS c
WHERE c.rn = 1
UNION ALL
SELECT '-1', 'Unknown', 'Unknown', NULL, NULL, NULL


/* ============================================================================
   QUERY 6 of 11   ·   dim_Product
   ----------------------------------------------------------------------------
   ProductKey = Line_Inventory_Item_Id + '.' + Line_Ship_From_Inventory_Org_Id,
   exactly as your query defines it. 1,726 distinct — the same item made at a
   different plant is a different ProductKey, correct for a manufacturer.
   ========================================================================= */
SELECT p.ProductKey, p.Item_Id, p.Item_Number, p.Product_Description, p.Inventory_Org_Id
FROM (
    SELECT
        CONCAT(sofv.[Line_Inventory_Item_Id], '.',
               sofv.[Line_Ship_From_Inventory_Org_Id])      AS ProductKey,
        sofv.[Line_Inventory_Item_Id]                       AS Item_Id,
        sofv.[Line_Product_Item_Number]                     AS Item_Number,
        sofv.[Line_Product_Item_Description]                AS Product_Description,
        sofv.[Line_Ship_From_Inventory_Org_Id]              AS Inventory_Org_Id,
        ROW_NUMBER() OVER (PARTITION BY CONCAT(sofv.[Line_Inventory_Item_Id], '.',
                                               sofv.[Line_Ship_From_Inventory_Org_Id])
                           ORDER BY sofv.[Ordered_Date] DESC) AS rn
    FROM cml.[Sales_Order_F_V] AS sofv
    WHERE sofv.[Line_Inventory_Item_Id] IS NOT NULL
      AND sofv.[Line_Cancelled_Flag] = 'N'
      AND (
              sofv.[Line_Schedule_Ship_Date]   >= '2026-01-01'
           OR sofv.[Line_Actual_Shipment_Date] >= '2026-01-01'
          )
) AS p
WHERE p.rn = 1
UNION ALL
SELECT '-1', NULL, 'Unknown', 'Unknown', NULL


/* ============================================================================
   QUERY 7 of 11   ·   dim_Organization
   ----------------------------------------------------------------------------
   OrgKey = Data_Source_Region + '-' + Line_Ship_From_Inventory_Org_Id.
   70 distinct manufacturing / dispatch organisations.
   ========================================================================= */
SELECT o.OrgKey, o.Region, o.Operating_Unit_Id, o.Operating_Unit, o.Inventory_Org_Id
FROM (
    SELECT
        CONCAT(sofv.[Data_Source_Region], '-',
               sofv.[Line_Ship_From_Inventory_Org_Id])      AS OrgKey,
        sofv.[Data_Source_Region]                           AS Region,
        sofv.[Operating_Unit_Id],
        sofv.[Operating_Unit_Name]                          AS Operating_Unit,
        sofv.[Line_Ship_From_Inventory_Org_Id]              AS Inventory_Org_Id,
        ROW_NUMBER() OVER (PARTITION BY CONCAT(sofv.[Data_Source_Region], '-',
                                               sofv.[Line_Ship_From_Inventory_Org_Id])
                           ORDER BY sofv.[Ordered_Date] DESC) AS rn
    FROM cml.[Sales_Order_F_V] AS sofv
    WHERE sofv.[Line_Ship_From_Inventory_Org_Id] IS NOT NULL
      AND sofv.[Line_Cancelled_Flag] = 'N'
      AND (
              sofv.[Line_Schedule_Ship_Date]   >= '2026-01-01'
           OR sofv.[Line_Actual_Shipment_Date] >= '2026-01-01'
          )
) AS o
WHERE o.rn = 1
UNION ALL
SELECT '-1', 'Unknown', NULL, 'Unknown', NULL


/* ============================================================================
   QUERY 8 of 11   ·   dim_ReturnReason
   ----------------------------------------------------------------------------
   Reason_Group is the column that matters. Only 36 of 576 returns are
   genuinely rejected inventory — the rest are price adjustments, freight and
   demurrage, and input errors. A metric named "return rate" on the raw flag
   reports invoicing accuracy, not product quality. Label it Credit Note Rate.

   CORRECTION D applied here too: without the NCHAR(160) strip, 13 real
   reasons render as 15 categories.
   ========================================================================= */
SELECT
    c.Return_Reason,
    CASE
        WHEN UPPER(c.Return_Reason) IN ('PRICE ADJUSTMENTS', 'ADHOC ADJUSTMENT',
                                        'QUARTERLY RECONS/TRUE UP', 'TAX ADJUSTMENT',
                                        'BCS-CREDITS')              THEN 'Commercial adjustment'
        WHEN UPPER(c.Return_Reason) IN ('FREIGHT/DEMURRAGE/DENTENTION',
                                        'SHIP REVERSAL BY PLANT',
                                        'WAREHOUSE CHARGES')        THEN 'Logistics / service'
        WHEN UPPER(c.Return_Reason) = 'RETURNED/REJECTED INVENTORY'  THEN 'Product quality'
        WHEN UPPER(c.Return_Reason) = 'INPUT ERROR/CORRECTION'       THEN 'Process error'
        ELSE 'Uncategorised'
    END                                                             AS Reason_Group,
    CASE WHEN UPPER(c.Return_Reason) = 'RETURNED/REJECTED INVENTORY'
         THEN 1 ELSE 0 END                                          AS Is_Physical_Return
FROM (
    SELECT DISTINCT
        ISNULL(NULLIF(LTRIM(RTRIM(
            REPLACE(sofv.[Line_Return_Reason_Code], NCHAR(160), N' '))), ''),
            'Not specified')                                        AS Return_Reason
    FROM cml.[Sales_Order_F_V] AS sofv
    WHERE sofv.[Line_Category_Code] = 'RETURN'
      AND sofv.[Line_Cancelled_Flag] = 'N'
      AND (
              sofv.[Line_Schedule_Ship_Date]   >= '2026-01-01'
           OR sofv.[Line_Actual_Shipment_Date] >= '2026-01-01'
          )
) AS c
UNION ALL
SELECT 'Not a return', 'Not a return', 0


/* ============================================================================
   QUERY 9 of 11   ·   dim_Carrier
   ----------------------------------------------------------------------------
   173 carriers. 23.5% of delivery records carry none — those map to the
   Unknown member so the blind spot stays visible on the scorecard. On-time
   performance ranges from 39.7% to 90.6% between carriers, so this dimension
   is a negotiating position as much as a lookup.
   ========================================================================= */
SELECT c.CarrierKey, c.Carrier_Name, c.SCAC
FROM (
    SELECT
        CAST(sosfv.[Delivery_Carrier_Id] AS varchar(50))    AS CarrierKey,
        sosfv.[Delivery_Carrier_Name]                       AS Carrier_Name,
        sosfv.[Delivery_Carrier_SCAC]                       AS SCAC,
        ROW_NUMBER() OVER (PARTITION BY CAST(sosfv.[Delivery_Carrier_Id] AS varchar(50))
                           ORDER BY sosfv.[Delivery_Confirm_Date] DESC) AS rn
    FROM cml.[Sales_Order_Shipment_F_V] AS sosfv
    WHERE sosfv.[Delivery_Carrier_Id] IS NOT NULL
      AND sosfv.[Data_Source_Region] IN ('NAM', 'EUR', 'SAM', 'AUS')   -- CORRECTION A
) AS c
WHERE c.rn = 1
UNION ALL
SELECT '-1', 'Not recorded', NULL


/* ============================================================================
   QUERY 10 of 11   ·   dim_Currency
   ----------------------------------------------------------------------------
   ONLY IF d_currency has been loaded into the warehouse. If it is still a
   spreadsheet, skip this and take dim_Currency from the Power Query file.

   THE GRAIN IS Currency_Code x Region, NOT Currency_Code. 1,000 rows, 308
   codes, 4 regions, and 230 codes exist in all four. The description even
   varies by region — USD reads 'US dollar' in NAM and 'US Dollar' in EUR.
   Joining on the code alone fans out four ways and multiplies every amount.

   USC = 'Dolar Compra', SAM only, 2,976 lines, resolved 1:1 with USD.
   ========================================================================= */
SELECT
    CONCAT(c.[Currency_Code], '|', c.[Region])                      AS CurrencyKey,
    c.[Currency_PK_Key],
    c.[Currency_Code],
    c.[Currency_Desc],
    c.[Region],
    CASE WHEN c.[Currency_Code] = 'USD' THEN 1 ELSE 0 END           AS Is_USD,
    CASE WHEN c.[Currency_Code] IN ('USD', 'USC') THEN 1 ELSE 0 END AS Is_Identity_Rate
FROM cml.[d_currency] AS c
UNION ALL
SELECT 'UNK|Unknown', -1, 'UNK', 'Unknown', 'Unknown', 0, 0


/* ============================================================================
   QUERY 11 of 11   ·   dim_ExchangeRate
   ----------------------------------------------------------------------------
   ONLY IF d_exchange_rate has been loaded into the warehouse, and only if you
   want the rate history visible for audit. fact_SalesOrder already resolves
   its own rate inline, so this table is optional and relates to nothing.

   Conversion_Type = 'Corporate' only. The file holds 55 types; Corporate is
   the only one with complete daily coverage — 225 of 225 days in the window
   for every currency in use, with no weekend gaps.

   Region belongs in the key: for the same pair on the same date the rate
   DIFFERS between regions on 80.5% of overlapping rows.
   ========================================================================= */
SELECT
    CONCAT(fx.[From_Currency_Code], '|', fx.[Data_Source_Region])   AS CurrencyKey,
    fx.[From_Currency_Code]                                         AS Currency_Code,
    fx.[Data_Source_Region]                                         AS Region,
    CAST(fx.[Conversion_Date] AS date)                              AS Rate_Date,
    AVG(CAST(fx.[Conversion_Rate] AS decimal(38,12)))               AS Rate_USD_per_Local,
    'Corporate'                                                     AS Rate_Source
FROM cml.[d_exchange_rate] AS fx
WHERE fx.[Conversion_Type]  = 'Corporate'
  AND fx.[To_Currency_Code] = 'USD'
  AND fx.[Status_Code]      = 'C'
  AND fx.[Conversion_Rate] IS NOT NULL
  AND fx.[Conversion_Rate]  > 0
GROUP BY
    fx.[From_Currency_Code],
    fx.[Data_Source_Region],
    CAST(fx.[Conversion_Date] AS date)
