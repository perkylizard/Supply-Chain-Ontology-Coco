-- =============================================================================
-- 30_semantic_view.sql
-- SC.SEMANTIC.SV_SUPPLY_CHAIN: the ONE place where metric logic lives
-- (AGENTS.md hard rule 1). Implements docs/metric_contracts.md v1.4 over the
-- SC.CONFORMED entities of docs/ontology.md.
-- Depends on: sql/20_conformed.sql. Idempotent: CREATE OR REPLACE ... COPY GRANTS.
-- Authored as DDL (single source). cortex_project/SV_SUPPLY_CHAIN.sv.yaml is an
-- export of the deployed view, re-synced after each deploy; never edit it by hand.
--
-- Logical tables (ontology entity -> CONFORMED object)
--   order_lines           OrderLine            FACT_ORDER_LINE         Customer OTD %, Fill Rate %
--   shipments             Shipment             FACT_SHIPMENT           (volumes only)
--   purchase_order_lines  PurchaseOrderLine    FACT_PO_LINE            Supplier OTD %
--   goods_receipts        PO line x GR         FACT_GOODS_RECEIPT      Landed Cost per Unit
--   inventory             InventorySnapshot    FACT_INVENTORY_SNAPSHOT Days of Inventory
--   suppliers parts plants customers                       DIM_*
--   contracts             Contract             DIM_CONTRACT            (terms from the signed PDF)
--   supplier_parts        SupplierPart         DIM_SUPPLIER_PART       (R6 link to contracts)
--   dates                 Time hierarchy       DIM_DATE (4-4-5 fiscal + calendar), role-played
--   12 logical tables. DIM_WAREHOUSE and DIM_CARRIER are not included (decided
--   2026-10-03, option B): no metric reaches a warehouse (inventory and shipments
--   are plant-grain), and the carrier is only a label, so the shipment carries
--   its SCAC as a plain dimension (shipments.scac).
--
-- Relationships (ontology.md §2) present in CONFORMED
--   R3 R4 R5 R6 R8 R9 R10 R11, R15, R16 at plant grain (inventory -> plants; RAW
--   inventory has no warehouse), PO line -> Part and GR -> PO line (§6 extension),
--   plus one date-role join per fact (commit / commit / GR posting / snapshot).
--   Not modelled: R1 R2 (supplier_parts -> suppliers would be a second path next to
--   supplier_parts -> contracts -> suppliers; supplier_parts carries SUPPLIER_NO and
--   PART_NO as plain dimensions instead), R7 (SalesOrder header is
--   denormalized onto order_lines), R12 (SCAC kept on shipments, no carrier
--   table), R13 R14 (no warehouse table; FACT_SHIPMENT.WAREHOUSE_CODE is NULL),
--   R17 R18 (no SensorReading fact yet).
--   Contract terms are dimensions on contracts. Supplier Contractual OTD % / Gap
--   (contract v1.4 §3.1, named variant) live on purchase_order_lines and read the
--   contract terms copied per PO line in CONFORMED (a purchase_order_lines -> contracts
--   join would be a second path to suppliers, which semantic views do not support).
--   purchase_order_lines has two date roles: po_line_to_commit_date (Supplier OTD %,
--   fiscal) and po_line_to_latest_confirmed_date (contractual, calendar months);
--   every PO-line metric names its role with USING.
--
-- Hierarchies (ontology.md §4) have no native semantic-view construct; they are
-- exposed as level dimensions whose comments name the parent level:
--   Part      parts.part_category > parts.part_family > parts.part_no
--   Geography plants.plant_region > plants.plant_country > plants.plant_code
--   Customer  customers.customer_segment > customers.customer_no
--   Time      dates.fiscal_year > fiscal_quarter > fiscal_month > fiscal_week > calendar_date
--
-- Contract rules applied everywhere (§1.3)
--   * ratio of sums: every ratio is SUM/COUNT of row-level facts at query grain
--   * zero denominator -> NULL (x / NULLIF(y, 0)); never DIV0 / DIV0NULL
--   * percentages are 0-1 fractions, NUMBER(9,6)
--   * as-of date = CURRENT_DATE() of the session (due lines: commit <= as-of)
--
-- Evidence coverage % (contract v1.2 §1.3, §5, §6): share of the metric's population
-- without the evidence-gap flags below.
--   Customer OTD % / Fill Rate %  NO_ARRIVAL_EVIDENCE (same population, one metric)
--   Supplier OTD %                NO_ARRIVAL_EVIDENCE (GR_FALLBACK counts as evidence;
--                                 GR-fallback share published separately)
--   Days of Inventory             DEMAND_FALLBACK, NO_DEMAND, NEGATIVE_STOCK
--   Landed Cost per Unit / Uplift PROVISIONAL, ALLOC_BY_VALUE; UNMAPPED_PART receipts are
--                                 added to the denominator as not covered
-- =============================================================================

USE ROLE SC_ADMIN;
USE WAREHOUSE SC_WH;
USE SCHEMA SC.SEMANTIC;

CREATE OR REPLACE SEMANTIC VIEW SC.SEMANTIC.SV_SUPPLY_CHAIN

  TABLES (
    order_lines AS SC.CONFORMED.FACT_ORDER_LINE
      PRIMARY KEY (SO_NO, LINE_NO)
      WITH SYNONYMS ('line', 'line item', 'order item', 'SO line', 'sales order line', 'customer order line')
      COMMENT = 'OrderLine: one Part, quantity and commit date on a customer SalesOrder (header attributes denormalized). Grain of Customer OTD % and Fill Rate %. One row per SO_NO + LINE_NO.',
    shipments AS SC.CONFORMED.FACT_SHIPMENT
      PRIMARY KEY (SHIPMENT_NO, SO_NO, LINE_NO)
      WITH SYNONYMS ('load', 'consignment', 'freight', 'BOL')
      COMMENT = 'Shipment: physical movement of (part of) one OrderLine by one Carrier, with arrival evidence. Outbound only. Grain shipment x order line.',
    purchase_order_lines AS SC.CONFORMED.FACT_PO_LINE
      PRIMARY KEY (PO_NO, PO_LINE_NO)
      WITH SYNONYMS ('PO', 'purchase order', 'buy order', 'release', 'PO line')
      COMMENT = 'PurchaseOrderLine: one supplier part, quantity and supplier commit date on a PurchaseOrder. Grain of Supplier OTD %. One row per PO_NO + PO_LINE_NO.',
    goods_receipts AS SC.CONFORMED.FACT_GOODS_RECEIPT
      PRIMARY KEY (GR_NO)
      WITH SYNONYMS ('goods receipt', 'GR', 'receipt')
      COMMENT = 'Goods receipt: one posted receipt against a PO line, with landed-cost components. Grain of Landed Cost per Unit. One row per GR_NO.',
    inventory AS SC.CONFORMED.FACT_INVENTORY_SNAPSHOT
      PRIMARY KEY (PART_NO, PLANT_CODE, SNAPSHOT_DATE)
      WITH SYNONYMS ('stock', 'on-hand', 'stock position', 'inventory balance', 'inventory snapshot')
      COMMENT = 'InventorySnapshot: end-of-day stock of a Part at a Plant by stock status, with demand inputs. Grain of Days of Inventory. One row per PART_NO x PLANT_CODE x SNAPSHOT_DATE.',
    suppliers AS SC.CONFORMED.DIM_SUPPLIER
      PRIMARY KEY (SUPPLIER_NO)
      WITH SYNONYMS ('vendor', 'seller', 'source', 'manufacturer', 'provider')
      COMMENT = 'Supplier: legal entity we buy parts or materials from. Natural key SUPPLIER_NO (ERP vendor number).',
    parts AS SC.CONFORMED.DIM_PART
      PRIMARY KEY (PART_NO)
      WITH SYNONYMS ('SKU', 'material', 'item', 'product', 'component', 'article')
      COMMENT = 'Part: item we buy, make, stock or sell, in its base unit of measure. Part hierarchy Category > Family > SKU.',
    plants AS SC.CONFORMED.DIM_PLANT
      PRIMARY KEY (PLANT_CODE)
      WITH SYNONYMS ('site', 'facility', 'factory', 'location')
      COMMENT = 'Plant: physical company site that makes, receives or ships goods. Geography hierarchy Region > Country > Plant.',
    customers AS SC.CONFORMED.DIM_CUSTOMER
      PRIMARY KEY (CUSTOMER_NO)
      WITH SYNONYMS ('client', 'account', 'buyer', 'sold-to')
      COMMENT = 'Customer: sold-to party. Customer hierarchy Segment > Customer.',
    contracts AS SC.CONFORMED.DIM_CONTRACT
      PRIMARY KEY (CONTRACT_NO)
      WITH SYNONYMS ('contract', 'agreement', 'supply agreement', 'MSA')
      COMMENT = 'Contract: supply agreement with one Supplier. Terms (delivery target, lead time, Incoterm, payment terms, late-delivery penalty, validity) come from the signed PDF, the legal source. One row per CONTRACT_NO.',
    supplier_parts AS SC.CONFORMED.DIM_SUPPLIER_PART
      PRIMARY KEY (SUPPLIER_NO, SUPPLIER_PART_NO)
      WITH SYNONYMS ('vendor item', 'approved vendor part', 'source of supply', 'catalog item')
      COMMENT = 'SupplierPart: a Supplier approved to supply a Part, with its quoted lead time, MOQ, price and governing contract (NULL = spot buy). One row per SUPPLIER_NO x SUPPLIER_PART_NO.',
    dates AS SC.CONFORMED.DIM_DATE
      PRIMARY KEY ("DATE")
      WITH SYNONYMS ('calendar', 'fiscal calendar', 'period')
      COMMENT = 'Calendar with 4-4-5 fiscal attributes (ISO weeks). Role-played: joined to each fact on that metric''s time anchor (commit date, GR posting date, snapshot date).'
  )

  RELATIONSHIPS (
    order_line_to_customer      AS order_lines (CUSTOMER_NO)               REFERENCES customers,
    order_line_to_part          AS order_lines (PART_NO)                   REFERENCES parts,
    order_line_to_plant         AS order_lines (PLANT_CODE)                REFERENCES plants,
    order_line_to_commit_date   AS order_lines (FIRST_COMMIT_DATE)         REFERENCES dates,
    shipment_to_order_line      AS shipments (SO_NO, LINE_NO)              REFERENCES order_lines,
    po_line_to_supplier         AS purchase_order_lines (SUPPLIER_NO)      REFERENCES suppliers,
    po_line_to_plant            AS purchase_order_lines (PLANT_CODE)       REFERENCES plants,
    po_line_to_part             AS purchase_order_lines (part_join_key)    REFERENCES parts,
    po_line_to_commit_date      AS purchase_order_lines (FIRST_COMMIT_DATE) REFERENCES dates,
    po_line_to_latest_confirmed_date AS purchase_order_lines (contract_due_date_key) REFERENCES dates,
    goods_receipt_to_po_line    AS goods_receipts (PO_NO, PO_LINE_NO)      REFERENCES purchase_order_lines,
    goods_receipt_to_posting_date AS goods_receipts (POSTING_DATE)         REFERENCES dates,
    inventory_to_part           AS inventory (PART_NO)                     REFERENCES parts,
    inventory_to_plant          AS inventory (PLANT_CODE)                  REFERENCES plants,
    inventory_to_snapshot_date  AS inventory (SNAPSHOT_DATE)               REFERENCES dates,
    contract_to_supplier        AS contracts (SUPPLIER_NO)                 REFERENCES suppliers,
    supplier_part_to_contract   AS supplier_parts (CONTRACT_NO)            REFERENCES contracts
  )

  FACTS (
    -- ---------------- order_lines: Customer OTD % and Fill Rate % (§2, §4) ----------------
    PRIVATE order_lines.is_otd_population
      AS order_lines.LINE_TYPE = 'STANDARD' AND order_lines.ORDER_QTY > 0 AND order_lines.REQUIRED_QTY > 0
         AND customers.is_intercompany IS DISTINCT FROM TRUE
      COMMENT = 'Population of Customer OTD % and Fill Rate % (identical by contract): outbound STANDARD lines; excludes returns (ORDER_QTY <= 0), free-of-charge samples, fully cancelled lines (required qty 0) and intercompany customers.',
    PRIVATE order_lines.is_due_line
      AS order_lines.is_otd_population AND order_lines.FIRST_COMMIT_DATE IS NOT NULL
         AND order_lines.FIRST_COMMIT_DATE <= CURRENT_DATE()
      COMMENT = 'Due line: in population, commit date present and on or before the as-of date (CURRENT_DATE). The reporting period comes from the query filter on the commit date. Open lines stay due.',
    PRIVATE order_lines.is_on_time_line
      AS order_lines.is_due_line
         AND order_lines.COMPLETE_ARRIVAL_LOCAL_DATE BETWEEN DATEADD(day, -1, order_lines.FIRST_COMMIT_DATE) AND order_lines.FIRST_COMMIT_DATE
      COMMENT = 'On-time window [commit - 1 day, commit], inclusive, on the customer-local complete-arrival date. Incomplete lines (NULL complete-arrival) are late.',
    PRIVATE order_lines.is_no_commit_line
      AS order_lines.is_otd_population AND order_lines.FIRST_COMMIT_DATE IS NULL
      COMMENT = 'Population line without a commit date: excluded from the metrics, counted for the DQ summary (NO_COMMIT).',
    PRIVATE order_lines.has_arrival_gap
      AS ARRAY_CONTAINS('NO_ARRIVAL_EVIDENCE'::VARIANT, order_lines.DQ_FLAGS)
      COMMENT = 'TRUE when at least one shipment of the line has no arrival evidence (NO_ARRIVAL_EVIDENCE).',
    PRIVATE order_lines.line_required_qty
      AS order_lines.REQUIRED_QTY
      COMMENT = 'Required qty (§1.1) in base UoM.',
    PRIVATE order_lines.line_filled_qty
      AS LEAST(COALESCE(order_lines.ARRIVED_BY_COMMIT_QTY, 0), order_lines.REQUIRED_QTY)
      COMMENT = 'Filled qty = MIN(qty of the ordered part arrived with local date <= commit date, required qty). Early arrivals count; over-delivery capped per line; substitutes and lines without arrival evidence contribute 0.',

    -- ---------------- purchase_order_lines: Supplier OTD % (§3) ----------------
    PRIVATE purchase_order_lines.is_stock_part_line
      AS purchase_order_lines.ITEM_CATEGORY = 'STOCK' AND parts.is_stocked IS DISTINCT FROM FALSE
      COMMENT = 'PO line for a stocked part: STOCK item category and the part is not flagged non-stock in the material master. Unmapped supplier parts (UNMAPPED_PART) are kept.',
    PRIVATE purchase_order_lines.is_supplier_otd_population
      AS purchase_order_lines.is_stock_part_line AND purchase_order_lines.REQUIRED_QTY > 0
      COMMENT = 'Population of Supplier OTD %: stocked-part PO lines from external suppliers; excludes service / non-stock lines and fully cancelled lines. No intercompany POs or returns to vendor exist in CONFORMED.',
    PRIVATE purchase_order_lines.is_due_po_line
      AS purchase_order_lines.is_supplier_otd_population AND purchase_order_lines.FIRST_COMMIT_DATE <= CURRENT_DATE()
      COMMENT = 'Due PO line: in population and supplier commit date on or before the as-of date. Open lines stay due.',
    PRIVATE purchase_order_lines.is_on_time_po_line
      AS purchase_order_lines.is_due_po_line
         AND purchase_order_lines.COMPLETE_ARRIVAL_LOCAL_DATE BETWEEN DATEADD(day, -1, purchase_order_lines.FIRST_COMMIT_DATE) AND purchase_order_lines.FIRST_COMMIT_DATE
      COMMENT = 'On-time window [commit - 1 day, commit] on the plant-local complete-arrival date. Under-delivered (incomplete) lines are late.',
    PRIVATE purchase_order_lines.has_no_arrival_evidence
      AS ARRAY_CONTAINS('NO_ARRIVAL_EVIDENCE'::VARIANT, purchase_order_lines.DQ_FLAGS)
      COMMENT = 'TRUE when the PO line is flagged NO_ARRIVAL_EVIDENCE. GR posting fallback counts as evidence (v1.2).',
    PRIVATE purchase_order_lines.is_gr_fallback
      AS ARRAY_CONTAINS('GR_FALLBACK'::VARIANT, purchase_order_lines.DQ_FLAGS)
      COMMENT = 'TRUE when an arrival of the PO line comes from the ERP goods-receipt posting date because the ASN has no IoT geofence or carrier POD (GR_FALLBACK).',
    PRIVATE purchase_order_lines.part_join_key
      AS COALESCE(purchase_order_lines.PART_NO, '#UNMAPPED')
      COMMENT = 'Join key to parts: PART_NO, or the unknown member #UNMAPPED (category UNMAPPED PART) when the supplier part number maps to no ERP part, so unmapped lines and receipts show under a label instead of a blank row. PART_NO itself stays NULL.',
    -- ---------------- purchase_order_lines: Supplier Contractual OTD % (v1.4 §3.1, variant) ----------------
    PRIVATE purchase_order_lines.contract_due_date_key
      AS COALESCE(purchase_order_lines.LATEST_CONFIRMED_DATE, purchase_order_lines.DUE_DATE)
      COMMENT = 'Time anchor of Supplier Contractual OTD % (v1.4 §3.1): latest supplier-confirmed date; PO due date when never confirmed. Join key of the latest-confirmed-date role on dates.',
    PRIVATE purchase_order_lines.is_contractual_population
      AS purchase_order_lines.is_supplier_otd_population AND purchase_order_lines.CONTRACT_NO IS NOT NULL
      COMMENT = 'Population of Supplier Contractual OTD %: the Supplier OTD % population restricted to PO lines with a governing contract. All of them, in or out of contract validity (pro-forma, v1.4).',
    PRIVATE purchase_order_lines.is_contractual_due_po_line
      AS purchase_order_lines.is_contractual_population AND purchase_order_lines.contract_due_date_key <= CURRENT_DATE()
      COMMENT = 'Contractual due PO line: in population and latest confirmed date on or before the as-of date. Open lines stay due.',
    PRIVATE purchase_order_lines.is_contractual_on_time_po_line
      AS purchase_order_lines.is_contractual_due_po_line
         AND COALESCE(purchase_order_lines.COMPLETE_ARRIVAL_LOCAL_DATE <= DATEADD(day, purchase_order_lines.CONTRACT_LATE_GRACE_DAYS, purchase_order_lines.contract_due_date_key), FALSE)
      COMMENT = 'Contractual on time (v1.4 §3.1): full required qty arrived (plant-local complete-arrival date) on or before latest confirmed date + the contract''s grace days. Early arrivals are on time; incomplete lines (no complete-arrival date) are FALSE = late, never NULL.',
    PRIVATE purchase_order_lines.is_in_contract_validity
      AS purchase_order_lines.PO_DATE BETWEEN purchase_order_lines.CONTRACT_VALID_FROM AND purchase_order_lines.CONTRACT_VALID_TO
      COMMENT = 'TRUE when the PO was ordered inside the governing contract''s validity; FALSE = pro-forma (contract terms applied to an earlier PO line).',
    PRIVATE purchase_order_lines.is_unmapped_stock_line
      AS purchase_order_lines.is_stock_part_line AND purchase_order_lines.PART_NO IS NULL
      COMMENT = 'Stock PO line whose supplier part number maps to no ERP part (UNMAPPED_PART).',

    -- ---------------- inventory: Days of Inventory (§5) ----------------
    PRIVATE parts.standard_cost_amt
      AS parts.STANDARD_COST_AMT
      COMMENT = 'ERP standard cost per base UoM, USD. Weight for DOI above Part level.',
    PRIVATE inventory.is_doi_population
      AS parts.is_stocked = TRUE
      COMMENT = 'Population of Days of Inventory: stocked parts only. Quarantine / blocked stock is excluded through UNRESTRICTED_QTY; no consignment or customer-owned stock exists in CONFORMED.',
    PRIVATE inventory.usable_qty
      AS inventory.UNRESTRICTED_QTY + IFF(inventory.IS_IN_TRANSIT_OWNED, inventory.IN_TRANSIT_QTY, 0)
      COMMENT = 'Usable inventory = unrestricted on-hand (negative floored to 0 in CONFORMED) + owned in-transit, base UoM.',
    PRIVATE inventory.is_demand_fallback
      AS inventory.FORECAST_QTY_NEXT_28D IS NULL OR COALESCE(inventory.FORECAST_DAYS_COVERED, 0) < 14
      COMMENT = 'DEMAND_FALLBACK (contract v1.2 §5): the latest forecast run covers fewer than 14 days of snapshot+1..+28 (or there is no run), so trailing 28-day shipments are used.',
    PRIVATE inventory.daily_demand_qty
      AS IFF(inventory.is_demand_fallback, inventory.SHIPPED_QTY_TRAILING_28D / 28,
             inventory.FORECAST_QTY_NEXT_28D / inventory.FORECAST_DAYS_COVERED)
      COMMENT = 'Average daily demand (contract v1.2 §5) = forecast qty over the days the run covers / those days; fallback trailing 28-day shipped qty / 28 (DEMAND_FALLBACK).',
    PRIVATE inventory.has_doi_evidence_gap
      AS inventory.is_demand_fallback OR inventory.daily_demand_qty = 0
         OR ARRAY_CONTAINS('NEGATIVE_STOCK'::VARIANT, inventory.DQ_FLAGS)
      COMMENT = 'TRUE when the row carries DEMAND_FALLBACK, NO_DEMAND or NEGATIVE_STOCK.',

    -- ---------------- goods_receipts: Landed Cost per Unit (§6) ----------------
    PRIVATE goods_receipts.is_landed_cost_population
      AS purchase_order_lines.is_stock_part_line AND goods_receipts.PART_NO IS NOT NULL
         AND goods_receipts.UNIT_PRICE_AMT > 0
      COMMENT = 'Population of Landed Cost per Unit: receipts of stocked, mapped parts on priced PO lines (excludes service / non-stock receipts, unpriced samples and amounts without FX). No intercompany receipts exist in CONFORMED.',
    PRIVATE goods_receipts.receipt_qty
      AS goods_receipts.RECEIVED_QTY
      COMMENT = 'Received qty, base UoM. No return-to-vendor reversal documents exist in CONFORMED yet, so nothing is netted.',
    PRIVATE goods_receipts.receipt_product_cost_amt
      AS goods_receipts.UNIT_PRICE_AMT * goods_receipts.RECEIVED_QTY
      COMMENT = 'Invoiced unit price (PO price when PROVISIONAL) x received qty, USD.',
    PRIVATE goods_receipts.receipt_landed_cost_amt
      AS goods_receipts.receipt_product_cost_amt + COALESCE(goods_receipts.FREIGHT_AMT, 0)
         + COALESCE(goods_receipts.ACCESSORIAL_AMT, 0) + COALESCE(goods_receipts.DUTY_AMT, 0)
         + COALESCE(goods_receipts.INSURANCE_AMT, 0)
      COMMENT = 'Total landed cost of the receipt = product cost + allocated freight + accessorials + non-recoverable duties + insurance, USD. Missing components count as 0 and the receipt is PROVISIONAL.',
    PRIVATE goods_receipts.is_unmapped_stock_receipt
      AS purchase_order_lines.is_stock_part_line AND goods_receipts.PART_NO IS NULL
         AND goods_receipts.UNIT_PRICE_AMT > 0
      COMMENT = 'Priced receipt on a stock PO line whose supplier part number maps to no ERP part (UNMAPPED_PART): outside the landed-cost population, counted as not covered.',
    PRIVATE goods_receipts.has_landed_cost_evidence_gap
      AS goods_receipts.IS_PROVISIONAL OR ARRAY_CONTAINS('ALLOC_BY_VALUE'::VARIANT, goods_receipts.DQ_FLAGS)
      COMMENT = 'TRUE when price, freight or duty is estimated / missing (PROVISIONAL) or freight was allocated by value (ALLOC_BY_VALUE).'
  )

  DIMENSIONS (
    -- order_lines
    order_lines.so_no AS order_lines.SO_NO
      WITH SYNONYMS ('sales order number', 'SO number', 'customer order number')
      COMMENT = 'Sales order number (natural key part 1).',
    order_lines.line_no AS order_lines.LINE_NO
      COMMENT = 'Line number on the sales order (natural key part 2).',
    order_lines.order_line_commit_date AS order_lines.FIRST_COMMIT_DATE
      WITH SYNONYMS ('customer commit date', 'first commit date')
      COMMENT = 'Commit date (§1.1): first confirmed date, reset only by a customer-requested change. Time anchor of Customer OTD % and Fill Rate %.',
    order_lines.order_line_requested_date AS order_lines.REQUESTED_DATE
      WITH SYNONYMS ('customer requested date')
      COMMENT = 'Date the customer asked for. Not the commit date and not used by any canonical metric.',
    order_lines.sales_order_date AS order_lines.ORDER_DATE
      COMMENT = 'Order date of the sales order (Time role: order date, volume reporting).',
    order_lines.order_line_type AS order_lines.LINE_TYPE
      COMMENT = 'STANDARD, RETURN or FREE_OF_CHARGE. Only STANDARD lines are in the OTD / Fill Rate population.',
    order_lines.order_line_status AS order_lines.LINE_STATUS
      COMMENT = 'ERP line status: OPEN, PARTIALLY_SHIPPED, SHIPPED, DELIVERED, CLOSED_SHORT, CANCELLED, CLOSED.',
    order_lines.order_line_reschedule_reason AS order_lines.RESCHEDULE_REASON
      COMMENT = 'Reason of the latest reschedule (CUSTOMER_REQUEST, MATERIAL_SHORTAGE, CAPACITY). Only CUSTOMER_REQUEST resets the commit date.',
    order_lines.order_line_complete_arrival_date AS order_lines.COMPLETE_ARRIVAL_LOCAL_DATE
      COMMENT = 'Customer-local date the line became complete (cumulative arrived qty >= required qty). NULL while incomplete.',
    order_lines.is_due_order_line AS order_lines.is_due_line
      COMMENT = 'TRUE when the line counts in the Customer OTD % / Fill Rate % denominator (population, commit date <= as-of date).',
    order_lines.is_on_time_order_line AS IFF(order_lines.is_due_line, order_lines.is_on_time_line, NULL)
      COMMENT = 'Per due line: TRUE = arrived complete within [commit - 1, commit]; FALSE = late (incl. partial or no arrival evidence); NULL = not a due line.',
    order_lines.order_line_has_no_arrival_evidence AS order_lines.has_arrival_gap
      COMMENT = 'DQ flag NO_ARRIVAL_EVIDENCE: a shipment of the line has no IoT / POD arrival.',
    order_lines.order_line_has_tz_fallback AS ARRAY_CONTAINS('TZ_FALLBACK'::VARIANT, order_lines.DQ_FLAGS)
      COMMENT = 'DQ flag TZ_FALLBACK: customer ship-to time zone unknown, shipping plant zone used.',
    order_lines.order_line_has_substitution AS ARRAY_CONTAINS('SUBSTITUTION'::VARIANT, order_lines.DQ_FLAGS)
      COMMENT = 'DQ flag SUBSTITUTION: a different part was shipped (counts as unfilled).',

    -- shipments
    shipments.shipment_no AS shipments.SHIPMENT_NO
      WITH SYNONYMS ('shipment number', 'load number')
      COMMENT = 'TMS shipment id.',
    shipments.scac AS shipments.SCAC
      WITH SYNONYMS ('carrier code', 'carrier SCAC', 'carrier')
      COMMENT = 'Standard Carrier Alpha Code of the carrier that moved the shipment (plain attribute; no carrier table in this view).',
    shipments.shipment_arrival_source AS shipments.ARRIVAL_SOURCE
      COMMENT = 'Arrival evidence used: IOT_GEOFENCE, CARRIER_POD, or NULL when there is no evidence.',
    shipments.shipment_arrival_date AS shipments.ARRIVAL_LOCAL_DATE
      COMMENT = 'Arrival date in the customer ship-to time zone.',
    shipments.shipment_goods_issue_date AS shipments.GOODS_ISSUE_DATE
      COMMENT = 'ERP goods-issue (ship) date, plant-local.',
    shipments.shipment_is_substitution AS shipments.IS_SUBSTITUTION
      COMMENT = 'TRUE when a different part than ordered was shipped.',

    -- purchase_order_lines
    purchase_order_lines.po_no AS purchase_order_lines.PO_NO
      WITH SYNONYMS ('PO number', 'purchase order number')
      COMMENT = 'Purchase order number (natural key part 1).',
    purchase_order_lines.po_line_no AS purchase_order_lines.PO_LINE_NO
      COMMENT = 'PO line number (natural key part 2).',
    purchase_order_lines.po_line_commit_date AS purchase_order_lines.FIRST_COMMIT_DATE
      WITH SYNONYMS ('supplier commit date', 'supplier first confirmed date')
      COMMENT = 'Supplier commit date (§1.1): first supplier confirmation, reset only by a buyer-requested change; PO due date when never confirmed (UNCONFIRMED). Time anchor of Supplier OTD %.',
    purchase_order_lines.po_date AS purchase_order_lines.PO_DATE
      COMMENT = 'PO order date (Time role: order date).',
    purchase_order_lines.po_item_category AS purchase_order_lines.ITEM_CATEGORY
      COMMENT = 'STOCK, NON_STOCK or SERVICE. Only STOCK lines are in the Supplier OTD / Landed Cost population.',
    purchase_order_lines.po_incoterm AS purchase_order_lines.INCOTERM
      COMMENT = 'Incoterm of the PO line (EXW, FCA, FOB, CIF, DAP, DDP).',
    purchase_order_lines.po_line_complete_arrival_date AS purchase_order_lines.COMPLETE_ARRIVAL_LOCAL_DATE
      COMMENT = 'Plant-local date the PO line became complete (arrival from IoT geofence, then carrier POD, else GR posting date = GR_FALLBACK). NULL while incomplete.',
    purchase_order_lines.po_line_complete_arrival_source AS purchase_order_lines.COMPLETE_ARRIVAL_SOURCE
      WITH SYNONYMS ('inbound arrival source', 'arrival evidence source')
      COMMENT = 'Arrival evidence of the ASN that completed the PO line: IOT_GEOFENCE, CARRIER_POD or GR_POSTING (GR_FALLBACK, lower confidence). NULL while incomplete.',
    purchase_order_lines.is_due_po_line_flag AS purchase_order_lines.is_due_po_line
      COMMENT = 'TRUE when the PO line counts in the Supplier OTD % denominator.',
    purchase_order_lines.is_on_time_po_line_flag AS IFF(purchase_order_lines.is_due_po_line, purchase_order_lines.is_on_time_po_line, NULL)
      COMMENT = 'Per due PO line: TRUE = arrived complete within [commit - 1, commit]; FALSE = late; NULL = not due.',
    purchase_order_lines.po_contract_no AS purchase_order_lines.CONTRACT_NO
      WITH SYNONYMS ('governing contract')
      COMMENT = 'Governing contract of the PO line (via its supplier part, R6); NULL = no contract.',
    purchase_order_lines.po_line_latest_confirmed_date AS purchase_order_lines.contract_due_date_key
      WITH SYNONYMS ('latest confirmed date', 'supplier latest confirmed date')
      COMMENT = 'Latest supplier-confirmed date (PO due date if never confirmed). Time anchor of Supplier Contractual OTD % only; Supplier OTD % uses po_line_commit_date.',
    purchase_order_lines.po_line_contract_grace_days AS purchase_order_lines.CONTRACT_LATE_GRACE_DAYS
      COMMENT = 'Late-delivery grace days of the governing contract.',
    purchase_order_lines.po_line_is_in_contract_validity AS purchase_order_lines.is_in_contract_validity
      WITH SYNONYMS ('in contract validity', 'strict contract view')
      COMMENT = 'TRUE = PO ordered inside the contract validity; FALSE = pro-forma. Filter TRUE only when the user asks for the strict / in-validity view.',
    purchase_order_lines.is_contractual_on_time_po_line_flag AS IFF(purchase_order_lines.is_contractual_due_po_line, purchase_order_lines.is_contractual_on_time_po_line, NULL)
      COMMENT = 'Per contractual due PO line: TRUE = complete by latest confirmed date + grace days; FALSE = late; NULL = not in the contractual population.',
    purchase_order_lines.po_line_is_unconfirmed AS purchase_order_lines.IS_UNCONFIRMED
      COMMENT = 'DQ flag UNCONFIRMED: supplier never confirmed; commit = PO due date.',

    -- goods_receipts
    goods_receipts.gr_no AS goods_receipts.GR_NO
      WITH SYNONYMS ('goods receipt number', 'GR number')
      COMMENT = 'ERP goods-receipt document.',
    goods_receipts.gr_posting_date AS goods_receipts.POSTING_DATE
      WITH SYNONYMS ('receipt date', 'GR date')
      COMMENT = 'GR posting date, plant-local. Time anchor of Landed Cost per Unit.',
    goods_receipts.gr_is_import AS goods_receipts.IS_IMPORT
      COMMENT = 'TRUE when supplier country differs from the receiving plant country.',
    goods_receipts.gr_is_provisional AS goods_receipts.IS_PROVISIONAL
      COMMENT = 'DQ flag PROVISIONAL: price, freight or duty estimated or missing.',
    goods_receipts.gr_arrival_source AS goods_receipts.ARRIVAL_SOURCE
      COMMENT = 'Arrival evidence of the receipt: IOT_GEOFENCE, CARRIER_POD or GR_POSTING (GR_FALLBACK).',
    goods_receipts.gr_freight_alloc_basis AS goods_receipts.FREIGHT_ALLOC_BASIS
      COMMENT = 'Freight allocation basis: SINGLE_LINE, WEIGHT or ALLOC_BY_VALUE.',

    -- inventory
    inventory.inventory_snapshot_date AS inventory.SNAPSHOT_DATE
      WITH SYNONYMS ('snapshot date', 'stock date')
      COMMENT = 'Plant-local end-of-day snapshot date. Time anchor of Days of Inventory.',
    inventory.snapshot_date AS inventory.SNAPSHOT_DATE
      WITH SYNONYMS ('inventory as-of date', 'stock snapshot date')
      COMMENT = 'Plant-local snapshot date as a DIMENSION (same column as inventory_snapshot_date). Grouping DOI by it returns one value per snapshot date: for "now" keep only the latest date (ORDER BY snapshot_date DESC LIMIT 1, or QUALIFY per plant), or use the METRIC DOI_SNAPSHOT_DATE instead.',
    inventory.inventory_base_uom AS inventory.BASE_UOM
      COMMENT = 'Base unit of measure of the inventory quantities.',
    inventory.is_demand_fallback_snapshot AS inventory.is_demand_fallback
      COMMENT = 'DQ flag DEMAND_FALLBACK: demand from trailing 28-day shipments because no forecast exists.',

    -- suppliers
    suppliers.supplier_no AS suppliers.SUPPLIER_NO
      WITH SYNONYMS ('vendor number', 'supplier number')
      COMMENT = 'Supplier natural key (ERP vendor number).',
    suppliers.supplier_name AS suppliers.SUPPLIER_NAME
      WITH SYNONYMS ('vendor name', 'supplier')
      COMMENT = 'Supplier legal name.',
    suppliers.supplier_country AS suppliers.COUNTRY_CODE
      COMMENT = 'ISO country of the supplier.',
    suppliers.supplier_region AS suppliers.REGION
      WITH SYNONYMS ('vendor region')
      COMMENT = 'Company region of the supplier (NA = Americas).',

    -- contracts (terms from the signed PDF; R5 contracts -> suppliers)
    contracts.contract_no AS contracts.CONTRACT_NO
      WITH SYNONYMS ('contract number', 'agreement number')
      COMMENT = 'Contract natural key as printed on the signed PDF, e.g. CTR-S0011-2026.',
    contracts.contract_supplier_name AS contracts.SUPPLIER_NAME_ON_CONTRACT
      COMMENT = 'Supplier name as printed on the contract.',
    contracts.contract_valid_from AS contracts.VALID_FROM
      WITH SYNONYMS ('contract effective date', 'contract start date')
      COMMENT = 'Contract effective date.',
    contracts.contract_valid_to AS contracts.VALID_TO
      WITH SYNONYMS ('contract end date', 'contract expiry date')
      COMMENT = 'Last day the contract is valid.',
    contracts.contract_delivery_target AS contracts.DELIVERY_TARGET_FRACTION
      WITH SYNONYMS ('contracted delivery target', 'contractual delivery performance target')
      COMMENT = 'Contracted on-time delivery target as a 0-1 fraction of PO lines (show x 100 as %). A contract TERM, not a measured metric, and NOT comparable with SUPPLIER_OTD_PCT (the contract measures against the confirmed date with grace days; Supplier OTD % uses the first commit date and a [-1, 0] day window).',
    contracts.contract_delivery_target_basis AS contracts.DELIVERY_TARGET_BASIS
      COMMENT = 'How the contract says the delivery target is measured (e.g. monthly).',
    contracts.contract_lead_time_days AS contracts.LEAD_TIME_DAYS
      WITH SYNONYMS ('contracted lead time', 'contract lead time')
      COMMENT = 'Contracted standard lead time in calendar days, counted from contract_lead_time_basis.',
    contracts.contract_lead_time_basis AS contracts.LEAD_TIME_BASIS
      COMMENT = 'Event the contracted lead time is counted from (e.g. PO acknowledgement).',
    contracts.contract_late_grace_days AS contracts.LATE_GRACE_DAYS
      COMMENT = 'Days after the confirmed date a PO line may arrive before the late-delivery penalty applies.',
    contracts.contract_late_penalty_per_day AS contracts.LATE_PENALTY_PER_DAY_FRACTION
      COMMENT = 'Late-delivery credit per day late, 0-1 fraction of the line value (show x 100 as %).',
    contracts.contract_late_penalty_cap AS contracts.LATE_PENALTY_CAP_FRACTION
      COMMENT = 'Cap of the late-delivery credit, 0-1 fraction of the line value (show x 100 as %).',
    contracts.contract_penalty_clause AS contracts.PENALTY_CLAUSE_TEXT
      WITH SYNONYMS ('penalty clause', 'late delivery penalty')
      COMMENT = 'Late-delivery penalty clause as worded in the signed PDF. For other wording questions use the contract search service.',
    contracts.contract_incoterm AS contracts.INCOTERM
      COMMENT = 'Contracted Incoterm (three-letter code, Incoterms 2020).',
    contracts.contract_currency AS contracts.CURRENCY
      COMMENT = 'Contract currency.',
    contracts.contract_payment_terms AS contracts.PAYMENT_TERMS
      COMMENT = 'Contracted payment terms (e.g. NET60).',
    contracts.contract_doc_file_path AS contracts.DOC_FILE_PATH
      COMMENT = 'Signed PDF on @SC.RAW_DOCS.CONTRACTS (legal source).',
    contracts.contract_has_payment_terms_mismatch AS ARRAY_CONTAINS('PAYMENT_TERMS_MISMATCH'::VARIANT, contracts.DQ_FLAGS)
      COMMENT = 'DQ flag PAYMENT_TERMS_MISMATCH: PDF payment terms differ from the supplier master (neither side overwritten).',
    contracts.contract_has_incoterm_mismatch AS ARRAY_CONTAINS('INCOTERM_MISMATCH_PO_LINES'::VARIANT, contracts.DQ_FLAGS)
      COMMENT = 'DQ flag INCOTERM_MISMATCH_PO_LINES: some PO lines of the supplier use a different Incoterm than the contract.',
    contracts.contract_has_lead_time_mismatch AS ARRAY_CONTAINS('LEAD_TIME_MISMATCH_SUPPLIER_PARTS'::VARIANT, contracts.DQ_FLAGS)
      COMMENT = 'DQ flag LEAD_TIME_MISMATCH_SUPPLIER_PARTS: some supplier parts quote a different lead time than the contract.',

    -- supplier_parts (R6 supplier_parts -> contracts)
    supplier_parts.supplier_part_no AS supplier_parts.SUPPLIER_PART_NO
      WITH SYNONYMS ('supplier part number', 'vendor part number')
      COMMENT = 'Part number in the supplier''s format.',
    supplier_parts.supplier_part_supplier_no AS supplier_parts.SUPPLIER_NO
      COMMENT = 'Supplier of the sourcing record (ERP vendor number). Plain attribute: the join to suppliers runs through contracts (R6, R5).',
    supplier_parts.supplier_part_part_no AS supplier_parts.PART_NO
      COMMENT = 'ERP part the supplier is approved to supply; NULL when the supplier part number maps to no ERP part.',
    supplier_parts.supplier_part_contract_no AS supplier_parts.CONTRACT_NO
      COMMENT = 'Governing contract (R6); NULL = spot buy, no contract.',
    supplier_parts.supplier_part_lead_time_days AS supplier_parts.LEAD_TIME_DAYS
      WITH SYNONYMS ('quoted lead time')
      COMMENT = 'Lead time quoted by the supplier for this part (can differ from the contracted lead time).',
    supplier_parts.supplier_part_moq AS supplier_parts.MOQ
      COMMENT = 'Minimum order quantity in base UoM.',
    supplier_parts.supplier_part_is_preferred AS supplier_parts.IS_PREFERRED
      COMMENT = 'TRUE for the preferred (rank 1) source of the part.',

    -- parts (Part hierarchy)
    parts.part_no AS parts.PART_NO
      WITH SYNONYMS ('SKU', 'material number', 'part number', 'item number')
      COMMENT = 'Part hierarchy level 3 (leaf, SKU). Parent: part_family.',
    parts.part_description AS parts.DESCRIPTION
      COMMENT = 'Material description.',
    parts.part_family AS parts.FAMILY
      WITH SYNONYMS ('product family')
      COMMENT = 'Part hierarchy level 2. Parent: part_category.',
    parts.part_category AS parts.CATEGORY
      WITH SYNONYMS ('category', 'product category', 'material group')
      COMMENT = 'Part hierarchy level 1 (top). UNMAPPED PART = PO lines / receipts whose supplier part number maps to no ERP part (excluded from Landed Cost per Unit / Uplift %, counted in LANDED_COST_UNMAPPED_PART_RECEIPTS).',
    parts.part_base_uom AS parts.BASE_UOM
      COMMENT = 'Base unit of measure (EA, L).',
    parts.is_stocked AS parts.IS_STOCKED
      COMMENT = 'TRUE for stocked parts; non-stock / expense parts are excluded from DOI, Supplier OTD and Landed Cost.',

    -- plants (Geography hierarchy)
    plants.plant_code AS plants.PLANT_CODE
      WITH SYNONYMS ('plant', 'site code')
      COMMENT = 'Geography hierarchy level 3 (leaf). Parent: plant_country.',
    plants.plant_name AS plants.PLANT_NAME
      WITH SYNONYMS ('site name', 'facility name')
      COMMENT = 'Plant name, e.g. Pune Assembly.',
    plants.plant_city AS plants.CITY
      COMMENT = 'City of the plant.',
    plants.plant_country AS plants.COUNTRY_CODE
      WITH SYNONYMS ('country')
      COMMENT = 'Geography hierarchy level 2 (ISO 3166-1 alpha-2). Parent: plant_region.',
    plants.plant_region AS plants.REGION
      WITH SYNONYMS ('region', 'geography')
      COMMENT = 'Geography hierarchy level 1: AMER (shown as NA), EMEA, APAC. Default meaning of "region".',
    plants.plant_type AS plants.PLANT_TYPE
      COMMENT = 'MANUFACTURING or DISTRIBUTION.',

    -- customers (Customer hierarchy)
    customers.customer_no AS customers.CUSTOMER_NO
      WITH SYNONYMS ('customer number', 'sold-to number')
      COMMENT = 'Customer hierarchy level 2 (leaf). Parent: customer_segment.',
    customers.customer_name AS customers.CUSTOMER_NAME
      COMMENT = 'Customer name.',
    customers.customer_segment AS customers.SEGMENT
      WITH SYNONYMS ('segment', 'customer group')
      COMMENT = 'Customer hierarchy level 1: Strategic, Key Account, Distributor, SMB, Intercompany.',
    customers.customer_country AS customers.COUNTRY_CODE
      COMMENT = 'ISO country of the ship-to.',
    customers.customer_region AS customers.REGION
      COMMENT = 'Company region of the customer ship-to.',
    customers.is_intercompany AS customers.IS_INTERCOMPANY
      COMMENT = 'TRUE for intercompany sold-to parties (excluded from Customer OTD % and Fill Rate %).',

    -- dates (Time hierarchy, 4-4-5 fiscal; calendar attributes as a separate path)
    dates.calendar_date AS dates."DATE"
      WITH SYNONYMS ('day', 'date')
      COMMENT = 'Time hierarchy leaf (day). Means the time anchor of the metric queried: commit date (Customer OTD, Fill Rate, Supplier OTD), GR posting date (Landed Cost), snapshot date (DOI).',
    dates.fiscal_week AS dates.FISCAL_WEEK
      WITH SYNONYMS ('week', 'fiscal week')
      COMMENT = 'Fiscal week 1-53 (ISO week). Parent: fiscal_month.',
    dates.fiscal_month AS dates.FISCAL_PERIOD
      WITH SYNONYMS ('month', 'fiscal month', 'fiscal period')
      COMMENT = 'Fiscal month 1-12 on a 4-4-5 pattern (week 53 joins month 12). Parent: fiscal_quarter. Default meaning of "month".',
    dates.fiscal_month_label AS dates.FISCAL_PERIOD_LABEL
      COMMENT = 'Fiscal month label, e.g. FY2026-P09. Unique across years; use for monthly trends.',
    dates.fiscal_quarter AS dates.FISCAL_QUARTER
      WITH SYNONYMS ('quarter', 'fiscal quarter')
      COMMENT = 'Fiscal quarter 1-4 (13 weeks; 14 in a 53-week year). Parent: fiscal_year.',
    dates.fiscal_year AS dates.FISCAL_YEAR
      WITH SYNONYMS ('year', 'fiscal year', 'FY')
      COMMENT = 'Fiscal year = ISO week-numbering year (top of the Time hierarchy).',
    dates.calendar_month AS dates.MONTH
      WITH SYNONYMS ('calendar month')
      COMMENT = 'Calendar month 1-12. Use only when the user names a calendar month (e.g. September 2026); combine with calendar_year.',
    dates.calendar_month_name AS dates.MONTH_NAME
      COMMENT = 'Calendar month abbreviation (Jan..Dec).',
    dates.calendar_quarter AS dates.QUARTER
      WITH SYNONYMS ('calendar quarter')
      COMMENT = 'Calendar quarter 1-4.',
    dates.calendar_year AS dates.YEAR
      WITH SYNONYMS ('calendar year')
      COMMENT = 'Calendar year.',
    dates.fiscal_quarter_label AS dates.FISCAL_QUARTER_LABEL
      COMMENT = 'Fiscal quarter label, e.g. FY2026-Q3. Unique across years.',
    dates.fiscal_month_start_date AS dates.FISCAL_PERIOD_START_DATE
      COMMENT = 'First day of the fiscal month. Return with fiscal_month_label so answers state the dates used.',
    dates.fiscal_month_end_date AS dates.FISCAL_PERIOD_END_DATE
      COMMENT = 'Last day of the fiscal month.',
    dates.fiscal_quarter_start_date AS dates.FISCAL_QUARTER_START_DATE
      COMMENT = 'First day of the fiscal quarter.',
    dates.fiscal_quarter_end_date AS dates.FISCAL_QUARTER_END_DATE
      COMMENT = 'Last day of the fiscal quarter.',
    dates.fiscal_week_offset AS dates.FISCAL_WEEK_OFFSET
      WITH SYNONYMS ('weeks ago', 'relative week')
      COMMENT = 'Fiscal weeks relative to today: 0 = this week, -1 = last week. Use for relative week questions.',
    dates.fiscal_month_offset AS dates.FISCAL_MONTH_OFFSET
      WITH SYNONYMS ('months ago', 'relative month')
      COMMENT = 'Fiscal months (4-4-5 periods) relative to today: 0 = this month, -1 = last month, BETWEEN -N AND -1 = last N completed months. Use for every relative month question.',
    dates.fiscal_quarter_offset AS dates.FISCAL_QUARTER_OFFSET
      WITH SYNONYMS ('quarters ago', 'relative quarter')
      COMMENT = 'Fiscal quarters relative to today: 0 = this quarter, -1 = last quarter.',
    dates.fiscal_year_offset AS dates.FISCAL_YEAR_OFFSET
      WITH SYNONYMS ('years ago', 'relative year')
      COMMENT = 'Fiscal years relative to today: 0 = this fiscal year (YTD), -1 = last fiscal year.',
    dates.fiscal_week_label AS dates.FISCAL_WEEK_LABEL
      COMMENT = 'Fiscal week label, e.g. FY2026-W39. Return with fiscal_week_start_date / fiscal_week_end_date for week questions.',
    dates.fiscal_week_start_date AS dates.WEEK_START_DATE
      COMMENT = 'First day (Monday) of the fiscal week.',
    dates.fiscal_week_end_date AS dates.FISCAL_WEEK_END_DATE
      COMMENT = 'Last day (Sunday) of the fiscal week.',
    dates.fiscal_year_label AS dates.FISCAL_YEAR_LABEL
      COMMENT = 'Fiscal year label, e.g. FY2026. Return with fiscal_year_start_date / fiscal_year_end_date for year questions.',
    dates.fiscal_year_start_date AS dates.FISCAL_YEAR_START_DATE
      COMMENT = 'First day of the fiscal year (Monday of ISO week 1).',
    dates.fiscal_year_end_date AS dates.FISCAL_YEAR_END_DATE
      COMMENT = 'Last day of the fiscal year.',
    dates.calendar_month_label AS dates.CALENDAR_MONTH_LABEL
      COMMENT = 'Calendar month label, e.g. Sep 2026. Use when the user names a calendar month, and ALWAYS for Supplier Contractual OTD % / Gap; say "calendar month, not fiscal" in the answer.',
    dates.calendar_month_start_date AS dates.CALENDAR_MONTH_START_DATE
      COMMENT = 'First day of the calendar month.',
    dates.calendar_month_end_date AS dates.CALENDAR_MONTH_END_DATE
      COMMENT = 'Last day of the calendar month.',
    dates.calendar_month_offset AS dates.CALENDAR_MONTH_OFFSET
      COMMENT = 'Calendar months relative to today: 0 = current calendar month, -1 = last complete calendar month. Period filter of Supplier Contractual OTD % / Gap (contract v1.4 §3.1); fiscal metrics use fiscal_month_offset.'
  )

  METRICS (
    -- ---------------- Customer OTD % (contract §2) ----------------
    order_lines.customer_otd_pct
      AS (COUNT_IF(order_lines.is_on_time_line) / NULLIF(COUNT_IF(order_lines.is_due_line), 0))::NUMBER(9,6)
      WITH SYNONYMS ('on-time delivery', 'OTD', 'OTD %', 'on-time', 'customer on-time delivery', 'outbound OTD',
                     'on-time to commit', 'delivery reliability', 'line-level OTIF')
      COMMENT = 'Customer OTD % (contract v1.2 §2): share of due customer order lines that arrived complete within [commit - 1 day, commit] of the first commit date. = ON_TIME_LINES / DUE_LINES, 0-1 fraction, NULL when no due lines. Default meaning of unqualified on-time delivery / OTD. Partial = late, so this is line-level OTIF. Publish with OUTBOUND_ARRIVAL_EVIDENCE_COVERAGE_PCT.',
    order_lines.on_time_lines
      AS COUNT_IF(order_lines.is_on_time_line)
      COMMENT = 'Customer OTD % numerator: due order lines arrived complete within the on-time window.',
    order_lines.due_lines
      AS COUNT_IF(order_lines.is_due_line)
      COMMENT = 'Customer OTD % denominator: order lines in population with commit date in the period and <= as-of date, including open lines.',

    -- ---------------- Fill Rate % (contract §4) ----------------
    order_lines.fill_rate_pct
      AS (SUM(IFF(order_lines.is_due_line, order_lines.line_filled_qty, NULL))
          / NULLIF(SUM(IFF(order_lines.is_due_line, order_lines.line_required_qty, NULL)), 0))::NUMBER(9,6)
      WITH SYNONYMS ('fill rate', 'unit fill rate', 'customer fill rate', 'demand fill rate', 'quantity fill rate')
      COMMENT = 'Fill Rate % (contract v1.2 §4): share of required qty that reached the customer by the commit date = FILL_RATE_FILLED_QTY / FILL_RATE_REQUIRED_QTY over due lines (same population as Customer OTD %), 0-1 fraction, NULL when empty. Per line filled = MIN(arrived by commit, required); early arrivals count, substitutes do not. Not trailer utilization.',
    order_lines.fill_rate_filled_qty
      AS SUM(IFF(order_lines.is_due_line, order_lines.line_filled_qty, NULL))
      COMMENT = 'Fill Rate % numerator: sum over due lines of MIN(qty arrived by commit date, required qty), base UoM.',
    order_lines.fill_rate_required_qty
      AS SUM(IFF(order_lines.is_due_line, order_lines.line_required_qty, NULL))
      COMMENT = 'Fill Rate % denominator: sum of required qty (ordered - customer-cancelled) over due lines, base UoM.',

    -- ---------------- outbound evidence / DQ ----------------
    order_lines.outbound_arrival_evidence_coverage_pct
      AS (COUNT_IF(order_lines.is_due_line AND NOT order_lines.has_arrival_gap) / NULLIF(COUNT_IF(order_lines.is_due_line), 0))::NUMBER(9,6)
      COMMENT = 'Evidence coverage of Customer OTD % and Fill Rate % (same population): share of due lines not flagged NO_ARRIVAL_EVIDENCE. 0-1 fraction.',
    order_lines.no_arrival_evidence_lines
      AS COUNT_IF(order_lines.is_due_line AND order_lines.has_arrival_gap)
      COMMENT = 'Due lines flagged NO_ARRIVAL_EVIDENCE (kept in the denominator, never on time, filled qty 0).',
    order_lines.no_commit_lines
      AS COUNT_IF(order_lines.is_no_commit_line)
      COMMENT = 'Population lines excluded because they have no commit date (NO_COMMIT, DQ summary).',
    order_lines.due_lines_first_commit_date
      AS MIN(IFF(order_lines.is_due_line, order_lines.FIRST_COMMIT_DATE, NULL))
      COMMENT = 'Data range start (contract v1.3.1 section 7.1) of Customer OTD % and Fill Rate %: earliest commit date among the due lines in the query scope. Return it with every no-period answer.',
    order_lines.due_lines_last_commit_date
      AS MAX(IFF(order_lines.is_due_line, order_lines.FIRST_COMMIT_DATE, NULL))
      COMMENT = 'Data range end of Customer OTD % and Fill Rate %: latest commit date among the due lines in the query scope (never after today).',

    -- ---------------- Supplier OTD % (contract §3) ----------------
    purchase_order_lines.supplier_otd_pct
      USING (po_line_to_commit_date)
      AS (COUNT_IF(purchase_order_lines.is_on_time_po_line) / NULLIF(COUNT_IF(purchase_order_lines.is_due_po_line), 0))::NUMBER(9,6)
      WITH SYNONYMS ('supplier OTD', 'vendor OTD', 'vendor on-time delivery', 'inbound OTD', 'supplier on-time',
                     'supplier delivery performance', 'supplier line-level OTIF')
      COMMENT = 'Supplier OTD % (contract v1.2 §3): share of due PO lines that arrived complete at the receiving plant within [commit - 1 day, commit] of the first supplier confirmation. = ON_TIME_PO_LINES / DUE_PO_LINES, 0-1 fraction, NULL when empty. Arrival per ASN = IoT geofence entry, then carrier POD, else GR posting date (GR_FALLBACK, lower confidence: GR lags arrival by 0-5 days and can understate OTD). Only for explicit supplier / vendor / inbound questions. Publish with SUPPLIER_OTD_EVIDENCE_COVERAGE_PCT and SUPPLIER_OTD_GR_FALLBACK_PCT.',
    purchase_order_lines.on_time_po_lines
      USING (po_line_to_commit_date)
      AS COUNT_IF(purchase_order_lines.is_on_time_po_line)
      COMMENT = 'Supplier OTD % numerator: due PO lines arrived complete within the on-time window.',
    purchase_order_lines.due_po_lines
      USING (po_line_to_commit_date)
      AS COUNT_IF(purchase_order_lines.is_due_po_line)
      COMMENT = 'Supplier OTD % denominator: PO lines in population with supplier commit date in the period and <= as-of date, including open lines.',
    purchase_order_lines.supplier_otd_evidence_coverage_pct
      USING (po_line_to_commit_date)
      AS (COUNT_IF(purchase_order_lines.is_due_po_line AND NOT purchase_order_lines.has_no_arrival_evidence)
          / NULLIF(COUNT_IF(purchase_order_lines.is_due_po_line), 0))::NUMBER(9,6)
      COMMENT = 'Evidence coverage of Supplier OTD % (contract v1.2 §1.3): share of due PO lines not flagged NO_ARRIVAL_EVIDENCE. GR posting fallback counts as evidence. 0-1 fraction.',
    purchase_order_lines.supplier_otd_gr_fallback_pct
      USING (po_line_to_commit_date)
      AS (COUNT_IF(purchase_order_lines.is_due_po_line AND purchase_order_lines.is_gr_fallback)
          / NULLIF(COUNT_IF(purchase_order_lines.is_due_po_line), 0))::NUMBER(9,6)
      COMMENT = 'GR-fallback share of Supplier OTD % (contract v1.2 §3): due PO lines whose arrival is the ERP GR posting date (GR_FALLBACK, can understate OTD by 1-2 days) / due PO lines. 0-1 fraction.',
    purchase_order_lines.unmapped_part_po_lines
      USING (po_line_to_commit_date)
      AS COUNT_IF(purchase_order_lines.is_unmapped_stock_line)
      COMMENT = 'Stock PO lines whose supplier part number maps to no ERP part (UNMAPPED_PART). Kept in Supplier OTD %; excluded from Landed Cost per Unit / Uplift % and counted against their evidence coverage.',
    purchase_order_lines.due_po_lines_first_commit_date
      USING (po_line_to_commit_date)
      AS MIN(IFF(purchase_order_lines.is_due_po_line, purchase_order_lines.FIRST_COMMIT_DATE, NULL))
      COMMENT = 'Data range start (contract v1.3.1 section 7.1) of Supplier OTD %: earliest supplier commit date among the due PO lines in the query scope. Return it with every no-period answer.',
    purchase_order_lines.due_po_lines_last_commit_date
      USING (po_line_to_commit_date)
      AS MAX(IFF(purchase_order_lines.is_due_po_line, purchase_order_lines.FIRST_COMMIT_DATE, NULL))
      COMMENT = 'Data range end of Supplier OTD %: latest supplier commit date among the due PO lines in the query scope (never after today).',

    -- ---------------- Supplier Contractual OTD % and Gap (contract v1.4 §3.1; named variant, NOT canonical) ----------------
    -- Joined to dates on the latest confirmed date (calendar months). Pro-forma: contract terms apply to every
    -- PO line of a contracted supplier; po_line_is_in_contract_validity = TRUE gives the strict view.
    purchase_order_lines.supplier_contractual_otd_pct
      USING (po_line_to_latest_confirmed_date)
      AS (COUNT_IF(purchase_order_lines.is_contractual_on_time_po_line) / NULLIF(COUNT_IF(purchase_order_lines.is_contractual_due_po_line), 0))::NUMBER(9,6)
      WITH SYNONYMS ('contractual OTD', 'OTD vs contract', 'supplier contractual OTD', 'contractual on-time delivery', 'on-time vs contract')
      COMMENT = 'Supplier Contractual OTD % (contract v1.4 §3.1, a named variant, NOT canonical): share of contracted-supplier PO lines whose full qty arrived on or before the latest confirmed date + the contract grace days (early = on time). = CONTRACTUAL_ON_TIME_PO_LINES / CONTRACTUAL_DUE_PO_LINES, 0-1 fraction, NULL when empty. Calendar months on the latest confirmed date. Only for "contractual OTD", "OTD vs contract" or "below contracted target" questions; never for plain OTD or supplier OTD.',
    purchase_order_lines.contractual_on_time_po_lines
      USING (po_line_to_latest_confirmed_date)
      AS COUNT_IF(purchase_order_lines.is_contractual_on_time_po_line)
      COMMENT = 'Supplier Contractual OTD % numerator: contractual due PO lines complete by latest confirmed date + grace days.',
    purchase_order_lines.contractual_due_po_lines
      USING (po_line_to_latest_confirmed_date)
      AS COUNT_IF(purchase_order_lines.is_contractual_due_po_line)
      COMMENT = 'Supplier Contractual OTD % denominator: contracted-supplier PO lines in population with latest confirmed date in the period and <= as-of date, including open lines.',
    purchase_order_lines.contracted_delivery_target
      USING (po_line_to_latest_confirmed_date)
      AS IFF(COUNT(DISTINCT IFF(purchase_order_lines.is_contractual_due_po_line, purchase_order_lines.CONTRACT_NO, NULL)) = 1,
             MAX(IFF(purchase_order_lines.is_contractual_due_po_line, purchase_order_lines.CONTRACT_DELIVERY_TARGET_FRACTION, NULL)), NULL)::NUMBER(9,6)
      WITH SYNONYMS ('contracted delivery target', 'contracted OTD target')
      COMMENT = 'Contracted delivery target (0-1 fraction) of the one contract in scope; NULL when the scope spans several contracts (group by supplier or contract).',
    purchase_order_lines.supplier_contractual_otd_gap
      USING (po_line_to_latest_confirmed_date)
      AS IFF(COUNT(DISTINCT IFF(purchase_order_lines.is_contractual_due_po_line, purchase_order_lines.CONTRACT_NO, NULL)) = 1,
             COUNT_IF(purchase_order_lines.is_contractual_on_time_po_line) / NULLIF(COUNT_IF(purchase_order_lines.is_contractual_due_po_line), 0)
             - MAX(IFF(purchase_order_lines.is_contractual_due_po_line, purchase_order_lines.CONTRACT_DELIVERY_TARGET_FRACTION, NULL)), NULL)::NUMBER(9,6)
      WITH SYNONYMS ('below contracted target', 'gap to contracted target', 'contractual OTD gap', 'OTD gap vs contract target')
      COMMENT = 'Supplier Contractual OTD Gap (contract v1.4 §3.1) = SUPPLIER_CONTRACTUAL_OTD_PCT - CONTRACTED_DELIVERY_TARGET, as a 0-1 fraction (x 100 = percentage points). Negative = below the contracted target. Defined within one contract: NULL when the scope spans several contracts, so group by supplier or contract.',
    purchase_order_lines.contractual_pro_forma_po_lines
      USING (po_line_to_latest_confirmed_date)
      AS COUNT_IF(purchase_order_lines.is_contractual_due_po_line AND NOT purchase_order_lines.is_in_contract_validity)
      COMMENT = 'Contractual due PO lines ordered before the contract became valid (pro-forma). When > 0 the answer must say: "pro-forma: contract terms (effective <CONTRACT_EFFECTIVE_DATE>) applied to earlier PO lines".',
    purchase_order_lines.contract_effective_date
      USING (po_line_to_latest_confirmed_date)
      AS MIN(IFF(purchase_order_lines.is_contractual_due_po_line, purchase_order_lines.CONTRACT_VALID_FROM, NULL))
      COMMENT = 'Earliest contract valid-from date among the contractual due PO lines in scope; quote it in the pro-forma label.',
    purchase_order_lines.contractual_otd_evidence_coverage_pct
      USING (po_line_to_latest_confirmed_date)
      AS (COUNT_IF(purchase_order_lines.is_contractual_due_po_line AND NOT purchase_order_lines.has_no_arrival_evidence)
          / NULLIF(COUNT_IF(purchase_order_lines.is_contractual_due_po_line), 0))::NUMBER(9,6)
      COMMENT = 'Evidence coverage of Supplier Contractual OTD % (§1.3): share of contractual due PO lines not flagged NO_ARRIVAL_EVIDENCE (GR fallback counts as evidence). 0-1 fraction.',
    purchase_order_lines.contractual_due_po_lines_first_date
      USING (po_line_to_latest_confirmed_date)
      AS MIN(IFF(purchase_order_lines.is_contractual_due_po_line, purchase_order_lines.contract_due_date_key, NULL))
      COMMENT = 'Data range start of Supplier Contractual OTD %: earliest latest-confirmed date among the contractual due PO lines in scope.',
    purchase_order_lines.contractual_due_po_lines_last_date
      USING (po_line_to_latest_confirmed_date)
      AS MAX(IFF(purchase_order_lines.is_contractual_due_po_line, purchase_order_lines.contract_due_date_key, NULL))
      COMMENT = 'Data range end of Supplier Contractual OTD %: latest latest-confirmed date among the contractual due PO lines in scope.',

    -- ---------------- Days of Inventory (contract §5) ----------------
    inventory.days_of_inventory
      NON ADDITIVE BY (inventory.inventory_snapshot_date)
      AS (SUM(IFF(inventory.is_doi_population, inventory.usable_qty * parts.standard_cost_amt, NULL))
          / NULLIF(SUM(IFF(inventory.is_doi_population, inventory.daily_demand_qty * parts.standard_cost_amt, NULL)), 0))::NUMBER(18,6)
      WITH SYNONYMS ('days of inventory', 'DOI', 'days of supply', 'DOS', 'days of cover', 'days of coverage',
                     'inventory coverage', 'days on hand')
      COMMENT = 'Days of Inventory (contract v1.2 §5) = usable inventory / average daily demand, at the LAST snapshot date of the period (never averaged or summed over dates). Weighted by standard cost: SUM(usable x std cost) / SUM(daily demand x std cost); within one Part the cost cancels, so this equals SUM(usable) / SUM(daily demand). Daily demand = forecast / days covered, or trailing 28-day shipments / 28 when the forecast covers < 14 days. NULL when demand is 0 (no demand).',
    inventory.weeks_of_supply
      NON ADDITIVE BY (inventory.inventory_snapshot_date)
      AS (SUM(IFF(inventory.is_doi_population, inventory.usable_qty * parts.standard_cost_amt, NULL))
          / NULLIF(SUM(IFF(inventory.is_doi_population, inventory.daily_demand_qty * parts.standard_cost_amt, NULL)), 0) / 7)::NUMBER(18,6)
      WITH SYNONYMS ('weeks of supply', 'weeks of cover')
      COMMENT = 'Weeks of supply = Days of Inventory / 7 (contract §5).',
    inventory.usable_inventory_qty
      NON ADDITIVE BY (inventory.inventory_snapshot_date)
      AS IFF(COUNT(DISTINCT IFF(inventory.is_doi_population, inventory.BASE_UOM, NULL)) > 1, NULL,
             SUM(IFF(inventory.is_doi_population, inventory.usable_qty, NULL)))
      COMMENT = 'DOI numerator within one Part: unrestricted + owned in-transit qty at the last snapshot of the period, base UoM. NULL when the group mixes units of measure.',
    inventory.avg_daily_demand_qty
      NON ADDITIVE BY (inventory.inventory_snapshot_date)
      AS IFF(COUNT(DISTINCT IFF(inventory.is_doi_population, inventory.BASE_UOM, NULL)) > 1, NULL,
             SUM(IFF(inventory.is_doi_population, inventory.daily_demand_qty, NULL)))
      COMMENT = 'DOI denominator within one Part: forecast qty / days covered (fallback trailing 28-day shipments / 28 when coverage < 14 days) at the last snapshot of the period, base UoM. NULL when the group mixes units of measure.',
    inventory.usable_inventory_value_amt
      NON ADDITIVE BY (inventory.inventory_snapshot_date)
      AS SUM(IFF(inventory.is_doi_population, inventory.usable_qty * parts.standard_cost_amt, NULL))
      COMMENT = 'DOI numerator above Part level: usable qty x standard cost, USD, at the last snapshot of the period.',
    inventory.daily_demand_value_amt
      NON ADDITIVE BY (inventory.inventory_snapshot_date)
      AS SUM(IFF(inventory.is_doi_population, inventory.daily_demand_qty * parts.standard_cost_amt, NULL))
      COMMENT = 'DOI denominator above Part level: average daily demand x standard cost, USD, at the last snapshot of the period.',
    inventory.doi_evidence_coverage_pct
      NON ADDITIVE BY (inventory.inventory_snapshot_date)
      AS (COUNT_IF(inventory.is_doi_population AND NOT inventory.has_doi_evidence_gap)
          / NULLIF(COUNT_IF(inventory.is_doi_population), 0))::NUMBER(9,6)
      COMMENT = 'Evidence coverage of Days of Inventory: share of part x plant snapshots (last snapshot of the period) without DEMAND_FALLBACK, NO_DEMAND or NEGATIVE_STOCK.',
    inventory.doi_snapshot_date
      NON ADDITIVE BY (inventory.inventory_snapshot_date)
      AS MAX(IFF(inventory.is_doi_population, inventory.SNAPSHOT_DATE, NULL))
      WITH SYNONYMS ('as-of date', 'snapshot date of DOI', 'stock as of')
      COMMENT = 'As-of snapshot date of DAYS_OF_INVENTORY: the plant-local snapshot date the value is taken from (the last snapshot of the period; with no date filter, the latest snapshot). This is a METRIC: put it under METRICS, never DIMENSIONS (the dimension is inventory.snapshot_date). Select it with every DOI answer and state it (contract v1.3 section 7.1).',
    inventory.inventory_first_snapshot_date
      AS MIN(IFF(inventory.is_doi_population, inventory.SNAPSHOT_DATE, NULL))
      COMMENT = 'Data range start (contract v1.3.1 section 7.1) of the inventory history in the query scope: earliest snapshot date. DOI itself is always the last snapshot (DOI_SNAPSHOT_DATE).',
    inventory.inventory_last_snapshot_date
      AS MAX(IFF(inventory.is_doi_population, inventory.SNAPSHOT_DATE, NULL))
      COMMENT = 'Data range end of the inventory history in the query scope: latest snapshot date.',

    -- ---------------- Landed Cost per Unit (contract §6) ----------------
    goods_receipts.landed_cost_per_unit
      USING (goods_receipt_to_posting_date)
      AS IFF(COUNT(DISTINCT IFF(goods_receipts.is_landed_cost_population, goods_receipts.PART_NO, NULL)) = 1,
             SUM(IFF(goods_receipts.is_landed_cost_population, goods_receipts.receipt_landed_cost_amt, NULL))
             / NULLIF(SUM(IFF(goods_receipts.is_landed_cost_population, goods_receipts.receipt_qty, NULL)), 0),
             NULL)::NUMBER(18,4)
      WITH SYNONYMS ('landed cost', 'landed cost per unit', 'actual landed cost', 'unit landed cost',
                     'total landed cost per unit', 'LCU', 'delivered cost per unit')
      COMMENT = 'Landed Cost per Unit (contract v1.2 §6) = TOTAL_LANDED_COST_AMT / LANDED_COST_RECEIVED_QTY, USD per base UoM, quantity-weighted, by GR posting date. Only defined within ONE Part: returns NULL when the group spans more than one part, so always group by part_no. Above Part level use TOTAL_LANDED_COST_AMT or LANDED_COST_UPLIFT_PCT.',
    goods_receipts.total_landed_cost_amt
      USING (goods_receipt_to_posting_date)
      AS SUM(IFF(goods_receipts.is_landed_cost_population, goods_receipts.receipt_landed_cost_amt, NULL))
      COMMENT = 'Landed Cost per Unit numerator: invoiced price x received qty + allocated freight + accessorials + non-recoverable duties + insurance, USD. Valid at any level.',
    goods_receipts.landed_cost_received_qty
      USING (goods_receipt_to_posting_date)
      AS SUM(IFF(goods_receipts.is_landed_cost_population, goods_receipts.receipt_qty, NULL))
      COMMENT = 'Landed Cost per Unit denominator: received qty in base UoM (meaningful within one Part).',
    goods_receipts.invoiced_product_cost_amt
      USING (goods_receipt_to_posting_date)
      AS SUM(IFF(goods_receipts.is_landed_cost_population, goods_receipts.receipt_product_cost_amt, NULL))
      COMMENT = 'Invoiced price x received qty, USD (base of the landed-cost uplift).',
    goods_receipts.landed_cost_freight_amt
      USING (goods_receipt_to_posting_date)
      AS SUM(IFF(goods_receipts.is_landed_cost_population, COALESCE(goods_receipts.FREIGHT_AMT, 0), NULL))
      COMMENT = 'Component of TOTAL_LANDED_COST_AMT: allocated freight (supplier-invoiced or carrier freight allocated by chargeable weight), USD. Missing freight counts as 0 (PROVISIONAL). Use to explain an uplift; not a per-unit metric.',
    goods_receipts.landed_cost_accessorial_amt
      USING (goods_receipt_to_posting_date)
      AS SUM(IFF(goods_receipts.is_landed_cost_population, COALESCE(goods_receipts.ACCESSORIAL_AMT, 0), NULL))
      COMMENT = 'Component of TOTAL_LANDED_COST_AMT: accessorials (expedite, handling, packaging, demurrage, detention, liftgate), USD.',
    goods_receipts.landed_cost_duty_amt
      USING (goods_receipt_to_posting_date)
      AS SUM(IFF(goods_receipts.is_landed_cost_population, COALESCE(goods_receipts.DUTY_AMT, 0), NULL))
      COMMENT = 'Component of TOTAL_LANDED_COST_AMT: non-recoverable duties, USD. Missing duty counts as 0 (PROVISIONAL).',
    goods_receipts.landed_cost_insurance_amt
      USING (goods_receipt_to_posting_date)
      AS SUM(IFF(goods_receipts.is_landed_cost_population, COALESCE(goods_receipts.INSURANCE_AMT, 0), NULL))
      COMMENT = 'Component of TOTAL_LANDED_COST_AMT: insurance, USD (no source system yet, so 0; contract §6 known limitation 4).',
    goods_receipts.landed_cost_uplift_pct
      USING (goods_receipt_to_posting_date)
      AS (SUM(IFF(goods_receipts.is_landed_cost_population, goods_receipts.receipt_landed_cost_amt, NULL))
          / NULLIF(SUM(IFF(goods_receipts.is_landed_cost_population, goods_receipts.receipt_product_cost_amt, NULL)), 0) - 1)::NUMBER(9,6)
      WITH SYNONYMS ('landed cost uplift', 'landed-cost uplift %', 'landed cost uplift percent', 'uplift over invoiced price',
                     'landed cost markup')
      COMMENT = 'Landed Cost Uplift % (contract v1.2 §6.1) = TOTAL_LANDED_COST_AMT / INVOICED_PRODUCT_COST_AMT - 1: how much freight, accessorials, duties and insurance add on top of the invoiced price. 0-1 fraction, ratio of sums, valid at any level incl. across parts; same population as Landed Cost per Unit. NULL when invoiced cost is 0. PROVISIONAL receipts understate it (missing freight / duty count as 0).',
    goods_receipts.landed_cost_evidence_coverage_pct
      USING (goods_receipt_to_posting_date)
      AS (COUNT_IF(goods_receipts.is_landed_cost_population AND NOT goods_receipts.has_landed_cost_evidence_gap)
          / NULLIF(COUNT_IF(goods_receipts.is_landed_cost_population OR goods_receipts.is_unmapped_stock_receipt), 0))::NUMBER(9,6)
      COMMENT = 'Evidence coverage of Landed Cost per Unit and Uplift % (contract v1.2 §6): receipts in the population neither PROVISIONAL nor ALLOC_BY_VALUE / (population receipts + UNMAPPED_PART stock receipts). 0-1 fraction.',
    goods_receipts.landed_cost_unmapped_part_receipts
      USING (goods_receipt_to_posting_date)
      AS COUNT_IF(goods_receipts.is_unmapped_stock_receipt)
      COMMENT = 'Priced stock receipts whose supplier part number maps to no ERP part (UNMAPPED_PART): not in Landed Cost per Unit / Uplift %, counted as not covered in LANDED_COST_EVIDENCE_COVERAGE_PCT.',
    goods_receipts.receipts_first_posting_date
      USING (goods_receipt_to_posting_date)
      AS MIN(IFF(goods_receipts.is_landed_cost_population OR goods_receipts.is_unmapped_stock_receipt, goods_receipts.POSTING_DATE, NULL))
      COMMENT = 'Data range start (contract v1.3.1 section 7.1) of Landed Cost per Unit / Uplift %: earliest GR posting date among the receipts in scope (population + UNMAPPED_PART receipts). Return it with every no-period answer.',
    goods_receipts.receipts_last_posting_date
      USING (goods_receipt_to_posting_date)
      AS MAX(IFF(goods_receipts.is_landed_cost_population OR goods_receipts.is_unmapped_stock_receipt, goods_receipts.POSTING_DATE, NULL))
      COMMENT = 'Data range end of Landed Cost per Unit / Uplift %: latest GR posting date among the receipts in scope.',

    -- ---------------- shipment volumes (not canonical KPIs) ----------------
    shipments.shipment_count
      AS COUNT(shipments.SHIPMENT_NO)
      COMMENT = 'Number of outbound shipment rows (shipment x order line). Volume only; carrier on-time is not a canonical metric.',
    shipments.total_shipped_qty
      AS SUM(shipments.SHIPPED_QTY)
      COMMENT = 'Shipped qty, base UoM (meaningful within one Part).',
    shipments.shipments_first_goods_issue_date
      AS MIN(shipments.GOODS_ISSUE_DATE)
      COMMENT = 'Data range start (contract v1.3.1 section 7.1) of the shipment volumes: earliest goods-issue date in scope.',
    shipments.shipments_last_goods_issue_date
      AS MAX(shipments.GOODS_ISSUE_DATE)
      COMMENT = 'Data range end of the shipment volumes: latest goods-issue date in scope.'
  )

  COMMENT = 'Supply chain canonical metrics (docs/metric_contracts.md v1.4): Customer OTD %, Supplier OTD %, Fill Rate %, Days of Inventory, Landed Cost per Unit, Landed Cost Uplift %. The only place metric logic lives.'

  AI_SQL_GENERATION $$Metric contract: docs/metric_contracts.md v1.4. Canonical metrics: CUSTOMER_OTD_PCT, SUPPLIER_OTD_PCT, FILL_RATE_PCT, DAYS_OF_INVENTORY, LANDED_COST_PER_UNIT, LANDED_COST_UPLIFT_PCT. Named variant (not canonical): SUPPLIER_CONTRACTUAL_OTD_PCT with SUPPLIER_CONTRACTUAL_OTD_GAP (rule 12).
1. Default rule: "on-time delivery", "OTD", "on-time", "on-time %" or "are we delivering on time?" with no qualifier ALWAYS means CUSTOMER_OTD_PCT. Use SUPPLIER_OTD_PCT only when the question says supplier, vendor or inbound.
2. Always select the named metric. Never compute a metric from facts or dimensions, never average percentages or unit costs across rows, never filter out rows that a metric already includes or excludes.
3. Percent metrics are 0-1 fractions: show them as % with one decimal (x 100). NULL means the population is empty: show n/a, never 0% or 100%. Days with one decimal, currency (USD) with two decimals.
4. Time anchors: Customer OTD %, Fill Rate % = order line commit date; Supplier OTD % = PO line supplier commit date; Landed Cost per Unit and Landed Cost Uplift % = GR posting date; Days of Inventory = snapshot date. Filter and group time through the dates table, which joins each metric on its own anchor.
5. Periods (contract v1.3 section 7.1). "week", "month", "quarter", "year" mean 4-4-5 fiscal periods from the dates table. Relative periods ALWAYS use the offset dimensions (0 = current, -1 = previous), never date arithmetic on CURRENT_DATE() and never YEAROFWEEKISO / MONTH of today: "last month" / "previous month" = dates.fiscal_month_offset = -1; "this month" / "month to date" / "MTD" = fiscal_month_offset = 0; "last N months" = fiscal_month_offset BETWEEN -N AND -1; "last quarter" = fiscal_quarter_offset = -1; "this quarter" / "QTD" = fiscal_quarter_offset = 0; "this year" / "YTD" = fiscal_year_offset = 0; "last year" = fiscal_year_offset = -1; "last week" = fiscal_week_offset = -1; "this week" / "WTD" = fiscal_week_offset = 0. Always return the period label and its first and last day as dimensions and state them in the answer: week = dates.fiscal_week_label, fiscal_week_start_date, fiscal_week_end_date; month = dates.fiscal_month_label, fiscal_month_start_date, fiscal_month_end_date; quarter = dates.fiscal_quarter_label, fiscal_quarter_start_date, fiscal_quarter_end_date; year = dates.fiscal_year_label, fiscal_year_start_date, fiscal_year_end_date. Example: "last month = fiscal FY2026-P09, 24 Aug - 27 Sep 2026"; for a current (partial) period add "through <today>". For trends group by the label. Exception: if the user names a calendar month or explicit dates ("September", "Sep 2026", "1-30 September"), filter dates.calendar_year + dates.calendar_month (or dates.calendar_date), return dates.calendar_month_label, calendar_month_start_date, calendar_month_end_date, and say in the answer that a calendar month, not a fiscal month, was used. A month name without a year means its most recent occurrence that has started on or before today.
6. DAYS_OF_INVENTORY (and WEEKS_OF_SUPPLY) is the value at the last snapshot date of each period; the metric does this itself. Do not sum or average it over dates. Every DOI answer states its as-of snapshot date: always also select inventory.doi_snapshot_date (a METRIC: list it under METRICS, never under DIMENSIONS; the snapshot-date dimension is inventory.snapshot_date, and if you group by it keep only the latest date unless a trend is asked) and say "as of <date> (latest snapshot)", or "as of <date> (last snapshot of <period label>)" when a period is asked. "Now", "current", "right now" or no period = the latest snapshot: add NO date filter. Return the components with it: USABLE_INVENTORY_VALUE_AMT (numerator), DAILY_DEMAND_VALUE_AMT (denominator) and DOI_EVIDENCE_COVERAGE_PCT; within one part also USABLE_INVENTORY_QTY and AVG_DAILY_DEMAND_QTY.
7. LANDED_COST_PER_UNIT is only defined within one Part: always group it by parts.part_no (optionally also supplier, plant or period). It returns NULL above Part level; for category, supplier, plant or period comparisons use LANDED_COST_UPLIFT_PCT (and TOTAL_LANDED_COST_AMT). "Landed cost by category / supplier / plant" = TOTAL_LANDED_COST_AMT, INVOICED_PRODUCT_COST_AMT, LANDED_COST_UPLIFT_PCT, LANDED_COST_EVIDENCE_COVERAGE_PCT and LANDED_COST_UNMAPPED_PART_RECEIPTS; to explain an uplift add the components LANDED_COST_FREIGHT_AMT, LANDED_COST_ACCESSORIAL_AMT, LANDED_COST_DUTY_AMT, LANDED_COST_INSURANCE_AMT (they sum with INVOICED_PRODUCT_COST_AMT to TOTAL_LANDED_COST_AMT). The part_category 'UNMAPPED PART' row holds receipts whose supplier part number maps to no ERP part: by contract they are excluded from landed cost (amounts NULL), so show the row as "UNMAPPED PART: <n> receipts excluded (no ERP part), amounts n/a", never as a blank category or as 0.
8. Return the matching evidence coverage metric with each canonical metric: OUTBOUND_ARRIVAL_EVIDENCE_COVERAGE_PCT (Customer OTD %, Fill Rate %), SUPPLIER_OTD_EVIDENCE_COVERAGE_PCT plus SUPPLIER_OTD_GR_FALLBACK_PCT (Supplier OTD %), DOI_EVIDENCE_COVERAGE_PCT, LANDED_COST_EVIDENCE_COVERAGE_PCT (Landed Cost per Unit, Landed Cost Uplift %). Also return the numerator and denominator when breaking a ratio down.
9. "region" means plants.plant_region (NA = Americas) unless the user says supplier or customer region. "site", "location" mean plant.
10. Every filter, also on a dimension (e.g. plants.plant_code = 'DE01'), goes in the WHERE clause INSIDE SEMANTIC_VIEW(... DIMENSIONS ... METRICS ... WHERE ...). The outer SELECT only sees the returned columns by their bare names (plant_code, not plants.plant_code); never put a table-qualified filter outside SEMANTIC_VIEW(). Plant codes: IN01 Pune, CN01 Suzhou, SG01 Singapore, NL01 Rotterdam, DE01 Stuttgart, PL01 Wroclaw, US01 Memphis, MX01 Monterrey.
11. No period named (contract v1.3.1 section 7.1): add NO date filter, answer over all available history, and ALWAYS return and state the data range (first and last date covered) by adding the data-range METRICS of the metric's table to the same SEMANTIC_VIEW call: Customer OTD % / Fill Rate % -> order_lines.due_lines_first_commit_date, due_lines_last_commit_date (commit dates); Supplier OTD % -> purchase_order_lines.due_po_lines_first_commit_date, due_po_lines_last_commit_date (supplier commit dates); Landed Cost per Unit / Uplift % / total landed cost -> goods_receipts.receipts_first_posting_date, receipts_last_posting_date (GR posting dates); shipment volumes -> shipments.shipments_first_goods_issue_date, shipments_last_goods_issue_date. Say e.g. "all history, supplier commit dates <first> - <last>". Never compute MIN / MAX / COUNT of a dimension or date in the outer query: the outer SELECT only sees the columns SEMANTIC_VIEW returns, so MIN(gr_posting_date) outside it fails. Exception: Days of Inventory with no period = the latest snapshot (rule 6), stated with DOI_SNAPSHOT_DATE.
12. Supplier Contractual OTD (contract v1.4 section 3.1, a named variant, NOT canonical). Use SUPPLIER_CONTRACTUAL_OTD_PCT / SUPPLIER_CONTRACTUAL_OTD_GAP ONLY when the question says "contractual OTD", "OTD vs contract", "below (the) contracted target" or "gap to contracted target"; plain "OTD" stays CUSTOMER_OTD_PCT and "supplier OTD" / "vendor OTD" stays SUPPLIER_OTD_PCT. Group by suppliers.supplier_no and suppliers.supplier_name (the gap and CONTRACTED_DELIVERY_TARGET are NULL across several contracts) and return CONTRACTED_DELIVERY_TARGET, SUPPLIER_CONTRACTUAL_OTD_GAP, CONTRACTUAL_ON_TIME_PO_LINES, CONTRACTUAL_DUE_PO_LINES, CONTRACTUAL_OTD_EVIDENCE_COVERAGE_PCT, CONTRACTUAL_PRO_FORMA_PO_LINES and CONTRACT_EFFECTIVE_DATE. Periods are CALENDAR months on the latest confirmed date: filter dates.calendar_month_offset (-1 = last complete calendar month) or dates.calendar_year + dates.calendar_month, return dates.calendar_month_label, calendar_month_start_date, calendar_month_end_date, and say "calendar month". With no period named use dates.calendar_month_offset = -1 (NOT all history) and name the month. "Below target" = SUPPLIER_CONTRACTUAL_OTD_GAP < 0, filtered in the outer query on the returned column. When CONTRACTUAL_PRO_FORMA_PO_LINES > 0 say "pro-forma: contract terms (effective <CONTRACT_EFFECTIVE_DATE>) applied to earlier PO lines". Only for "strict" / "in validity" add WHERE purchase_order_lines.po_line_is_in_contract_validity = TRUE inside SEMANTIC_VIEW.$$

  AI_QUESTION_CATEGORIZATION $$Resolve the user's phrasing with this table (metric_contracts.md v1.3 section 7). Name the metric used in the answer.
- "on-time delivery", "OTD", "on-time %", "are we delivering on time?" -> Customer OTD % (the default; no qualifier needed).
- "supplier / vendor / inbound on-time", "supplier OTD" -> Supplier OTD %.
- "carrier on-time", "on-time pickup" -> Carrier On-Time Arrival. NOT a canonical metric and not in this semantic view: say so in the answer; offer Customer OTD % as the canonical delivery measure.
- "on-time to request", "met requested date" -> On-Time to Request. NOT a canonical metric: say so; do not compute it.
- "fill rate", "unit fill rate" -> Fill Rate %.
- "supplier fill rate" -> Supplier Fill Rate, an inbound variant that is not a canonical metric: say so; do not compute it.
- "trailer fill", "truck fill rate", "load utilization" -> Trailer Utilization. Not a fill rate and not canonical: say so; never answer with Fill Rate %.
- "days of inventory / supply / cover", "days on hand" -> Days of Inventory. Always state the as-of snapshot date (DOI_SNAPSHOT_DATE).
- "DIO", "days inventory outstanding" -> DIO, a financial, Finance-owned metric that is not canonical: say so; never answer with Days of Inventory.
- "landed cost", "cost per unit delivered" -> Landed Cost per Unit (per part).
- "landed cost uplift", "uplift over invoice", landed cost compared across categories, suppliers or plants -> Landed Cost Uplift %.
- "freight cost per unit" -> Freight Cost per Unit, one component only and not canonical: say so.
- contract terms ("contracted delivery target", lead time, Incoterm, payment terms, late-delivery penalty, validity) -> the contracts dimensions (terms from the signed PDF). The contracted delivery target is a contract term and NOT comparable with Supplier OTD % (different date basis and tolerance): never compare SUPPLIER_OTD_PCT with contracts.contract_delivery_target.
- "contractual OTD", "OTD vs contract", "supplier contractual OTD" -> Supplier Contractual OTD % (v1.4 section 3.1), a named variant that is not canonical: say so, state the calendar month and the pro-forma label (rule 12).
- "below contracted target", "gap to contracted target", "which suppliers are below their contracted OTD target" -> Supplier Contractual OTD Gap per supplier with Supplier Contractual OTD % and the contracted target (rule 12).
- plain "OTD" is never Supplier Contractual OTD; "supplier OTD" / "vendor OTD" is Supplier OTD %, never the contractual variant.
Other variants are also not canonical and must be named as such: Ship-On-Time, Supplier Contractual OTD, line fill rate, order fill rate, first-pass fill rate, customer OTIF scorecards, DC Days on Hand, inventory turns, Standard Landed Cost, Quoted Landed Cost, PPV, TCO.$$

  AI_VERIFIED_QUERIES (
    suppliers_below_contracted_target_last_month AS (
      QUESTION 'Which suppliers are below their contracted OTD target?'
      SQL 'SELECT * FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN DIMENSIONS suppliers.supplier_no, suppliers.supplier_name, dates.calendar_month_label, dates.calendar_month_start_date, dates.calendar_month_end_date METRICS purchase_order_lines.supplier_contractual_otd_pct, purchase_order_lines.contracted_delivery_target, purchase_order_lines.supplier_contractual_otd_gap, purchase_order_lines.contractual_on_time_po_lines, purchase_order_lines.contractual_due_po_lines, purchase_order_lines.contractual_otd_evidence_coverage_pct, purchase_order_lines.contractual_pro_forma_po_lines, purchase_order_lines.contract_effective_date WHERE dates.calendar_month_offset = -1) WHERE supplier_contractual_otd_gap < 0 ORDER BY supplier_contractual_otd_gap'
    ),
    contractual_otd_kronos_last_6_calendar_months AS (
      QUESTION 'Show contractual OTD vs contract for Kronos Castings over the last 6 complete calendar months'
      SQL 'SELECT * FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN DIMENSIONS suppliers.supplier_name, dates.calendar_month_label, dates.calendar_month_start_date, dates.calendar_month_end_date METRICS purchase_order_lines.supplier_contractual_otd_pct, purchase_order_lines.contracted_delivery_target, purchase_order_lines.supplier_contractual_otd_gap, purchase_order_lines.contractual_on_time_po_lines, purchase_order_lines.contractual_due_po_lines, purchase_order_lines.contractual_pro_forma_po_lines, purchase_order_lines.contract_effective_date WHERE suppliers.supplier_name = ''Kronos Castings'' AND dates.calendar_month_offset BETWEEN -6 AND -1) ORDER BY calendar_month_start_date'
    ),
    customer_otd_by_plant_fytd AS (
      QUESTION 'What is our on-time delivery by plant this fiscal year?'
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT * FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN DIMENSIONS plants.plant_code, plants.plant_name METRICS order_lines.customer_otd_pct, order_lines.on_time_lines, order_lines.due_lines, order_lines.outbound_arrival_evidence_coverage_pct WHERE dates.fiscal_year_offset = 0) ORDER BY customer_otd_pct'
    ),
    customer_otd_for_plant_last_month AS (
      QUESTION 'What was on-time delivery for Pune last month?'
      SQL 'SELECT * FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN DIMENSIONS plants.plant_code, plants.plant_name, dates.fiscal_month_label, dates.fiscal_month_start_date, dates.fiscal_month_end_date METRICS order_lines.customer_otd_pct, order_lines.on_time_lines, order_lines.due_lines, order_lines.outbound_arrival_evidence_coverage_pct WHERE plants.plant_code = ''IN01'' AND dates.fiscal_month_offset = -1)'
    ),
    customer_otd_for_plant_last_quarter AS (
      QUESTION 'What was on-time delivery for Pune last quarter?'
      SQL 'SELECT * FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN DIMENSIONS plants.plant_code, plants.plant_name, dates.fiscal_quarter_label, dates.fiscal_quarter_start_date, dates.fiscal_quarter_end_date METRICS order_lines.customer_otd_pct, order_lines.on_time_lines, order_lines.due_lines, order_lines.outbound_arrival_evidence_coverage_pct WHERE plants.plant_code = ''IN01'' AND dates.fiscal_quarter_offset = -1)'
    ),
    customer_otd_by_region_fytd AS (
      QUESTION 'What is Customer OTD % by region this fiscal year?'
      SQL 'SELECT * FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN DIMENSIONS plants.plant_region METRICS order_lines.customer_otd_pct, order_lines.on_time_lines, order_lines.due_lines, order_lines.outbound_arrival_evidence_coverage_pct WHERE dates.fiscal_year_offset = 0) ORDER BY plant_region'
    ),
    customer_otd_by_fiscal_month AS (
      QUESTION 'Show Customer OTD % by fiscal month for the last 12 completed fiscal months'
      SQL 'SELECT * FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN DIMENSIONS dates.fiscal_month_label, dates.fiscal_month_start_date, dates.fiscal_month_end_date METRICS order_lines.customer_otd_pct, order_lines.on_time_lines, order_lines.due_lines, order_lines.outbound_arrival_evidence_coverage_pct WHERE dates.fiscal_month_offset BETWEEN -12 AND -1) ORDER BY fiscal_month_label'
    ),
    customer_otd_by_part_category_fytd AS (
      QUESTION 'What is Customer OTD % by part category this fiscal year?'
      SQL 'SELECT * FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN DIMENSIONS parts.part_category METRICS order_lines.customer_otd_pct, order_lines.on_time_lines, order_lines.due_lines, order_lines.outbound_arrival_evidence_coverage_pct WHERE dates.fiscal_year_offset = 0) ORDER BY customer_otd_pct'
    ),
    fill_rate_by_plant_fytd AS (
      QUESTION 'What is the fill rate by plant this fiscal year?'
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT * FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN DIMENSIONS plants.plant_code, plants.plant_name METRICS order_lines.fill_rate_pct, order_lines.fill_rate_filled_qty, order_lines.fill_rate_required_qty, order_lines.outbound_arrival_evidence_coverage_pct WHERE dates.fiscal_year_offset = 0) ORDER BY fill_rate_pct'
    ),
    fill_rate_by_fiscal_month AS (
      QUESTION 'Show Fill Rate % by fiscal month for the last 12 completed fiscal months'
      SQL 'SELECT * FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN DIMENSIONS dates.fiscal_month_label, dates.fiscal_month_start_date, dates.fiscal_month_end_date METRICS order_lines.fill_rate_pct, order_lines.fill_rate_filled_qty, order_lines.fill_rate_required_qty, order_lines.outbound_arrival_evidence_coverage_pct WHERE dates.fiscal_month_offset BETWEEN -12 AND -1) ORDER BY fiscal_month_label'
    ),
    fill_rate_by_region_fytd AS (
      QUESTION 'What is Fill Rate % by region this fiscal year?'
      SQL 'SELECT * FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN DIMENSIONS plants.plant_region METRICS order_lines.fill_rate_pct, order_lines.fill_rate_filled_qty, order_lines.fill_rate_required_qty, order_lines.outbound_arrival_evidence_coverage_pct WHERE dates.fiscal_year_offset = 0) ORDER BY plant_region'
    ),
    supplier_otd_by_supplier_fytd AS (
      QUESTION 'Which suppliers have the lowest supplier OTD this fiscal year?'
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT * FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN DIMENSIONS suppliers.supplier_no, suppliers.supplier_name METRICS purchase_order_lines.supplier_otd_pct, purchase_order_lines.on_time_po_lines, purchase_order_lines.due_po_lines, purchase_order_lines.supplier_otd_evidence_coverage_pct, purchase_order_lines.supplier_otd_gr_fallback_pct, purchase_order_lines.due_po_lines_first_commit_date, purchase_order_lines.due_po_lines_last_commit_date WHERE dates.fiscal_year_offset = 0) ORDER BY supplier_otd_pct NULLS LAST'
    ),
    supplier_otd_by_supplier_all_history AS (
      QUESTION 'What is vendor OTD by supplier?'
      SQL 'SELECT * FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN DIMENSIONS suppliers.supplier_no, suppliers.supplier_name METRICS purchase_order_lines.supplier_otd_pct, purchase_order_lines.on_time_po_lines, purchase_order_lines.due_po_lines, purchase_order_lines.supplier_otd_evidence_coverage_pct, purchase_order_lines.supplier_otd_gr_fallback_pct, purchase_order_lines.due_po_lines_first_commit_date, purchase_order_lines.due_po_lines_last_commit_date) ORDER BY supplier_otd_pct NULLS LAST'
    ),
    supplier_otd_by_plant_fytd AS (
      QUESTION 'What is Supplier OTD % by receiving plant this fiscal year?'
      SQL 'SELECT * FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN DIMENSIONS plants.plant_code, plants.plant_name METRICS purchase_order_lines.supplier_otd_pct, purchase_order_lines.on_time_po_lines, purchase_order_lines.due_po_lines, purchase_order_lines.supplier_otd_evidence_coverage_pct, purchase_order_lines.supplier_otd_gr_fallback_pct WHERE dates.fiscal_year_offset = 0) ORDER BY supplier_otd_pct'
    ),
    supplier_otd_by_part_category_fytd AS (
      QUESTION 'What is Supplier OTD % by part category this fiscal year?'
      SQL 'SELECT * FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN DIMENSIONS parts.part_category METRICS purchase_order_lines.supplier_otd_pct, purchase_order_lines.on_time_po_lines, purchase_order_lines.due_po_lines, purchase_order_lines.supplier_otd_evidence_coverage_pct, purchase_order_lines.supplier_otd_gr_fallback_pct WHERE dates.fiscal_year_offset = 0) ORDER BY supplier_otd_pct'
    ),
    doi_by_plant_latest AS (
      QUESTION 'How many days of inventory does each plant have right now?'
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT * FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN DIMENSIONS plants.plant_code, plants.plant_name METRICS inventory.doi_snapshot_date, inventory.days_of_inventory, inventory.usable_inventory_value_amt, inventory.daily_demand_value_amt, inventory.doi_evidence_coverage_pct) ORDER BY days_of_inventory'
    ),
    doi_for_plant_latest AS (
      QUESTION 'Days of supply for plant DE01'
      SQL 'SELECT * FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN DIMENSIONS plants.plant_code, plants.plant_name METRICS inventory.doi_snapshot_date, inventory.days_of_inventory, inventory.weeks_of_supply, inventory.usable_inventory_value_amt, inventory.daily_demand_value_amt, inventory.doi_evidence_coverage_pct WHERE plants.plant_code = ''DE01'')'
    ),
    doi_by_part_category_latest AS (
      QUESTION 'What are days of inventory by part category at the latest snapshot?'
      SQL 'SELECT * FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN DIMENSIONS parts.part_category METRICS inventory.doi_snapshot_date, inventory.days_of_inventory, inventory.usable_inventory_value_amt, inventory.daily_demand_value_amt, inventory.doi_evidence_coverage_pct) ORDER BY days_of_inventory'
    ),
    doi_by_fiscal_month AS (
      QUESTION 'Show period-end days of inventory by fiscal month for the last 12 completed fiscal months'
      SQL 'SELECT * FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN DIMENSIONS dates.fiscal_month_label, dates.fiscal_month_start_date, dates.fiscal_month_end_date METRICS inventory.doi_snapshot_date, inventory.days_of_inventory, inventory.usable_inventory_value_amt, inventory.daily_demand_value_amt, inventory.doi_evidence_coverage_pct WHERE dates.fiscal_month_offset BETWEEN -12 AND -1) ORDER BY fiscal_month_label'
    ),
    landed_cost_per_unit_by_part_supplier_fytd AS (
      QUESTION 'What is the landed cost per unit by part and supplier this fiscal year?'
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT * FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN DIMENSIONS parts.part_no, parts.part_description, suppliers.supplier_name METRICS goods_receipts.landed_cost_per_unit, goods_receipts.total_landed_cost_amt, goods_receipts.landed_cost_received_qty, goods_receipts.landed_cost_evidence_coverage_pct WHERE dates.fiscal_year_offset = 0) ORDER BY part_no, landed_cost_per_unit'
    ),
    landed_cost_by_part_category_fytd AS (
      QUESTION 'Landed cost by category this fiscal year'
      SQL 'SELECT * FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN DIMENSIONS parts.part_category METRICS goods_receipts.total_landed_cost_amt, goods_receipts.invoiced_product_cost_amt, goods_receipts.landed_cost_freight_amt, goods_receipts.landed_cost_accessorial_amt, goods_receipts.landed_cost_duty_amt, goods_receipts.landed_cost_insurance_amt, goods_receipts.landed_cost_uplift_pct, goods_receipts.landed_cost_evidence_coverage_pct, goods_receipts.landed_cost_unmapped_part_receipts, goods_receipts.receipts_first_posting_date, goods_receipts.receipts_last_posting_date WHERE dates.fiscal_year_offset = 0) ORDER BY total_landed_cost_amt DESC NULLS LAST'
    ),
    landed_cost_by_part_category_all_history AS (
      QUESTION 'Landed cost by category'
      SQL 'SELECT * FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN DIMENSIONS parts.part_category METRICS goods_receipts.total_landed_cost_amt, goods_receipts.invoiced_product_cost_amt, goods_receipts.landed_cost_freight_amt, goods_receipts.landed_cost_accessorial_amt, goods_receipts.landed_cost_duty_amt, goods_receipts.landed_cost_insurance_amt, goods_receipts.landed_cost_uplift_pct, goods_receipts.landed_cost_evidence_coverage_pct, goods_receipts.landed_cost_unmapped_part_receipts, goods_receipts.receipts_first_posting_date, goods_receipts.receipts_last_posting_date) ORDER BY total_landed_cost_amt DESC NULLS LAST'
    )
  )

  COPY GRANTS;

DESCRIBE SEMANTIC VIEW SC.SEMANTIC.SV_SUPPLY_CHAIN;
