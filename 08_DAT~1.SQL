/* ============================================================================
   dim_DateBasis   —   the date-lens selector
   ============================================================================
   A disconnected table. It has NO relationship to anything; it exists purely so
   a slicer can tell the measures which date to anchor on.

   WHY THIS RATHER THAN THREE REPORTS
     Supply chain wants shipping date, finance wants invoice date, transport
     wants trip stage dates. Same measures, different lens. Duplicating the
     measure set per team gives you 135 x 3 measures to maintain. One selector
     plus USERELATIONSHIP gives you one set.

   SCOPE IS NOT COSMETIC — READ THIS
     Where a date physically lives decides what it can filter.

       Bridge dates      ordered, scheduled ship, actual shipment, promise,
                         requested, fulfilment
                         -> filter ALL THREE facts. Revenue, volume and
                            shipments all move together.

       Invoice dates     invoice, GL posting, invoice ship date
                         -> filter fact_Invoice ONLY. Revenue and invoiced
                            tonnage respond; Shipped MT does not, because it
                            lives on a different fact with no relationship to
                            an invoice date.

       Shipment dates    delivery confirm, pickup planned/actual,
                         drop-off planned/actual
                         -> filter fact_Shipment ONLY.

     That is not a defect. It maps neatly onto who asks for what: supply chain
     needs the cross-functional view and gets it from bridge dates; finance
     needs revenue on an invoice timeline and gets it; transport needs delivery
     performance by trip stage and gets it. But a finance user who picks
     "Invoice date" and then wonders why Shipped MT did not move needs the
     Scope column visible on the slicer, so put it there.

   BUILD IT AS A LOOKUP, NOT A QUERY
     There is no source table for this. Either paste the SELECT below as a
     native query, or use Enter Data in Power BI — the M version is in
     08_DateBasis_And_Slicers.m. Sixteen rows either way.
   ========================================================================= */
SELECT * FROM (VALUES
    -- Key            Label                     Team              Scope             Sort
    ( 'ordered',     'Ordered date',           'Commercial',     'All facts',       10),
    ( 'sched_ship',  'Scheduled ship date',    'Supply chain',   'All facts',       20),
    ( 'actual_ship', 'Actual shipment date',   'Supply chain',   'All facts',       21),
    ( 'promise',     'Promise date',           'Supply chain',   'All facts',       22),
    ( 'request',     'Requested date',         'Supply chain',   'All facts',       23),
    ( 'fulfil',      'Fulfilment date',        'Supply chain',   'All facts',       24),
    ( 'invoice',     'Invoice date',           'Finance',        'Invoice only',    30),
    ( 'gl',          'GL posting date',        'Finance',        'Invoice only',    31),
    ( 'inv_ship',    'Invoice ship date',      'Finance',        'Invoice only',    32),
    ( 'deliv_conf',  'Delivery confirm date',  'Transportation', 'Shipment only',   40),
    ( 'pick_plan',   'Pickup planned',         'Transportation', 'Shipment only',   41),
    ( 'pick_act',    'Pickup actual',          'Transportation', 'Shipment only',   42),
    ( 'drop_plan',   'Drop-off planned',       'Transportation', 'Shipment only',   43),
    ( 'drop_act',    'Drop-off actual',        'Transportation', 'Shipment only',   44)
) AS v (Basis_Key, Basis_Label, Team, Scope, Sort_Order)


/* ============================================================================
   COVERAGE — measured on the current extract
   ----------------------------------------------------------------------------
   A basis with low coverage silently drops rows from every visual using it.
   Show this next to the slicer, or at least know it.

     Basis                    Table      Populated   Coverage
     ---------------------------------------------------------
     Ordered date             bridge        68,977     100.0%
     Requested date           bridge        68,975     100.0%
     Scheduled ship date      bridge        68,651      99.5%
     Promise date             bridge        65,183      94.5%
     Fulfilment date          bridge        63,555      92.1%
     Actual shipment date     bridge        59,336      86.0%   <- unshipped lines
     Invoice date             invoice       79,576     100.0%
     GL posting date          invoice       79,576     100.0%
     Invoice ship date        invoice       75,721      95.2%
     Pickup planned           shipment      66,105      78.2%
     Drop-off planned         shipment      66,096      78.2%
     Delivery confirm date    shipment      64,695      76.6%
     Pickup actual            shipment      63,977      75.7%
     Drop-off actual          shipment      63,969      75.7%

   Actual shipment date at 86% is the one to watch: the missing 14% is the open
   order book. Switching a supply chain view to that basis quietly removes every
   unshipped line, which is usually what is wanted — but not always.
   ========================================================================= */
