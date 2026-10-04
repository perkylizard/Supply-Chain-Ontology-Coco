-- =============================================================================
-- 01f_raw_inbound_arrivals.sql
-- Synthetic inbound ARRIVAL EVIDENCE for Supplier OTD % (12 months ending today):
-- the physical arrival sources 1 and 2 of metric_contracts.md §1.1 for inbound
-- ASNs, so the GR posting date (source 4, GR_FALLBACK) is only the last resort.
-- Depends on: sql/01a_raw_erp.sql (PLANTS), sql/01b_raw_supplier.sql (ASNS,
--             GOODS_RECEIPTS, OPS.GEN_INBOUND_PLAN), sql/01c_raw_logistics.sql
--             (CARRIERS), sql/01e_raw_inbound_costs.sql (INBOUND_FREIGHT_INVOICES)
-- Creates ONLY the two tables below; existing RAW tables are read, never rewritten.
-- Built with UNIFORM / RANDOM. Re-runnable (CREATE OR REPLACE).
--
-- Tables:
--   RAW_IOT.INBOUND_GEOFENCE_EVENTS  pallet / trailer tracker entering the receiving
--                                    plant's yard geofence (source 1). ~55% of ASNs.
--   RAW_LOGISTICS.INBOUND_CARRIER_POD carrier proof of delivery signed at the plant
--                                    dock (source 2). ~67% of ASNs, drawn
--                                    independently, so ~85% of goods receipts have
--                                    at least one physical arrival source.
--
-- Physical arrival = the existing GR dock-arrival behaviour: the plant-local date is
-- GOODS_RECEIPTS.ARRIVAL_LOCAL_DATE (= the generator's true arrival in
-- OPS.GEN_INBOUND_PLAN, also used for ASNs that arrived but are not posted yet), so
-- KRON / VELA keep their planted late arrivals. Only the GR posting lag goes away.
--
-- Planted on purpose:
--   * Timestamps in UTC only; gate entry 06:00-18:00 plant-local, so APAC early
--     mornings and Americas evenings fall on another UTC date (CONFORMED must take
--     the plant-local date, contract §1.2)
--   * ~2% duplicate geofence events (tracker re-ping 2-20 min later; take the first)
--   * POD 15-120 min after gate entry, same plant-local day
--   * ~15% of receipts with neither source -> GR_FALLBACK stays visible
-- =============================================================================

USE ROLE SC_ADMIN;
USE WAREHOUSE SC_WH;
ALTER SESSION SET TIMEZONE = 'UTC';

SET AS_OF = CURRENT_DATE();

-- -----------------------------------------------------------------------------
-- Arrived ASNs (temp): plant-local arrival date + random draws
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE SC.RAW_SUPPLIER._INB_ARR AS
WITH a AS (
  SELECT a.ASN_ID, a.PO_ID, a.PO_LINE_NO, a.SUPPLIER_ID, a.SHIP_TO_PLANT_ID,
         COALESCE(g.ARRIVAL_LOCAL_DATE, IFF(a.ASN_SEQ = 1, p.ARRIVAL1_DATE, p.ARRIVAL2_DATE)) AS ARRIVAL_LOCAL_DATE,
         pl.TIMEZONE, pl.REGION AS PLANT_REGION
  FROM SC.RAW_SUPPLIER.ASNS a
  JOIN SC.OPS.GEN_INBOUND_PLAN p       ON p.PO_ID = a.PO_ID AND p.PO_LINE_NO = a.PO_LINE_NO
  JOIN SC.RAW_ERP.PLANTS pl            ON pl.PLANT_ID = a.SHIP_TO_PLANT_ID
  LEFT JOIN SC.RAW_SUPPLIER.GOODS_RECEIPTS g ON g.ASN_ID = a.ASN_ID
)
SELECT a.*,
       UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(1701)) AS R_GEO,
       UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(1702)) AS R_POD,
       UNIFORM(360, 1080, RANDOM(1703))          AS GATE_MIN,
       UNIFORM(15, 120, RANDOM(1704))            AS POD_GAP_MIN,
       UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(1705)) AS R_DUP,
       UNIFORM(2, 20, RANDOM(1706))              AS DUP_GAP_MIN,
       UNIFORM(10000, 99999, RANDOM(1707))       AS DEV_N,
       UNIFORM(1, 3, RANDOM(1708))               AS CARRIER_K
FROM a
WHERE a.ARRIVAL_LOCAL_DATE < $AS_OF;

-- -----------------------------------------------------------------------------
-- RAW_IOT.INBOUND_GEOFENCE_EVENTS
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE SC.RAW_IOT.INBOUND_GEOFENCE_EVENTS AS
WITH e AS (
  SELECT ASN_ID, PO_ID, PO_LINE_NO, SUPPLIER_ID, SHIP_TO_PLANT_ID, DEV_N, R_DUP, DUP_GAP_MIN,
         CONVERT_TIMEZONE(TIMEZONE, 'UTC', DATEADD(minute, GATE_MIN, ARRIVAL_LOCAL_DATE::TIMESTAMP_NTZ)) AS TS
  FROM SC.RAW_SUPPLIER._INB_ARR
  WHERE R_GEO < 0.55
),
x AS (
  SELECT ASN_ID, PO_ID, PO_LINE_NO, SUPPLIER_ID, SHIP_TO_PLANT_ID, DEV_N, TS FROM e
  UNION ALL
  -- tracker re-ping inside the geofence
  SELECT ASN_ID, PO_ID, PO_LINE_NO, SUPPLIER_ID, SHIP_TO_PLANT_ID, DEV_N, DATEADD(minute, DUP_GAP_MIN, TS) FROM e WHERE R_DUP < 0.02
)
SELECT
  'GF' || LPAD(ROW_NUMBER() OVER (ORDER BY ASN_ID, TS), 9, '0')  AS EVENT_ID,
  'TRK-' || DEV_N                                                AS DEVICE_ID,
  ASN_ID, PO_ID, PO_LINE_NO, SUPPLIER_ID,
  SHIP_TO_PLANT_ID                                               AS PLANT_ID,
  'GEO-' || SHIP_TO_PLANT_ID || '-YARD'                          AS GEOFENCE_ID,
  'GEOFENCE_ENTER'                                               AS EVENT_TYPE,
  'RECEIVING_PLANT'                                              AS LOCATION_TYPE,
  TS                                                             AS EVENT_TS_UTC
FROM x
ORDER BY EVENT_ID;

-- -----------------------------------------------------------------------------
-- RAW_LOGISTICS.INBOUND_CARRIER_POD (one signed POD per ASN)
--   Carrier: the one on the freight invoice for buyer-paid loads, else one of the
--   plant region's truck carriers (supplier-arranged freight).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE SC.RAW_LOGISTICS.INBOUND_CARRIER_POD AS
WITH cr AS (
  SELECT SCAC, REGION, ROW_NUMBER() OVER (PARTITION BY REGION ORDER BY CARRIER_ID) AS K
  FROM SC.RAW_LOGISTICS.CARRIERS WHERE MODE <> 'PARCEL'
),
fi AS (SELECT ASN_ID, ANY_VALUE(SCAC) AS SCAC FROM SC.RAW_SUPPLIER.INBOUND_FREIGHT_INVOICES GROUP BY ASN_ID)
SELECT
  'IPOD' || LPAD(ROW_NUMBER() OVER (ORDER BY a.ASN_ID), 8, '0')  AS POD_ID,
  a.ASN_ID, a.PO_ID, a.PO_LINE_NO, a.SUPPLIER_ID, a.SHIP_TO_PLANT_ID,
  COALESCE(fi.SCAC, cr.SCAC)                                     AS SCAC,
  CONVERT_TIMEZONE(a.TIMEZONE, 'UTC',
    DATEADD(minute, a.GATE_MIN + a.POD_GAP_MIN, a.ARRIVAL_LOCAL_DATE::TIMESTAMP_NTZ)) AS POD_TS_UTC,
  'DOCK-' || a.SHIP_TO_PLANT_ID                                  AS SIGNED_AT
FROM SC.RAW_SUPPLIER._INB_ARR a
JOIN cr ON cr.REGION = a.PLANT_REGION AND cr.K = a.CARRIER_K
LEFT JOIN fi ON fi.ASN_ID = a.ASN_ID
WHERE a.R_POD < 0.67
ORDER BY POD_ID;

-- -----------------------------------------------------------------------------
-- Row counts + coverage of goods receipts
-- -----------------------------------------------------------------------------
SELECT 'INBOUND_GEOFENCE_EVENTS' AS TABLE_NAME, COUNT(*) AS ROW_COUNT FROM SC.RAW_IOT.INBOUND_GEOFENCE_EVENTS
UNION ALL SELECT 'INBOUND_CARRIER_POD', COUNT(*) FROM SC.RAW_LOGISTICS.INBOUND_CARRIER_POD
UNION ALL
SELECT 'GOODS_RECEIPTS with geofence or POD (%)',
       ROUND(100 * COUNT_IF(ge.ASN_ID IS NOT NULL OR po.ASN_ID IS NOT NULL) / COUNT(*), 1)
FROM SC.RAW_SUPPLIER.GOODS_RECEIPTS g
LEFT JOIN (SELECT DISTINCT ASN_ID FROM SC.RAW_IOT.INBOUND_GEOFENCE_EVENTS) ge ON ge.ASN_ID = g.ASN_ID
LEFT JOIN SC.RAW_LOGISTICS.INBOUND_CARRIER_POD po ON po.ASN_ID = g.ASN_ID;
