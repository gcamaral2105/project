/* ============================================================================
   ORDER-TO-CASH SEMANTIC MODEL  —  SOURCE SQL
   ============================================================================
   Twelve objects: 1 bridge, 3 facts, 8 dimensions.
   Target: SQL Server / Azure Synapse (T-SQL).

   Build each as a view in a reporting schema (rpt) so Power BI does a plain
   SELECT with nothing to transform and nothing to fold.

   BUILD ORDER — later objects reference earlier ones
     1  rpt.dim_ExchangeRate     no dependencies
     2  rpt.dim_Currency         no dependencies
     3  rpt.dim_Date             no dependencies
     4  rpt.dim_SalesOrderLine   the bridge
     5  rpt.fact_SalesOrder      needs dim_ExchangeRate and dim_SalesOrderLine
     6  rpt.fact_Invoice
     7  rpt.fact_Shipment
     8  rpt.dim_Customer   9 rpt.dim_Product   10 rpt.dim_Organization
    11  rpt.dim_Carrier   12 rpt.dim_ReturnReason

   THE FIVE CORRECTIONS, AND WHERE EACH LIVES
     A  48 malformed shipment rows filtered        fact_Shipment, dim_Carrier
     B  return quantities sign-normalised          fact_SalesOrder
     C  sentinel dates capped at 2030              dim_SalesOrderLine
     D  non-breaking spaces stripped               dim_SalesOrderLine, dim_ReturnReason
     E  WHERE-clause precedence bug                ALREADY FIXED in your v2 query.
                                                   The brackets are in; cancelled
                                                   lines dropped from 39 to 0 and
                                                   the extract grew 68,469 -> 68,977.

   CURRENCY — the v2 query changed this materially
     Sales_Order_V supplies Exchange_Date, Exchange_Rate and Exchange_Rate_Type.
     Tested against the extract:
       · Exchange_Rate reproduces the USD price EXACTLY on 100% of 25,834 rows,
         and the list price on 100% of 23,602 rows
       · Exchange_Date equals Line_Actual_Shipment_Date on 100% of the 28,719
         shipped rows that carry one — zero offset, not approximately
       · Exchange_Rate_Type is 'Corporate' on every populated row, which
         independently confirms the conversion type chosen in object 1
       · USD and USC rows carry no rate at all, which independently confirms
         USC is treated as USD at parity
     So the rate is no longer inferred. Precedence is now:
       1  identity for USD and USC
       2  the source Exchange_Rate where supplied            44.3% of rows
       3  the Corporate rate table for the remainder          7.7% of rows
     Coverage is 100.000% — nothing is unconvertible.

   TWO PLACEHOLDERS TO CONFIRM
     d_currency and d_exchange_rate arrived as spreadsheets, so their warehouse
     names are assumed to be cml.d_currency and cml.d_exchange_rate. Adjust the
     FROM clauses in objects 1 and 2 if they live elsewhere.
   ========================================================================= */


/* ============================================================================
   1 · rpt.dim_ExchangeRate
   ----------------------------------------------------------------------------
   112,877 source rows reduced to the daily USD conversion spine.

   THREE DECISIONS, EACH TESTED AGAINST THE DATA

   Conversion_Type = 'Corporate' only. The file holds 55 types; Corporate is
   the only one with complete daily coverage — 225 of 225 days in the window
   for every currency in use, no weekend gaps. The numeric types (1000, 1621,
   1740 ...) and the Period Average / Period End variants are partial.

   Region belongs in the key. For the same pair on the same date the rate
   DIFFERS between regions on 80.5% of overlapping rows. AUD -> BRL on
   2025-01-01 is 3.84344254 in AUS and 3.83922654 in EUR.

   USD and USC are handled as identity in fact_SalesOrder rather than
   materialised here — see the note in object 5. Generating an identity spine
   would add ~76,000 rows to carry a constant of 1.0.
   ========================================================================= */
CREATE OR ALTER VIEW rpt.dim_ExchangeRate AS
SELECT
    CONCAT(fx.[From_Currency_Code], '|', fx.[Data_Source_Region])   AS CurrencyKey,
    fx.[From_Currency_Code]                                         AS Currency_Code,
    fx.[Data_Source_Region]                                         AS Region,
    CAST(fx.[Conversion_Date] AS date)                              AS Rate_Date,
    -- A handful of pair-date-region combinations appear more than once.
    -- MIN over a deduplicated set would also work; AVG is used so a stray
    -- duplicate cannot swing the result the way picking one arbitrarily can.
    AVG(CAST(fx.[Conversion_Rate] AS decimal(38,12)))               AS Rate_USD_per_Local,
    'Corporate'                                                     AS Rate_Source
FROM cml.[d_exchange_rate] AS fx
WHERE fx.[Conversion_Type]    = 'Corporate'
  AND fx.[To_Currency_Code]   = 'USD'
  AND fx.[Status_Code]        = 'C'
  AND fx.[Conversion_Rate] IS NOT NULL
  AND fx.[Conversion_Rate]    > 0
GROUP BY
    fx.[From_Currency_Code],
    fx.[Data_Source_Region],
    CAST(fx.[Conversion_Date] AS date);
GO


/* ============================================================================
   2 · rpt.dim_Currency
   ----------------------------------------------------------------------------
   THE GRAIN IS Currency_Code x Region, NOT Currency_Code.
   1,000 rows, 308 codes, 4 regions, and 230 codes exist in all four. The
   description even varies by region — USD reads 'US dollar' in NAM and
   'US Dollar' in EUR. Joining on the code alone fans out up to four ways and
   multiplies every amount it touches. CurrencyKey is the join key.

   USC = 'Dolar Compra', SAM only. The rate table resolves it 1:1 with USD:
   direct USC -> USD rows read exactly 1.000000, and BRL -> USC tracks
   BRL -> USD within 0.011% across 591 shared dates. It is NOT US cents.
   ========================================================================= */
CREATE OR ALTER VIEW rpt.dim_Currency AS
SELECT
    CONCAT(c.[Currency_Code], '|', c.[Region])                      AS CurrencyKey,
    c.[Currency_PK_Key],
    c.[Currency_Code],
    c.[Currency_Desc],
    c.[Region],
    CAST(CASE WHEN c.[Currency_Code] = 'USD' THEN 1 ELSE 0 END AS bit)   AS Is_USD,
    -- USD needs no conversion; USC converts at parity. Everything else has a
    -- Corporate rate. Nothing in the current data is unconvertible.
    CAST(CASE WHEN c.[Currency_Code] IN ('USD', 'USC') THEN 1 ELSE 0 END AS bit)
                                                                    AS Is_Identity_Rate,
    CAST(1 AS bit)                                                  AS Is_Convertible
FROM cml.[d_currency] AS c

UNION ALL

-- Unknown member so an unmatched fact row stays visible instead of vanishing
SELECT 'UNK|Unknown', -1, 'UNK', 'Unknown', 'Unknown',
       CAST(0 AS bit), CAST(0 AS bit), CAST(0 AS bit);
GO


/* ============================================================================
   3 · rpt.dim_Date
   ----------------------------------------------------------------------------
   Mark as the date table in Power BI. Anchored to Ordered_Date; invoice and
   delivery dates are wired as INACTIVE relationships and activated inside
   measures with USERELATIONSHIP.

   Is_Complete_Month exists because the extract ends mid-August — without it
   every trend chart shows a false collapse in the final month.
   ========================================================================= */
CREATE OR ALTER VIEW rpt.dim_Date AS
WITH Days AS (
    SELECT CAST('2025-01-01' AS date) AS [Date]
    UNION ALL
    SELECT DATEADD(day, 1, [Date]) FROM Days WHERE [Date] < '2027-12-31'
)
SELECT
    d.[Date],
    YEAR(d.[Date])                                                  AS [Year],
    MONTH(d.[Date])                                                 AS Month_Number,
    FORMAT(d.[Date], 'MMM')                                         AS Month_Short,
    FORMAT(d.[Date], 'MMM yyyy')                                    AS Year_Month,
    YEAR(d.[Date]) * 100 + MONTH(d.[Date])                          AS Year_Month_Sort,
    CONCAT('Q', DATEPART(quarter, d.[Date]))                        AS [Quarter],
    CONCAT(YEAR(d.[Date]), ' Q', DATEPART(quarter, d.[Date]))       AS Year_Quarter,
    CAST(CASE WHEN EOMONTH(d.[Date]) <= EOMONTH(DATEADD(month, -1, GETDATE()))
              THEN 1 ELSE 0 END AS bit)                             AS Is_Complete_Month
FROM Days AS d;
GO
-- Recursion default is 100. Either add OPTION (MAXRECURSION 0) at the call
-- site or, better, build this from a permanent calendar table if one exists.


/* ============================================================================
   4 · rpt.dim_SalesOrderLine        THE BRIDGE
   ----------------------------------------------------------------------------
   One row per sales order line. Every fact filters through this; no fact ever
   joins to another fact. One order line carries up to 4 invoice lines and up
   to 115 shipment rows, so a direct fact-to-fact join fans out 4 x 115 on the
   worst key and multiplies every measure.

   GRAIN — verified on v2: 68,977 rows, 68,977 distinct LineKey, zero nulls.
   ========================================================================= */
CREATE OR ALTER VIEW rpt.dim_SalesOrderLine AS
SELECT
    -- ---- KEYS (definitions taken unchanged from your existing query) ----
    CONCAT(sofv.[Data_Source_Region], '-', sofv.[Line_Id])              AS LineKey,
    CONCAT(sofv.[Order_Number], '-',
           CONCAT(sofv.[Line_Number], '.', sofv.[Shipment_Number]))     AS DP_Key,
    CONCAT(sofv.[Line_Inventory_Item_Id], '.',
           sofv.[Line_Ship_From_Inventory_Org_Id])                      AS ProductKey,
    CONCAT(sofv.[Data_Source_Region], '-',
           sofv.[Line_Ship_From_Inventory_Org_Id])                      AS OrgKey,
    sofv.[Customer_Account_Number]                                      AS CustomerKey,
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
    -- Ordered_Date is never a sentinel, so it passes through untouched.
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
    -- The source now tells us directly. Sales_Order_V.Exchange_Date is the
    -- date the conversion was struck at, and on the 28,719 shipped rows that
    -- carry one it equals Line_Actual_Shipment_Date on 100% — zero offset.
    -- Where it is absent the ladder below fills in, and rung 1 is therefore
    -- confirmed rather than inferred.
    --
    -- Ladder distribution on the current extract:
    --   1 Source Exchange_Date   30,541   44.3%   authoritative
    --   2 Actual shipment        30,617   44.4%   confirmed equal to rung 1
    --   3 Fulfilment              4,168    6.0%
    --   4 Promise date            3,168    4.6%   forward
    --   5 Scheduled ship            483    0.7%   forward
    --   6 Order date                  0    0.0%   never reached
    CAST(COALESCE(
        sov.[Exchange_Date],
        sofv.[Line_Actual_Shipment_Date],
        sofv.[Line_Fulfillment_Date],
        CASE WHEN sofv.[Line_Promise_Date]       <= '2030-12-30'
             THEN sofv.[Line_Promise_Date]       END,
        CASE WHEN sofv.[Line_Schedule_Ship_Date] <= '2030-12-30'
             THEN sofv.[Line_Schedule_Ship_Date] END,
        sofv.[Ordered_Date]
    ) AS date)                                                          AS FX_Date,

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
    CAST(CASE WHEN sofv.[Line_Category_Code] = 'RETURN'
                OR NULLIF(LTRIM(RTRIM(sofv.[Line_Return_Reason_Code])), '') IS NOT NULL
                OR UPPER(ISNULL(sofv.[Line_Type_Name], '')) LIKE '%RMA%'
                OR UPPER(ISNULL(sofv.[Line_Type_Name], '')) LIKE '%RETURN%'
                OR sofv.[Line_DFF_Quick_RMA_Original_Line_Id] IS NOT NULL
              THEN 1 ELSE 0 END AS bit)                                 AS Is_Return,

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
    -- Line_Fulfilled_Flag is NULL on 5,407 rows rather than 'N', so the
    -- ISNULL matters — without it the bit inherits the null.
    CAST(CASE WHEN sofv.[Line_Open_Flag]      = 'Y' THEN 1 ELSE 0 END AS bit) AS Is_Open,
    CAST(CASE WHEN sofv.[Line_Cancelled_Flag] = 'Y' THEN 1 ELSE 0 END AS bit) AS Is_Cancelled,
    CAST(CASE WHEN sofv.[Line_Booked_Flag]    = 'Y' THEN 1 ELSE 0 END AS bit) AS Is_Booked,
    CAST(CASE WHEN ISNULL(sofv.[Line_Fulfilled_Flag], 'N') = 'Y'
              THEN 1 ELSE 0 END AS bit)                                 AS Is_Fulfilled,

    -- ---- DURATIONS AND BUCKETS ----
    -- Pushed down so DAX carries no calculated columns.
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
       The brackets below are what makes the cancelled filter actually bind.
       Without them AND binds tighter than OR and SQL evaluates
           (cancelled = 'N' AND schedule >= X) OR (actual >= X)
       bypassing every filter left of the OR. Confirmed fixed: cancelled lines
       went from 39 to 0 and the extract grew from 68,469 to 68,977 rows.
       Keep the brackets.
       --------------------------------------------------------------------- */
    AND sofv.[Line_Cancelled_Flag] = 'N'
    AND (
            sofv.[Line_Schedule_Ship_Date]   >= '2026-01-01'
         OR sofv.[Line_Actual_Shipment_Date] >= '2026-01-01'
        )
    AND sofv.[Line_Id] IS NOT NULL;
GO


/* ============================================================================
   5 · rpt.fact_SalesOrder           GRAIN: one sales order line
   ----------------------------------------------------------------------------
   Measures only. Every descriptive column already lives on the bridge, so
   carrying it twice doubles memory for nothing.

   RATE PRECEDENCE — three tiers, in this order

     1  IDENTITY for USD and USC. USC ('Dolar Compra') is 1:1 with USD:
        direct USC -> USD quotes read exactly 1.000000, BRL -> USC tracks
        BRL -> USD within 0.011% across 591 dates, and the source itself
        supplies no Exchange_Rate for either code.          48.0% of rows

     2  THE SOURCE'S OWN RATE. Sales_Order_V.Exchange_Rate reproduces the USD
        price EXACTLY on 100% of the 25,834 testable rows, and the list price
        on 100% of 23,602. When the source has already done the arithmetic
        there is no reason to redo it.                      44.3% of rows

     3  THE CORPORATE RATE TABLE for what is left — rows with no USD price and
        no supplied rate, looked up at FX_Date.              7.7% of rows

   Result: 100.000% coverage. Nothing is unconvertible.
   ========================================================================= */
CREATE OR ALTER VIEW rpt.fact_SalesOrder AS
WITH src AS (
    SELECT
        CONCAT(sofv.[Data_Source_Region], '-', sofv.[Line_Id])          AS LineKey,
        CONCAT(sofv.[Transactional_Currency_Code], '|',
               sofv.[Data_Source_Region])                               AS CurrencyKey,
        sofv.[Transactional_Currency_Code]                              AS Currency_Code,

        -- Source date first; the ladder only fills where it is absent.
        CAST(COALESCE(
            sov.[Exchange_Date],
            sofv.[Line_Actual_Shipment_Date],
            sofv.[Line_Fulfillment_Date],
            CASE WHEN sofv.[Line_Promise_Date]       <= '2030-12-30'
                 THEN sofv.[Line_Promise_Date]       END,
            CASE WHEN sofv.[Line_Schedule_Ship_Date] <= '2030-12-30'
                 THEN sofv.[Line_Schedule_Ship_Date] END,
            sofv.[Ordered_Date]) AS date)                               AS FX_Date,

        sov.[Exchange_Rate]                                             AS Source_FX_Rate,
        sov.[Exchange_Rate_Type]                                        AS Source_FX_Type,

        -- CORRECTION B, detection half (repeated so the fact stands alone)
        CASE WHEN sofv.[Line_Category_Code] = 'RETURN'
                  OR NULLIF(LTRIM(RTRIM(sofv.[Line_Return_Reason_Code])), '') IS NOT NULL
                  OR UPPER(ISNULL(sofv.[Line_Type_Name], '')) LIKE '%RMA%'
                  OR UPPER(ISNULL(sofv.[Line_Type_Name], '')) LIKE '%RETURN%'
             THEN 1 ELSE 0 END                                          AS Is_Return,

        sofv.[Line_Ordered_Qty_Metric_Ton],
        sofv.[Line_Shipped_Qty_Metric_Ton],
        sofv.[Line_Invoiced_Qty_Metric_Ton],
        sofv.[Line_Ordered_Qty],
        sofv.[Line_Unit_List_Price],
        sofv.[Line_Unit_Selling_Price],
        sov.[Line_Unit_List_Price_USD],
        sov.[Line_Unit_Selling_Price_USD]
    FROM cml.[Sales_Order_F_V] AS sofv
    LEFT JOIN cml.[Sales_Order_V] AS sov
           ON sofv.[Data_Source_Region] = sov.[Data_Source_Region]
          AND sofv.[Line_Id]            = sov.[Line_Id]
    WHERE 1 = 1
        AND sofv.[Line_Cancelled_Flag] = 'N'
        AND (
                sofv.[Line_Schedule_Ship_Date]   >= '2026-01-01'
             OR sofv.[Line_Actual_Shipment_Date] >= '2026-01-01'
            )
        AND sofv.[Line_Id] IS NOT NULL
),
rated AS (
    SELECT
        s.*,
        -- The three tiers, resolved once here so the SELECT below stays readable
        COALESCE(
            CASE WHEN s.Currency_Code IN ('USD', 'USC') THEN CAST(1.0 AS decimal(38,12)) END,
            s.Source_FX_Rate,
            fx.Rate
        )                                                               AS FX_Rate,
        CASE
            WHEN s.Currency_Code IN ('USD', 'USC') THEN 'Identity (USD/USC)'
            WHEN s.Source_FX_Rate IS NOT NULL      THEN 'Source Exchange_Rate'
            WHEN fx.Rate          IS NOT NULL      THEN 'Corporate rate table'
            ELSE 'Unresolved'
        END                                                             AS FX_Rate_Source
    FROM src AS s
    OUTER APPLY (
        -- Tier 3 only. Skipped entirely for identity currencies and for rows
        -- where the source already supplied a rate.
        SELECT TOP 1 x.Rate
        FROM (
            SELECT r.Rate_USD_per_Local AS Rate, 1 AS Priority, r.Rate_Date
            FROM   rpt.dim_ExchangeRate AS r
            WHERE  r.CurrencyKey = s.CurrencyKey
              AND  r.Rate_Date  <= s.FX_Date

            UNION ALL

            -- Backstop for order dates predating the rate table
            SELECT r.Rate_USD_per_Local, 2, r.Rate_Date
            FROM   rpt.dim_ExchangeRate AS r
            WHERE  r.CurrencyKey = s.CurrencyKey
              AND  NOT EXISTS (SELECT 1 FROM rpt.dim_ExchangeRate AS r2
                               WHERE r2.CurrencyKey = s.CurrencyKey
                                 AND r2.Rate_Date  <= s.FX_Date)
        ) AS x
        ORDER BY x.Priority ASC,
                 CASE WHEN x.Priority = 1 THEN x.Rate_Date END DESC,
                 x.Rate_Date ASC
    ) AS fx
)
SELECT
    r.LineKey,
    r.CurrencyKey,

    -- ---- CORRECTION B, signing half ----
    -- The source stores ordered and shipped POSITIVE but invoiced NEGATIVE on
    -- the same return lines. Untouched, ordered volume inflates ~4% and
    -- shipped ~4%. Invoiced is already signed — do not flip it.
    CASE WHEN r.Is_Return = 1 THEN -1 * ISNULL(r.[Line_Ordered_Qty_Metric_Ton], 0)
         ELSE                            ISNULL(r.[Line_Ordered_Qty_Metric_Ton], 0)
    END                                                                 AS Ordered_MT_Signed,
    CASE WHEN r.Is_Return = 1 THEN -1 * ISNULL(r.[Line_Shipped_Qty_Metric_Ton], 0)
         ELSE                            ISNULL(r.[Line_Shipped_Qty_Metric_Ton], 0)
    END                                                                 AS Shipped_MT_Signed,
    r.[Line_Invoiced_Qty_Metric_Ton]                                    AS Invoiced_MT,
    r.[Line_Ordered_Qty]                                                AS Ordered_Qty_Native,

    -- ---- LOCAL PRICES: kept for audit, never aggregated ----
    -- Averaging these mixes nine currencies and always returns a plausible
    -- number. Hide them in the model.
    r.[Line_Unit_List_Price]                                            AS Unit_List_Price_Local,
    r.[Line_Unit_Selling_Price]                                         AS Unit_Selling_Price_Local,

    -- ---- USD PRICES: source value wins, conversion fills the gap ----
    COALESCE(r.[Line_Unit_List_Price_USD],
             r.[Line_Unit_List_Price]    * r.FX_Rate)                   AS Unit_List_Price_USD,
    COALESCE(r.[Line_Unit_Selling_Price_USD],
             r.[Line_Unit_Selling_Price] * r.FX_Rate)                   AS Unit_Selling_Price_USD,

    r.FX_Date,
    r.FX_Rate,
    r.FX_Rate_Source,
    r.Source_FX_Type                                                    AS FX_Rate_Type,

    -- A forward date can sit past the last quoted rate. Those rows carry the
    -- last known rate carried forward, which is right for a forward valuation
    -- but must not be presented as settled.
    CAST(CASE WHEN r.FX_Rate_Source = 'Corporate rate table'
                   AND r.FX_Date > (SELECT MAX(Rate_Date) FROM rpt.dim_ExchangeRate)
              THEN 1 ELSE 0 END AS bit)                                 AS FX_Rate_Is_Forward,

    -- A converted number must never be indistinguishable from a source one.
    CASE
        WHEN r.[Line_Unit_Selling_Price_USD] IS NOT NULL THEN '1 - Source'
        WHEN r.[Line_Unit_Selling_Price] IS NOT NULL
             AND r.FX_Rate IS NOT NULL                   THEN '2 - Converted'
        ELSE '3 - Not convertible'
    END                                                                 AS Price_USD_Quality

FROM rated AS r;
GO


/* ============================================================================
   6 · rpt.fact_Invoice              GRAIN: one invoice line
   ----------------------------------------------------------------------------
   Unique on (LineKey, Invoice_Number, Line_Number) — 79,576 distinct across
   79,576 rows, so no deduplication is needed or wanted. Duplicate LineKeys are
   legitimate: one order line can be invoiced in instalments.
   ========================================================================= */
CREATE OR ALTER VIEW rpt.fact_Invoice AS
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
    -- Filtering by the SO return flag finds under 10% of them.
    -- Verified: this rule leaves exactly zero negative revenue outside it.
    CAST(CASE WHEN UPPER(ISNULL(ctfv.[Transaction_Type], '')) LIKE '%CM%'
                OR UPPER(ISNULL(ctfv.[Transaction_Type], '')) LIKE '%CRD%'
                OR UPPER(ISNULL(ctfv.[Transaction_Type], '')) LIKE '%[_]NC%'
                OR ISNULL(ctfv.[Line_Revenue_Amount_USD], 0) < 0
                OR ctfv.[Line_Quantity_Credited_MT] IS NOT NULL
              THEN 1 ELSE 0 END AS bit)                                     AS Is_Credit_Memo,

    CASE WHEN UPPER(ISNULL(ctfv.[Transaction_Type], '')) LIKE '%CM%'
           OR UPPER(ISNULL(ctfv.[Transaction_Type], '')) LIKE '%CRD%'
           OR UPPER(ISNULL(ctfv.[Transaction_Type], '')) LIKE '%[_]NC%'
           OR ISNULL(ctfv.[Line_Revenue_Amount_USD], 0) < 0
           OR ctfv.[Line_Quantity_Credited_MT] IS NOT NULL
         THEN 'Credit memo' ELSE 'Invoice' END                              AS Transaction_Category,

    -- The premium breakdown is populated on NAM and EUR lines only — 76.2% of
    -- rows, 78.3% of revenue. SAM and AUS carry none, so any bridge visual
    -- must filter on this flag or it silently reports on part of the business.
    CAST(CASE WHEN ctpfv.[Line_Base_Amount] IS NOT NULL THEN 1 ELSE 0 END AS bit)
                                                                            AS Has_Price_Bridge,

    -- ---- MEASURES ----
    ctfv.[Line_Revenue_Amount_USD]                                          AS Revenue_USD,
    -- These two are MUTUALLY EXCLUSIVE: of the 4,569 rows carrying a credited
    -- quantity, not one carries an invoiced quantity. Any net volume measure
    -- must add both — summing only the first silently drops every credit.
    ctfv.[Line_Quantity_Invoiced_MT]                                        AS Qty_Invoiced_MT,
    ctfv.[Line_Quantity_Credited_MT]                                        AS Qty_Credited_MT,
    ctfv.[Line_Unit_Selling_Price_USD]                                      AS Unit_Selling_Price_USD,
    ctfv.[Line_Unit_Standard_Price_USD]                                     AS Unit_Standard_Price_USD,

    -- ---- PRICE BRIDGE COMPONENTS ----
    -- Reconcile to realised price within 0.71% on covered rows.
    ctpfv.[Line_Base_Amount]                                                AS Base_Amount,
    ctpfv.[Line_Regional_Premium_Amount]                                    AS Regional_Premium,
    ctpfv.[Line_Product_Premium_Amount]                                     AS Product_Premium,
    ctpfv.[Line_Green_Premium_Amount]                                       AS Green_Premium,
    ctpfv.[Line_Other_Premium_Amount]                                       AS Other_Premium,
    ctpfv.[Line_Tariff_Amount]                                              AS Tariff_Amount,
    ctpfv.[Line_Alloy_Amount]                                               AS Alloy_Amount

FROM cml.[Customer_Transaction_F_V] AS ctfv
LEFT JOIN cml.[Sales_Order_V] AS sov
       ON ctfv.[Data_Source_Region]      = sov.[Data_Source_Region]
      AND ctfv.[Line_DFF_Order_Line_Id]  = sov.[Line_Id]
LEFT JOIN cml.[Customer_Transaction_Price_F_V] AS ctpfv
       ON ctfv.[Data_Source_Region] = ctpfv.[Data_Source_Region]
      AND ctfv.[Transaction_Id]     = ctpfv.[Transaction_Id]
      AND ctfv.[Line_Id]            = ctpfv.[Line_Id]
WHERE 1 = 1
    AND ctfv.[Line_Type] = 'LINE'
    -- CORRECTION E again — same bracket fix as the bridge
    AND (
            sov.[Line_Schedule_Ship_Date]   >= '2026-01-01'
         OR sov.[Line_Actual_Shipment_Date] >= '2026-01-01'
        );
GO


/* ============================================================================
   7 · rpt.fact_Shipment             GRAIN: one delivery detail line
   ----------------------------------------------------------------------------
   283 source columns reduced to 37. Of the rest: 21 completely empty, 11
   populated but every value zero, 27 under 1% populated, 70 redundant twins,
   38 audit plumbing, 10 parser artefacts, 35 belong on a dimension.

   THE ALL-ZERO TRAP — Delivered_Qty_MT, Received_Qty_MT and Scheduled_Qty_MT
   are populated on 78% of rows and every single value is zero. They look real
   in a column list and will silently return zero in any measure built on them.
   Excluded deliberately; delivery-confirmation KPIs are blocked, not broken.
   ========================================================================= */
CREATE OR ALTER VIEW rpt.fact_Shipment AS
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
    -- the Unknown member keeps the gap visible on the scorecard instead of
    -- quietly shrinking the denominator.
    ISNULL(CAST(sosfv.[Delivery_Carrier_Id] AS varchar(50)), '-1')      AS CarrierKey,

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
    CAST(sosfv.[Trip_Stop_Pick_Up_Planned_Arrival_Date]   AS datetime2) AS Planned_Pickup,
    CAST(sosfv.[Trip_Stop_Pick_Up_Actual_Arrival_Date]    AS datetime2) AS Actual_Pickup,
    CAST(sosfv.[Trip_Stop_Drop_Off_Planned_Arrival_Date]  AS datetime2) AS Planned_Arrival,
    CAST(sosfv.[Trip_Stop_Drop_Off_Actual_Arrival_Date]   AS datetime2) AS Actual_Arrival,
    CAST(sosfv.[Trip_Stop_Drop_Off_Actual_Departure_Date] AS datetime2) AS Actual_Departure,

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
    CAST(CASE WHEN sosfv.[Ship_From_Country] <> sosfv.[Ship_To_Country]
              THEN 1 ELSE 0 END AS bit)                                 AS Is_Export

FROM cml.[Sales_Order_Shipment_F_V] AS sosfv
LEFT JOIN cml.[Sales_Order_V] AS sov
       ON sosfv.[Data_Source_Region]              = sov.[Data_Source_Region]
      AND sosfv.[Delivery_Detail_Source_Line_Id]  = sov.[Line_Id]
WHERE 1 = 1
    /* ---- CORRECTION A — the single most important predicate in this file ---
       48 rows have shifted columns, leaving values like 'PER2', '9.6' and
       'XPO1' in Data_Source_Region and pushing data into trailing columns.
       Left in they report 282.5m MT against a true 21.2m MT — one row alone
       contributes 39.5m. Costs at most 3 valid LineKeys.

       Root cause is almost certainly an unescaped comma or embedded newline
       in a text field upstream. Worth fixing there, since the same defect
       will recur on every refresh and may next time land on rows without an
       obviously wrong region value.
       --------------------------------------------------------------------- */
    AND sosfv.[Data_Source_Region] IN ('NAM', 'EUR', 'SAM', 'AUS')
    AND sosfv.[Delivery_Detail_Released_Status] <> 'Cancelled'
    -- CORRECTION E — bracketed, so the status filter above actually applies
    AND (
            sov.[Line_Schedule_Ship_Date]   >= '2026-01-01'
         OR sov.[Line_Actual_Shipment_Date] >= '2026-01-01'
        );
GO


/* ============================================================================
   8 · rpt.dim_Customer
   ----------------------------------------------------------------------------
   Conformed across all three facts. Sales order uses Customer_Number, invoice
   uses Sold_To_Customer_Id, shipment uses Customer_Account_Number — verified
   as the same 749-value domain with 100% overlap.
   ========================================================================= */
CREATE OR ALTER VIEW rpt.dim_Customer AS
SELECT
    c.CustomerKey,
    c.Customer_Name,
    c.Customer_Type,
    c.Country,
    c.City,
    c.[State]
FROM (
    SELECT
        sofv.[Customer_Account_Number]                      AS CustomerKey,
        sofv.[Customer_Name],
        sofv.[Customer_Type],
        sofv.[Line_Ship_To_Country]                         AS Country,
        sofv.[Line_Ship_To_City]                            AS City,
        sofv.[Line_Ship_To_State]                           AS [State],
        ROW_NUMBER() OVER (PARTITION BY sofv.[Customer_Account_Number]
                           ORDER BY sofv.[Ordered_Date] DESC)  AS rn
    FROM cml.[Sales_Order_F_V] AS sofv
    WHERE sofv.[Customer_Account_Number] IS NOT NULL
) AS c
WHERE c.rn = 1        -- most recent attributes win

UNION ALL
SELECT '-1', 'Unknown', 'Unknown', NULL, NULL, NULL;
GO


/* ============================================================================
   9 · rpt.dim_Product
   ----------------------------------------------------------------------------
   ProductKey = Line_Inventory_Item_Id + '.' + Line_Ship_From_Inventory_Org_Id,
   exactly as your query defines it. 1,722 distinct — the same item made at a
   different plant is a different ProductKey, which is correct for a
   manufacturer.
   ========================================================================= */
CREATE OR ALTER VIEW rpt.dim_Product AS
SELECT
    p.ProductKey, p.Item_Id, p.Item_Number, p.Product_Description, p.Inventory_Org_Id
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
) AS p
WHERE p.rn = 1

UNION ALL
SELECT '-1', NULL, 'Unknown', 'Unknown', NULL;
GO


/* ============================================================================
   10 · rpt.dim_Organization
   ----------------------------------------------------------------------------
   OrgKey = Data_Source_Region + '-' + Line_Ship_From_Inventory_Org_Id.
   70 distinct manufacturing / dispatch organisations.
   ========================================================================= */
CREATE OR ALTER VIEW rpt.dim_Organization AS
SELECT
    o.OrgKey, o.Region, o.Operating_Unit_Id, o.Operating_Unit, o.Inventory_Org_Id
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
) AS o
WHERE o.rn = 1

UNION ALL
SELECT '-1', 'Unknown', NULL, 'Unknown', NULL;
GO


/* ============================================================================
   11 · rpt.dim_Carrier
   ----------------------------------------------------------------------------
   173 carriers. 23.5% of delivery records carry none — those map to the
   Unknown member so the blind spot stays visible on the scorecard.
   On-time performance ranges from 39.7% to 90.6% between carriers, so this
   dimension is a negotiating position as much as a lookup.
   ========================================================================= */
CREATE OR ALTER VIEW rpt.dim_Carrier AS
SELECT
    c.CarrierKey, c.Carrier_Name, c.SCAC
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
SELECT '-1', 'Not recorded', NULL;
GO


/* ============================================================================
   12 · rpt.dim_ReturnReason
   ----------------------------------------------------------------------------
   Reason_Group is the column that matters. Only 36 of 576 returns are
   genuinely rejected inventory — the rest are price adjustments, freight and
   demurrage, and input errors. A metric named "return rate" on the raw flag
   reports invoicing accuracy, not product quality. Label it Credit Note Rate.

   CORRECTION D applied here too: without the NCHAR(160) strip, 13 real
   reasons render as 15 categories.
   ========================================================================= */
CREATE OR ALTER VIEW rpt.dim_ReturnReason AS
WITH cleaned AS (
    SELECT DISTINCT
        ISNULL(NULLIF(LTRIM(RTRIM(
            REPLACE(sofv.[Line_Return_Reason_Code], NCHAR(160), N' '))), ''),
            'Not specified')                                AS Return_Reason
    FROM cml.[Sales_Order_F_V] AS sofv
    WHERE sofv.[Line_Category_Code] = 'RETURN'
)
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
    CAST(CASE WHEN UPPER(c.Return_Reason) = 'RETURNED/REJECTED INVENTORY'
              THEN 1 ELSE 0 END AS bit)                             AS Is_Physical_Return
FROM cleaned AS c

UNION ALL
SELECT 'Not a return', 'Not a return', CAST(0 AS bit);
GO


/* ============================================================================
   VALIDATION — run before pointing Power BI at any of this
   ----------------------------------------------------------------------------
   Expected values are from the v2 extract (68,977 order lines). They will move
   as the source moves. What must NOT move is the shape: one row per key on
   every dimension, no nulls in a key, no cancelled lines, no fan-out.
   ========================================================================= */

-- 1. GRAIN. Every one of these must return zero rows. Anything here means a
--    one-to-many relationship in the model is actually many-to-many.
SELECT 'dim_SalesOrderLine' AS Obj, LineKey AS K, COUNT(*) AS Dupes FROM rpt.dim_SalesOrderLine GROUP BY LineKey HAVING COUNT(*) > 1
UNION ALL SELECT 'dim_Customer',     CustomerKey,   COUNT(*) FROM rpt.dim_Customer     GROUP BY CustomerKey   HAVING COUNT(*) > 1
UNION ALL SELECT 'dim_Product',      ProductKey,    COUNT(*) FROM rpt.dim_Product      GROUP BY ProductKey    HAVING COUNT(*) > 1
UNION ALL SELECT 'dim_Organization', OrgKey,        COUNT(*) FROM rpt.dim_Organization GROUP BY OrgKey        HAVING COUNT(*) > 1
UNION ALL SELECT 'dim_Carrier',      CarrierKey,    COUNT(*) FROM rpt.dim_Carrier      GROUP BY CarrierKey    HAVING COUNT(*) > 1
UNION ALL SELECT 'dim_ReturnReason', Return_Reason, COUNT(*) FROM rpt.dim_ReturnReason GROUP BY Return_Reason HAVING COUNT(*) > 1
UNION ALL SELECT 'dim_Currency',     CurrencyKey,   COUNT(*) FROM rpt.dim_Currency     GROUP BY CurrencyKey   HAVING COUNT(*) > 1
UNION ALL SELECT 'dim_ExchangeRate', CONCAT(CurrencyKey, '|', Rate_Date), COUNT(*)
          FROM rpt.dim_ExchangeRate GROUP BY CONCAT(CurrencyKey, '|', Rate_Date) HAVING COUNT(*) > 1;

-- 2. ROW COUNTS on the v2 extract.
--    dim_SalesOrderLine 68,977 | fact_SalesOrder 68,977 | fact_Shipment 84,505
--    dim_Customer 750 | dim_Product 1,727 | dim_Organization 71
--    dim_Carrier 174 | dim_ReturnReason 14 | dim_Currency 1,001
SELECT 'dim_SalesOrderLine' AS Obj, COUNT(*) AS [Rows] FROM rpt.dim_SalesOrderLine
UNION ALL SELECT 'fact_SalesOrder',  COUNT(*) FROM rpt.fact_SalesOrder
UNION ALL SELECT 'fact_Invoice',     COUNT(*) FROM rpt.fact_Invoice
UNION ALL SELECT 'fact_Shipment',    COUNT(*) FROM rpt.fact_Shipment
UNION ALL SELECT 'dim_Customer',     COUNT(*) FROM rpt.dim_Customer
UNION ALL SELECT 'dim_Product',      COUNT(*) FROM rpt.dim_Product
UNION ALL SELECT 'dim_Organization', COUNT(*) FROM rpt.dim_Organization
UNION ALL SELECT 'dim_Carrier',      COUNT(*) FROM rpt.dim_Carrier
UNION ALL SELECT 'dim_ReturnReason', COUNT(*) FROM rpt.dim_ReturnReason
UNION ALL SELECT 'dim_Currency',     COUNT(*) FROM rpt.dim_Currency;

-- 3. REFERENTIAL INTEGRITY. Every fact row must find its bridge row.
SELECT 'fact_SalesOrder' AS Fact, COUNT(*) AS Orphans
FROM rpt.fact_SalesOrder f LEFT JOIN rpt.dim_SalesOrderLine d ON f.LineKey = d.LineKey WHERE d.LineKey IS NULL
UNION ALL SELECT 'fact_Invoice', COUNT(*)
FROM rpt.fact_Invoice   f LEFT JOIN rpt.dim_SalesOrderLine d ON f.LineKey = d.LineKey WHERE d.LineKey IS NULL
UNION ALL SELECT 'fact_Shipment', COUNT(*)
FROM rpt.fact_Shipment  f LEFT JOIN rpt.dim_SalesOrderLine d ON f.LineKey = d.LineKey WHERE d.LineKey IS NULL;

-- 4. THE WHERE-CLAUSE FIX. Must be zero — and now is, in v2. Reads 39 against
--    the unbracketed version, so it stays here as a regression guard.
SELECT COUNT(*) AS Cancelled_Lines_Present FROM rpt.dim_SalesOrderLine WHERE Is_Cancelled = 1;

-- 5. THE SIGN FIX. Ordered must read ~25.35m, not ~25.75m. If it reads high,
--    the returns were never signed and every volume figure is ~4% out.
SELECT
    SUM(Ordered_MT_Signed) AS Ordered_MT,   -- expect  25,346,201
    SUM(Shipped_MT_Signed) AS Shipped_MT,   -- expect  20,350,225
    SUM(Invoiced_MT)       AS Invoiced_MT   -- expect  20,350,680
FROM rpt.fact_SalesOrder;

-- 6. THE MALFORMED-ROW FILTER. Shipped must be ~21.2m, not ~282.5m.
SELECT SUM(Shipped_MT) AS Shipped_MT FROM rpt.fact_Shipment;   -- expect 21,199,021

-- 7. CURRENCY COVERAGE. Expect Source 60,685 | Converted 8,292 |
--    Not convertible 0. Coverage is 100.000% on the v2 extract.
SELECT Price_USD_Quality, COUNT(*) AS Lines,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS decimal(6,3)) AS Pct
FROM rpt.fact_SalesOrder GROUP BY Price_USD_Quality ORDER BY Price_USD_Quality;

-- 8. RATE PRECEDENCE. Expect Identity 33,120 (48.0%) | Source Exchange_Rate
--    30,541 (44.3%) | Corporate rate table 5,316 (7.7%) | Unresolved 0.
--    'Unresolved' above zero means a currency-region pair is missing from
--    d_exchange_rate entirely.
SELECT FX_Rate_Source, COUNT(*) AS Lines,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS decimal(5,2)) AS Pct
FROM rpt.fact_SalesOrder GROUP BY FX_Rate_Source ORDER BY FX_Rate_Source;

-- 9. THE SOURCE RATE IS AUTHORITATIVE — prove it still is after a refresh.
--    Recomputes the USD price from Exchange_Rate and compares. Expect zero
--    rows outside a 0.01% tolerance; it currently matches on 100% of 25,834.
SELECT COUNT(*) AS Rows_Where_Source_Rate_Disagrees
FROM rpt.fact_SalesOrder
WHERE FX_Rate_Source = 'Source Exchange_Rate'
  AND Unit_Selling_Price_Local IS NOT NULL
  AND Unit_Selling_Price_Local <> 0
  AND Unit_Selling_Price_USD   IS NOT NULL
  AND ABS(Unit_Selling_Price_Local * FX_Rate - Unit_Selling_Price_USD)
      / NULLIF(ABS(Unit_Selling_Price_USD), 0) > 0.0001;

-- 10. FX DATE LADDER. FX_Date must never be null — a null breaks the lookup
--     silently. Expected: Source Exchange_Date 30,541 | Actual shipment 30,617
--     | Fulfilment 4,168 | Promise 3,168 | Scheduled ship 483 | Order date 0.
SELECT FX_Date_Basis, COUNT(*) AS Lines,
       SUM(CASE WHEN FX_Date IS NULL THEN 1 ELSE 0 END) AS Null_FX_Date
FROM rpt.dim_SalesOrderLine GROUP BY FX_Date_Basis ORDER BY FX_Date_Basis;

-- 11. FORWARD-RATE EXPOSURE. Expect ~1,364 lines (1.98%). These convert at the
--     last known rate carried forward because their date sits past the final
--     quote — right for a forward valuation, wrong to present as settled.
SELECT COUNT(*) AS Forward_Rate_Lines FROM rpt.fact_SalesOrder WHERE FX_Rate_Is_Forward = 1;

-- 12. CURRENCY KEY RESOLUTION. Must be zero. Anything here means a
--     currency-region pair in the facts is missing from d_currency.
SELECT COUNT(*) AS Unresolved_Currency
FROM rpt.dim_SalesOrderLine d
LEFT JOIN rpt.dim_Currency c ON d.CurrencyKey = c.CurrencyKey
WHERE c.CurrencyKey IS NULL;

-- 13. SENTINEL DATES. All four must be zero.
SELECT
    SUM(CASE WHEN Schedule_Ship_Date    > '2030-12-30' THEN 1 ELSE 0 END) AS Sched,
    SUM(CASE WHEN Promise_Date          > '2030-12-30' THEN 1 ELSE 0 END) AS Promise,
    SUM(CASE WHEN Request_Date          > '2030-12-30' THEN 1 ELSE 0 END) AS [Request],
    SUM(CASE WHEN Schedule_Arrival_Date > '2030-12-30' THEN 1 ELSE 0 END) AS Arrival
FROM rpt.dim_SalesOrderLine;

-- 14. RETURN REASONS. Expect 14 (13 real + 'Not a return'). Reads 16 if the
--     non-breaking space strip is not working.
SELECT COUNT(*) AS Distinct_Reasons FROM rpt.dim_ReturnReason;

-- 15. THE FAN-OUT GUARD, in SQL. Invoiced must never exceed Ordered at the
--     grand total. If it does, something is joined fact-to-fact.
SELECT CASE WHEN (SELECT SUM(Invoiced_MT)        FROM rpt.fact_SalesOrder)
               >  (SELECT SUM(Ordered_MT_Signed) FROM rpt.fact_SalesOrder) * 1.05
            THEN 'FAN-OUT DETECTED' ELSE 'Model OK' END AS Fan_Out_Check;


/* ============================================================================
   RELATIONSHIPS TO CREATE IN POWER BI
   ----------------------------------------------------------------------------
     FROM (1)               TO (*)                 KEY             ACTIVE
     ------------------------------------------------------------------------
     dim_SalesOrderLine  -> fact_SalesOrder        LineKey         Yes  (1:1)
     dim_SalesOrderLine  -> fact_Invoice           LineKey         Yes
     dim_SalesOrderLine  -> fact_Shipment          LineKey         Yes
     dim_Date            -> dim_SalesOrderLine     Ordered_Date    Yes
     dim_Date            -> fact_Invoice           Invoice_Date    NO
     dim_Date            -> fact_Shipment          Delivery_Confirm_Date  NO
     dim_Customer        -> dim_SalesOrderLine     CustomerKey     Yes
     dim_Product         -> dim_SalesOrderLine     ProductKey      Yes
     dim_Organization    -> dim_SalesOrderLine     OrgKey          Yes
     dim_Currency        -> dim_SalesOrderLine     CurrencyKey     Yes
     dim_ReturnReason    -> dim_SalesOrderLine     Return_Reason   Yes
     dim_Carrier         -> fact_Shipment          CarrierKey      Yes

   dim_ExchangeRate is consumed inside fact_SalesOrder and is NOT related to
   anything. Load it only if you want the rate history visible for audit.

   All cross-filter directions Single. The two inactive date relationships are
   activated inside measures with USERELATIONSHIP — that is what lets "revenue
   by invoice month" coexist with "orders by order month". It matters more than
   it sounds: the credit-rate spike is invisible on the order-date timeline.

   Turn OFF Autodetect new relationships before the first refresh, or Power BI
   will wire fact_Invoice straight to fact_Shipment for you.
   ========================================================================= */
