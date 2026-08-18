/*  ==========================================================================
    dim_DateBasis  —  the date-lens selector          (Power Query version)
    ==========================================================================
    Disconnected. No relationship to anything. It exists so a slicer can tell
    the measures which date to anchor on.

    Paste as a Blank Query. See 08_DateBasis_And_Slicers.sql for the same
    table as a SELECT, and for the coverage figures per basis.

    After loading:
      · sort Basis_Label by Sort_Order
      · hide Basis_Key and Sort_Order from report view
      · put Team on the slicer as a group header, and Scope as a tooltip or a
        second line — a finance user needs to see "Invoice only" before they
        wonder why Shipped MT did not move
    ========================================================================== */
let
    Rows = #table(
        type table [Basis_Key = text, Basis_Label = text, Team = text,
                    Scope = text, Sort_Order = Int64.Type],
        {
            {"ordered",     "Ordered date",          "Commercial",     "All facts",     10},
            {"sched_ship",  "Scheduled ship date",   "Supply chain",   "All facts",     20},
            {"actual_ship", "Actual shipment date",  "Supply chain",   "All facts",     21},
            {"promise",     "Promise date",          "Supply chain",   "All facts",     22},
            {"request",     "Requested date",        "Supply chain",   "All facts",     23},
            {"fulfil",      "Fulfilment date",       "Supply chain",   "All facts",     24},
            {"invoice",     "Invoice date",          "Finance",        "Invoice only",  30},
            {"gl",          "GL posting date",       "Finance",        "Invoice only",  31},
            {"inv_ship",    "Invoice ship date",     "Finance",        "Invoice only",  32},
            {"deliv_conf",  "Delivery confirm date", "Transportation", "Shipment only", 40},
            {"pick_plan",   "Pickup planned",        "Transportation", "Shipment only", 41},
            {"pick_act",    "Pickup actual",         "Transportation", "Shipment only", 42},
            {"drop_plan",   "Drop-off planned",      "Transportation", "Shipment only", 43},
            {"drop_act",    "Drop-off actual",       "Transportation", "Shipment only", 44}
        })
in
    Rows


/*  ==========================================================================
    RELATIONSHIPS TO ADD  —  dim_Date to every date column, all INACTIVE
    --------------------------------------------------------------------------
    You already have three of these. Add the rest. Every one is Single
    direction, dim_Date on the 1 side, and INACTIVE except Ordered_Date.

      dim_Date[Date] -> dim_SalesOrderLine[Ordered_Date]           ACTIVE
      dim_Date[Date] -> dim_SalesOrderLine[Schedule_Ship_Date]     inactive
      dim_Date[Date] -> dim_SalesOrderLine[Actual_Shipment_Date]   inactive
      dim_Date[Date] -> dim_SalesOrderLine[Promise_Date]           inactive
      dim_Date[Date] -> dim_SalesOrderLine[Request_Date]           inactive
      dim_Date[Date] -> dim_SalesOrderLine[Fulfillment_Date]       inactive

      dim_Date[Date] -> fact_Invoice[Invoice_Date]                 inactive
      dim_Date[Date] -> fact_Invoice[Batch_GL_Date]                inactive
      dim_Date[Date] -> fact_Invoice[Ship_Date_Actual]             inactive

      dim_Date[Date] -> fact_Shipment[Delivery_Confirm_Date]       inactive
      dim_Date[Date] -> fact_Shipment[Planned_Pickup]              inactive
      dim_Date[Date] -> fact_Shipment[Actual_Pickup]               inactive
      dim_Date[Date] -> fact_Shipment[Planned_Arrival]             inactive
      dim_Date[Date] -> fact_Shipment[Actual_Arrival]              inactive

    Fourteen relationships from one table. That is fine and it is not
    ambiguity — only one can be active at a time, and USERELATIONSHIP picks
    which. Power BI will not complain.

    NOTE ON THE SHIPMENT TIMESTAMPS
      Planned_Pickup, Actual_Pickup, Planned_Arrival and Actual_Arrival are
      datetime2 in the source. A relationship to a date column needs them cast
      to date, or the join matches nothing. Either change the type in
      fact_Shipment, or add date-only companion columns. The SQL files already
      CAST Delivery_Confirm_Date; do the same for these four if you want them
      as bases.
    ========================================================================== */
