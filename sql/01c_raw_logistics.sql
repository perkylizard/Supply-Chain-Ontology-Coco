-- =============================================================================
-- 01c_raw_logistics.sql
-- Synthetic logistics (TMS / carrier) data for SC.RAW_LOGISTICS.
-- Depends on: sql/01a_raw_erp.sql (ERP_SHIPMENTS, ORDER_LINES, SALES_ORDERS,
--             CUSTOMERS, PLANTS, PARTS)
-- Built with GENERATOR-free derivation + UNIFORM / RANDOM. Re-runnable.
--
-- Tables: CARRIERS(12) SHIPMENTS
--   One carrier shipment per ERP delivery; ~3.5% of single-delivery lines are
--   loaded onto two trucks, so ~15% of shipped lines have 2-3 shipments.
--
-- Planted on purpose:
--   * ~1% duplicate SHIPMENTS rows (same SHIPMENT_ID, EDI re-send, later LOADED_TS)
--   * ~8% of PODs at 23:00-01:00 UTC, chosen so DATE(POD_TS_UTC) differs from the
--     ship-to local date (and, same region, the plant-local date)
--   * POD local date is 1 day before ERP GOODS_RECEIPT_DATE on ~10% of shipments
--     (customer posts receipt the next day)
--   * NULL FREIGHT_COST: ~50% of shipments delivered in the last 14 days or still
--     in transit (invoice not yet received), ~4% of older ones
--   * POD_TS_UTC NULL while in transit
-- =============================================================================

USE ROLE SC_ADMIN;
USE WAREHOUSE SC_WH;
USE SCHEMA SC.RAW_LOGISTICS;
ALTER SESSION SET TIMEZONE = 'UTC';

SET AS_OF = CURRENT_DATE();

-- -----------------------------------------------------------------------------
-- CARRIERS (fictional; 4 per region: 3 truck + 1 parcel)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE CARRIERS AS
SELECT * FROM VALUES
  ('CR01', 'MNSL', 'Monsoon Logistics',   'FTL',    'APAC'),
  ('CR02', 'JADX', 'Jade Route Express',  'LTL',    'APAC'),
  ('CR03', 'TGRH', 'Tiger Line Haulage',  'FTL',    'APAC'),
  ('CR04', 'SKPX', 'Skyport Parcel',      'PARCEL', 'APAC'),
  ('CR05', 'NRDF', 'Nordic Freightways',  'FTL',    'EMEA'),
  ('CR06', 'RHNL', 'Rhine Logistics',     'LTL',    'EMEA'),
  ('CR07', 'ALPX', 'Alpine Express',      'PARCEL', 'EMEA'),
  ('CR08', 'BLTC', 'Baltic Carriers',     'FTL',    'EMEA'),
  ('CR09', 'SWFT', 'Swiftway Freight',    'FTL',    'NA'),
  ('CR10', 'MDLT', 'Midland LTL',         'LTL',    'NA'),
  ('CR11', 'PRXP', 'ParcelXpress',        'PARCEL', 'NA'),
  ('CR12', 'CNTH', 'Continental Haulers', 'FTL',    'NA')
AS t(CARRIER_ID, SCAC, CARRIER_NAME, MODE, REGION);

-- -----------------------------------------------------------------------------
-- Shipment plan (temp): ERP deliveries x truck pieces
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE _SHIP_PLAN AS
WITH d AS (
  SELECT e.DELIVERY_ID, e.ORDER_LINE_ID, e.DELIVERY_SEQ, e.PLANT_ID, e.QTY_SHIPPED,
         e.SHIP_DATE, e.GOODS_RECEIPT_DATE,
         p.REGION                        AS PLANT_REGION,
         p.TIMEZONE                      AS PLANT_TZ,
         c.SHIP_TO_TIMEZONE,
         pt.UNIT_WEIGHT_KG,
         COUNT(*) OVER (PARTITION BY e.ORDER_LINE_ID) AS N_DEL,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(1001))    AS R_SPLIT,
         UNIFORM(1, 4, RANDOM(1002))                  AS TRANSIT_DAYS
  FROM SC.RAW_ERP.ERP_SHIPMENTS e
  JOIN SC.RAW_ERP.SALES_ORDERS so ON so.SO_ID       = e.SO_ID
  JOIN SC.RAW_ERP.CUSTOMERS c     ON c.CUSTOMER_ID  = so.CUSTOMER_ID
  JOIN SC.RAW_ERP.PLANTS p        ON p.PLANT_ID     = e.PLANT_ID
  JOIN SC.RAW_ERP.PARTS pt        ON pt.PART_ID     = e.PART_ID_SHIPPED
),
pc AS (
  SELECT d.*, x.PIECE,
         (d.N_DEL = 1 AND d.QTY_SHIPPED >= 2 AND d.R_SPLIT < 0.035) AS IS_TRUCK_SPLIT
  FROM d
  JOIN (SELECT COLUMN1 AS PIECE FROM VALUES (1), (2)) x
    ON x.PIECE = 1 OR (d.N_DEL = 1 AND d.QTY_SHIPPED >= 2 AND d.R_SPLIT < 0.035)
),
r AS (
  SELECT pc.*,
         IFF(NOT IS_TRUCK_SPLIT, QTY_SHIPPED,
             IFF(PIECE = 1, GREATEST(1, FLOOR(QTY_SHIPPED * 0.5)), QTY_SHIPPED - GREATEST(1, FLOOR(QTY_SHIPPED * 0.5)))) AS PIECE_QTY,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(1011)) AS R_LAG,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(1012)) AS R_FLIP,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(1013)) AS R_MIN,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(1014)) AS R_PICK,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(1015)) AS R_CARRIER,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(1016)) AS R_RATE,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(1017)) AS R_NULL,
         UNIFORM(0, 1, RANDOM(1018))               AS PIECE_EXTRA_DAY
  FROM pc
),
a AS (
  SELECT r.*,
    -- true local arrival date: ERP receipt date (minus a 1-day posting lag on ~10%),
    -- or ship date + transit when the customer never confirmed receipt
    GREATEST(SHIP_DATE,
      DATEADD(day,
        IFF(PIECE = 2, PIECE_EXTRA_DAY, 0) - IFF(GOODS_RECEIPT_DATE IS NOT NULL AND R_LAG < 0.10, 1, 0),
        COALESCE(GOODS_RECEIPT_DATE, DATEADD(day, TRANSIT_DAYS, SHIP_DATE))))::DATE   AS POD_LOCAL_DATE,
    ROUND(PIECE_QTY * UNIT_WEIGHT_KG, 1)                                             AS GROSS_WEIGHT_KG
  FROM r
),
o AS (
  SELECT a.*,
    -- ship-to UTC offset (minutes) on that date: local noon minus its UTC equivalent
    DATEDIFF(minute,
             CONVERT_TIMEZONE(SHIP_TO_TIMEZONE, 'UTC', DATEADD(hour, 12, POD_LOCAL_DATE::TIMESTAMP_NTZ)),
             DATEADD(hour, 12, POD_LOCAL_DATE::TIMESTAMP_NTZ))                       AS OFFSET_MIN,
    POD_LOCAL_DATE < $AS_OF                                                          AS IS_DELIVERED
  FROM a
),
t AS (
  SELECT o.*,
    (R_FLIP < 0.08 AND OFFSET_MIN <> 0)                                              AS IS_MIDNIGHT_FLIP,
    CASE
      -- east of UTC: local early morning -> 23:00-23:55 UTC the previous day
      WHEN R_FLIP < 0.08 AND OFFSET_MIN > 0 THEN OFFSET_MIN - (5 + FLOOR(R_MIN * 55))
      -- west of UTC: local evening -> 00:05-01:00 UTC the next day
      WHEN R_FLIP < 0.08 AND OFFSET_MIN < 0 THEN 1440 + OFFSET_MIN + 5 + FLOOR(R_MIN * 55)
      -- normal business-hours delivery 08:00-18:00 local
      ELSE 480 + FLOOR(R_MIN * 600)
    END                                                                              AS POD_LOCAL_MINUTE
  FROM o
)
SELECT t.*,
  IFF(IS_DELIVERED,
      CONVERT_TIMEZONE(SHIP_TO_TIMEZONE, 'UTC', DATEADD(minute, POD_LOCAL_MINUTE, POD_LOCAL_DATE::TIMESTAMP_NTZ)),
      NULL)                                                                          AS POD_TS_UTC,
  -- pickup 14:00-20:00 plant-local on the ERP ship date
  CONVERT_TIMEZONE(PLANT_TZ, 'UTC', DATEADD(minute, 840 + FLOOR(R_PICK * 360), SHIP_DATE::TIMESTAMP_NTZ)) AS PICKUP_TS_UTC
FROM t;

-- -----------------------------------------------------------------------------
-- SHIPMENTS
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE SHIPMENTS AS
WITH cr AS (
  SELECT c.*, ROW_NUMBER() OVER (PARTITION BY REGION, MODE = 'PARCEL' ORDER BY CARRIER_ID) AS K
  FROM CARRIERS c
),
s AS (
  SELECT sp.*,
         c.CARRIER_ID, c.MODE,
         ROW_NUMBER() OVER (ORDER BY sp.ORDER_LINE_ID, sp.DELIVERY_SEQ, sp.PIECE)                 AS RN,
         ROW_NUMBER() OVER (PARTITION BY sp.ORDER_LINE_ID ORDER BY sp.DELIVERY_SEQ, sp.PIECE)     AS SHIPMENT_SEQ
  FROM _SHIP_PLAN sp
  -- parcel under 50 kg, otherwise one of the region's 3 truck carriers
  JOIN cr c ON c.REGION = sp.PLANT_REGION
           AND (c.MODE = 'PARCEL') = (sp.GROSS_WEIGHT_KG < 50)
           AND c.K = IFF(sp.GROSS_WEIGHT_KG < 50, 1, 1 + FLOOR(sp.R_CARRIER * 3))
),
f AS (
  SELECT s.*,
    ROUND(
      CASE MODE WHEN 'PARCEL' THEN 8   + GROSS_WEIGHT_KG * (0.90 + R_RATE * 0.40)
                WHEN 'LTL'    THEN 60  + GROSS_WEIGHT_KG * (0.25 + R_RATE * 0.10)
                ELSE               150 + GROSS_WEIGHT_KG * (0.10 + R_RATE * 0.05) END
      * IFF(PLANT_ID = 'IN01', 1.25, 1), 2)                                                      AS FREIGHT_RAW,
    IFF(NOT IS_DELIVERED OR POD_LOCAL_DATE >= DATEADD(day, -14, $AS_OF), R_NULL < 0.50, R_NULL < 0.04) AS FREIGHT_MISSING
  FROM s
),
base AS (
  SELECT
    'SHP' || LPAD(RN, 8, '0')                                  AS SHIPMENT_ID,
    ORDER_LINE_ID,
    DELIVERY_ID                                                AS ERP_DELIVERY_ID,
    SHIPMENT_SEQ,
    CARRIER_ID,
    PLANT_ID                                                   AS ORIGIN_PLANT_ID,
    PIECE_QTY                                                  AS QTY_SHIPPED,
    GROSS_WEIGHT_KG,
    PICKUP_TS_UTC,
    POD_TS_UTC,
    IFF(FREIGHT_MISSING, NULL, FREIGHT_RAW)::NUMBER(12,2)      AS FREIGHT_COST,
    'USD'                                                      AS FREIGHT_CURRENCY,
    DATEADD(minute, 60 + FLOOR(R_MIN * 300), COALESCE(POD_TS_UTC, PICKUP_TS_UTC)) AS LOADED_TS
  FROM f
),
dup AS (
  -- EDI re-send: identical business content, loaded again 1-48 hours later
  SELECT * REPLACE (DATEADD(hour, UNIFORM(1, 48, RANDOM(1021)), LOADED_TS) AS LOADED_TS)
  FROM base
  WHERE UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(1022)) < 0.01
)
SELECT * FROM base
UNION ALL
SELECT * FROM dup
ORDER BY SHIPMENT_ID, LOADED_TS;

-- -----------------------------------------------------------------------------
-- Row counts
-- -----------------------------------------------------------------------------
SELECT 'CARRIERS' AS TABLE_NAME, COUNT(*) AS ROW_COUNT FROM CARRIERS
UNION ALL SELECT 'SHIPMENTS',                    COUNT(*) FROM SHIPMENTS
UNION ALL SELECT 'SHIPMENTS (distinct ids)',     COUNT(DISTINCT SHIPMENT_ID) FROM SHIPMENTS;
