-- =============================================================================
-- 25_legacy_views.sql
-- SC.LEGACY: the deliberate "before" state for the demo. Each view reproduces one
-- team's CURRENT, mutually inconsistent OTD and Fill Rate logic from
-- docs/conflict_matrix.md §3, read straight from RAW the way each team does today.
--
-- APPROVED EXCEPTION to AGENTS.md hard rule 1 (metric logic only in the semantic
-- view): metric logic is allowed here, and only here, because these numbers are
-- meant to disagree. They are NOT canonical, never feed CONFORMED / SEMANTIC /
-- AGENTS / apps (hard rule 2), and persona roles get no grants on this schema.
--
-- Depends on: sql/01a..01e (RAW_*). Idempotent: CREATE OR REPLACE.
--
-- Views (one row per month x plant):
--   V_PLANNING_OTD_FILL      planning   OTD vs requested date on goods issue; first-delivery fill
--   V_PROCUREMENT_OTD_FILL   procurement OTD -3/+0 vs latest confirmation on GR; cumulative received/ordered
--   V_LOGISTICS_OTD_FILL     logistics  stop arrival vs appointment +30 min; trailer utilization as "fill rate"
--
-- Proxies (RAW has no APPOINTMENT, equipment or WMS tables):
--   * Appointment window end = 17:00 customer-local on the line's latest PROMISED_DATE
--     (logistics books against the latest promise; a rebook resets the target).
--   * Trailer capacity: FTL 20,000 kg, LTL 10,000 kg; a trailer = origin plant x
--     carrier x pickup UTC date; parcel excluded.
-- =============================================================================

USE ROLE SC_ADMIN;
USE WAREHOUSE SC_WH;
CREATE SCHEMA IF NOT EXISTS SC.LEGACY COMMENT = 'Legacy persona-variant metric views for the before/after demo. Demo only; never a source for agents or apps.';
USE SCHEMA SC.LEGACY;
ALTER SESSION SET TIMEZONE = 'UTC';

-- -----------------------------------------------------------------------------
-- Planning (SC_PLANNER today): ERP only
--   OTD  = SO lines fully shipped with last goods issue <= REQUESTED_DATE
--          / SO lines whose last goods issue falls in the month. Partial = late.
--   Fill = units on the FIRST delivery / units ordered (gross), lines first shipped in the month.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW SC.LEGACY.V_PLANNING_OTD_FILL (
  PERIOD_MONTH        COMMENT 'Calendar month (first day). OTD: month of the last goods issue; Fill: month of the first goods issue.',
  PLANT_CODE          COMMENT 'Fulfilling plant on the sales order line.',
  OTD_ON_TIME_LINES   COMMENT 'Lines fully shipped (shipped >= ordered - cancelled) with last goods issue on or before the customer requested date.',
  OTD_SHIPPED_LINES   COMMENT 'Lines with their last goods issue in the month (open late lines never appear).',
  OTD_PCT             COMMENT 'Planning OTD = on-time lines / shipped lines (0-1). NOT the canonical Customer OTD %.',
  FILL_FIRST_DELIVERY_QTY COMMENT 'Units shipped on delivery 1 of lines first shipped in the month.',
  FILL_ORDERED_QTY    COMMENT 'Gross units ordered on those lines (cancellations not removed).',
  FILL_RATE_PCT       COMMENT 'Planning first-pass fill rate = first-delivery units / ordered units (0-1). NOT the canonical Fill Rate %.'
)
COMMENT = 'LEGACY demo only. Planning definition of OTD and Fill Rate (conflict_matrix.md §3): ship date stands in for delivery, measured against requested date; fill counts the first delivery only.'
AS
WITH d AS (
  SELECT ORDER_LINE_ID, MIN(SHIP_DATE) AS FIRST_GI, MAX(SHIP_DATE) AS LAST_GI,
         SUM(QTY_SHIPPED) AS SHIPPED, SUM(IFF(DELIVERY_SEQ = 1, QTY_SHIPPED, 0)) AS FIRST_QTY
  FROM SC.RAW_ERP.ERP_SHIPMENTS GROUP BY ORDER_LINE_ID
),
l AS (
  SELECT ol.PLANT_ID, ol.REQUESTED_DATE, ol.QTY_ORDERED, ol.QTY_CANCELLED, d.*
  FROM SC.RAW_ERP.ORDER_LINES ol JOIN d ON d.ORDER_LINE_ID = ol.ORDER_LINE_ID
),
otd AS (
  SELECT DATE_TRUNC(month, LAST_GI) AS M, PLANT_ID,
         COUNT_IF(LAST_GI <= REQUESTED_DATE AND SHIPPED >= QTY_ORDERED - QTY_CANCELLED) AS NUM, COUNT(*) AS DEN
  FROM l GROUP BY 1, 2
),
fill AS (
  SELECT DATE_TRUNC(month, FIRST_GI) AS M, PLANT_ID, SUM(FIRST_QTY) AS NUM, SUM(QTY_ORDERED) AS DEN
  FROM l GROUP BY 1, 2
)
SELECT COALESCE(o.M, f.M), COALESCE(o.PLANT_ID, f.PLANT_ID),
       o.NUM, o.DEN, (o.NUM / NULLIF(o.DEN, 0))::NUMBER(9,6),
       f.NUM, f.DEN, (f.NUM / NULLIF(f.DEN, 0))::NUMBER(9,6)
FROM otd o FULL OUTER JOIN fill f ON f.M = o.M AND f.PLANT_ID = o.PLANT_ID;

-- -----------------------------------------------------------------------------
-- Procurement (SC_PROCUREMENT today): supplier portal + ERP goods receipts
--   OTD  = PO lines whose last GR posting is within [latest confirmed - 3, latest confirmed]
--          / PO lines received (last GR in the month). Open overdue lines drop out.
--   Fill = units received / units ordered, cumulative, uncapped (can exceed 100%).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW SC.LEGACY.V_PROCUREMENT_OTD_FILL (
  PERIOD_MONTH        COMMENT 'Calendar month (first day) of the last goods-receipt posting on the PO line.',
  PLANT_CODE          COMMENT 'Receiving (ship-to) plant of the PO line.',
  OTD_ON_TIME_LINES   COMMENT 'Received PO lines whose last GR posting date is 0-3 days before or on the LATEST supplier-confirmed date.',
  OTD_RECEIVED_LINES  COMMENT 'PO lines with at least one GR and their last GR in the month.',
  OTD_PCT             COMMENT 'Procurement OTD = on-time lines / received lines (0-1). NOT the canonical Supplier OTD %.',
  FILL_RECEIVED_QTY   COMMENT 'Units received to date on those lines.',
  FILL_ORDERED_QTY    COMMENT 'Gross units ordered on those lines.',
  FILL_RATE_PCT       COMMENT 'Procurement supplier fill rate = received / ordered, uncapped (0-1+). NOT a canonical metric.'
)
COMMENT = 'LEGACY demo only. Procurement definition of OTD and Fill Rate (conflict_matrix.md §3): GR posting vs latest confirmation with -3/+0 tolerance; any eventual receipt counts.'
AS
WITH g AS (
  SELECT PO_ID, PO_LINE_NO, MAX(POSTING_DATE) AS LAST_GR, SUM(QTY_RECEIVED) AS RECEIVED
  FROM SC.RAW_SUPPLIER.GOODS_RECEIPTS GROUP BY PO_ID, PO_LINE_NO
)
SELECT DATE_TRUNC(month, g.LAST_GR), po.SHIP_TO_PLANT_ID,
       COUNT_IF(g.LAST_GR BETWEEN DATEADD(day, -3, po.LATEST_CONFIRMED_DATE) AND po.LATEST_CONFIRMED_DATE),
       COUNT(*),
       (COUNT_IF(g.LAST_GR BETWEEN DATEADD(day, -3, po.LATEST_CONFIRMED_DATE) AND po.LATEST_CONFIRMED_DATE) / NULLIF(COUNT(*), 0))::NUMBER(9,6),
       SUM(g.RECEIVED), SUM(po.QTY_ORDERED),
       (SUM(g.RECEIVED) / NULLIF(SUM(po.QTY_ORDERED), 0))::NUMBER(9,6)
FROM g JOIN SC.RAW_SUPPLIER.PURCHASE_ORDERS po ON po.PO_ID = g.PO_ID AND po.PO_LINE_NO = g.PO_LINE_NO
GROUP BY 1, 2;

-- -----------------------------------------------------------------------------
-- Logistics (SC_LOGISTICS today): TMS / carrier / IoT
--   OTD  = stops arrived <= appointment window end + 30 min / stops delivered
--          (arrival = IoT gate arrival, else POD; month of arrival in UTC / carrier time)
--   Fill = loaded kg / trailer capacity kg (trailer utilization; same name, different concept)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW SC.LEGACY.V_LOGISTICS_OTD_FILL (
  PERIOD_MONTH        COMMENT 'Calendar month (first day). OTD: UTC month of arrival; Fill: UTC month of pickup.',
  PLANT_CODE          COMMENT 'Origin (shipping) plant of the shipment.',
  OTD_ON_TIME_STOPS   COMMENT 'Delivered stops that arrived no later than appointment window end + 30 minutes.',
  OTD_DELIVERED_STOPS COMMENT 'Stops (deduplicated shipments) with an arrival in the month.',
  OTD_PCT             COMMENT 'Logistics OTD = on-time stops / delivered stops (0-1). This is Carrier On-Time Arrival, NOT Customer OTD %.',
  FILL_LOADED_KG      COMMENT 'Gross kg loaded on FTL / LTL trailers picked up in the month.',
  FILL_CAPACITY_KG    COMMENT 'Trailer capacity kg of those trailers (FTL 20,000, LTL 10,000).',
  FILL_RATE_PCT       COMMENT 'Logistics "fill rate" = loaded kg / capacity kg (0-1). This is Trailer Utilization, NOT Fill Rate %.'
)
COMMENT = 'LEGACY demo only. Logistics definition of OTD and Fill Rate (conflict_matrix.md §3): carrier performance against the booked slot, and trailer utilization. Appointment proxy: 17:00 customer-local on the latest promised date.'
AS
WITH s AS (
  SELECT * FROM SC.RAW_LOGISTICS.SHIPMENTS
  QUALIFY ROW_NUMBER() OVER (PARTITION BY SHIPMENT_ID ORDER BY LOADED_TS) = 1
),
iot AS (
  SELECT SHIPMENT_ID, MIN(EVENT_TS_UTC) AS TS FROM SC.RAW_IOT.ARRIVAL_EVENTS GROUP BY SHIPMENT_ID
),
stops AS (
  SELECT s.ORIGIN_PLANT_ID, COALESCE(iot.TS, s.POD_TS_UTC) AS ARR_UTC,
         CONVERT_TIMEZONE(c.SHIP_TO_TIMEZONE, 'UTC', DATEADD(hour, 17, ol.PROMISED_DATE::TIMESTAMP_NTZ)) AS APPT_END_UTC
  FROM s
  JOIN SC.RAW_ERP.ORDER_LINES ol  ON ol.ORDER_LINE_ID = s.ORDER_LINE_ID
  JOIN SC.RAW_ERP.SALES_ORDERS so ON so.SO_ID = ol.SO_ID
  JOIN SC.RAW_ERP.CUSTOMERS c     ON c.CUSTOMER_ID = so.CUSTOMER_ID
  LEFT JOIN iot                   ON iot.SHIPMENT_ID = s.SHIPMENT_ID
),
otd AS (
  SELECT DATE_TRUNC(month, ARR_UTC)::DATE AS M, ORIGIN_PLANT_ID AS PLANT_ID,
         COUNT_IF(ARR_UTC <= DATEADD(minute, 30, APPT_END_UTC)) AS NUM, COUNT(*) AS DEN
  FROM stops WHERE ARR_UTC IS NOT NULL GROUP BY 1, 2
),
trailers AS (
  SELECT s.ORIGIN_PLANT_ID, s.CARRIER_ID, s.PICKUP_TS_UTC::DATE AS PICKUP_DATE, c.MODE, SUM(s.GROSS_WEIGHT_KG) AS KG
  FROM s JOIN SC.RAW_LOGISTICS.CARRIERS c ON c.CARRIER_ID = s.CARRIER_ID
  WHERE c.MODE IN ('FTL', 'LTL')
  GROUP BY 1, 2, 3, 4
),
fill AS (
  SELECT DATE_TRUNC(month, PICKUP_DATE) AS M, ORIGIN_PLANT_ID AS PLANT_ID,
         SUM(KG) AS NUM, SUM(IFF(MODE = 'FTL', 20000, 10000)) AS DEN
  FROM trailers GROUP BY 1, 2
)
SELECT COALESCE(o.M, f.M), COALESCE(o.PLANT_ID, f.PLANT_ID),
       o.NUM, o.DEN, (o.NUM / NULLIF(o.DEN, 0))::NUMBER(9,6),
       f.NUM, f.DEN, (f.NUM / NULLIF(f.DEN, 0))::NUMBER(9,6)
FROM otd o FULL OUTER JOIN fill f ON f.M = o.M AND f.PLANT_ID = o.PLANT_ID;

-- -----------------------------------------------------------------------------
-- Demo: Pune (IN01), last calendar month, the three legacy answers side by side
-- -----------------------------------------------------------------------------
SET DEMO_MONTH = DATE_TRUNC(month, DATEADD(month, -1, CURRENT_DATE()));

SELECT 'OTD' AS METRIC_NAME_USED,
       ROUND(100 * p.OTD_PCT, 1) AS PLANNING_PCT, ROUND(100 * r.OTD_PCT, 1) AS PROCUREMENT_PCT, ROUND(100 * l.OTD_PCT, 1) AS LOGISTICS_PCT,
       p.OTD_ON_TIME_LINES || ' / ' || p.OTD_SHIPPED_LINES || ' SO lines' AS PLANNING_BASIS,
       r.OTD_ON_TIME_LINES || ' / ' || r.OTD_RECEIVED_LINES || ' PO lines' AS PROCUREMENT_BASIS,
       l.OTD_ON_TIME_STOPS || ' / ' || l.OTD_DELIVERED_STOPS || ' stops' AS LOGISTICS_BASIS
FROM SC.LEGACY.V_PLANNING_OTD_FILL p
JOIN SC.LEGACY.V_PROCUREMENT_OTD_FILL r ON r.PERIOD_MONTH = p.PERIOD_MONTH AND r.PLANT_CODE = p.PLANT_CODE
JOIN SC.LEGACY.V_LOGISTICS_OTD_FILL l   ON l.PERIOD_MONTH = p.PERIOD_MONTH AND l.PLANT_CODE = p.PLANT_CODE
WHERE p.PLANT_CODE = 'IN01' AND p.PERIOD_MONTH = $DEMO_MONTH
UNION ALL
SELECT 'Fill Rate',
       ROUND(100 * p.FILL_RATE_PCT, 1), ROUND(100 * r.FILL_RATE_PCT, 1), ROUND(100 * l.FILL_RATE_PCT, 1),
       p.FILL_FIRST_DELIVERY_QTY || ' / ' || p.FILL_ORDERED_QTY || ' units',
       r.FILL_RECEIVED_QTY || ' / ' || r.FILL_ORDERED_QTY || ' units',
       ROUND(l.FILL_LOADED_KG) || ' / ' || l.FILL_CAPACITY_KG || ' kg'
FROM SC.LEGACY.V_PLANNING_OTD_FILL p
JOIN SC.LEGACY.V_PROCUREMENT_OTD_FILL r ON r.PERIOD_MONTH = p.PERIOD_MONTH AND r.PLANT_CODE = p.PLANT_CODE
JOIN SC.LEGACY.V_LOGISTICS_OTD_FILL l   ON l.PERIOD_MONTH = p.PERIOD_MONTH AND l.PLANT_CODE = p.PLANT_CODE
WHERE p.PLANT_CODE = 'IN01' AND p.PERIOD_MONTH = $DEMO_MONTH;
