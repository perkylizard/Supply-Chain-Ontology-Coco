-- =============================================================================
-- 01d_raw_iot.sql
-- Synthetic IoT / planning-feed data for SC.RAW_IOT.
-- Depends on: sql/01a_raw_erp.sql (PARTS, PLANTS, ORDER_LINES, SALES_ORDERS, CUSTOMERS)
--             sql/01c_raw_logistics.sql (SHIPMENTS)
-- Built with GENERATOR / UNIFORM / RANDOM. Re-runnable (CREATE OR REPLACE).
--
-- Tables:
--   INVENTORY_SNAPSHOTS  RFID end-of-day stock, 300 sampled stocked parts x 8 plants x 365 days
--                        ON_HAND_QTY = all physical stock incl. BLOCKED_QTY (quality hold)
--   ARRIVAL_EVENTS       IoT gate arrival at the customer site for ~70% of delivered shipments
--   SENSOR_READINGS      hourly temperature per plant warehouse zone, last 30 days
--   DEMAND_FORECAST      weekly consensus forecast runs, 28 daily buckets each, same 300 parts
--
-- Planted on purpose:
--   * SNAPSHOT_TS_UTC only (no local date): end-of-day in NA plants lands on the next UTC day
--   * Pune (IN01): thin safety stock -> frequent zero on-hand; forecast biased ~15% low;
--     cold-room excursions above 8 C (3-day compressor fault + afternoon spikes)
--   * ~5% of plant/part pairs have no forecast (DOI must use the trailing-shipments fallback)
--   * BLOCKED_QTY on ~5% of snapshots (excluded from usable stock by the DOI contract)
-- =============================================================================

USE ROLE SC_ADMIN;
USE WAREHOUSE SC_WH;
USE SCHEMA SC.RAW_IOT;
ALTER SESSION SET TIMEZONE = 'UTC';

SET AS_OF = CURRENT_DATE();

-- -----------------------------------------------------------------------------
-- Plant / part pairs (temp): 300 sampled stocked parts x 8 plants, sized on ERP demand
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE _PAIRS AS
WITH sp AS (
  SELECT PART_ID, BASE_UOM
  FROM SC.RAW_ERP.PARTS
  WHERE IS_STOCKED
  QUALIFY ROW_NUMBER() OVER (ORDER BY RANDOM(1101)) <= 300
),
dm AS (
  SELECT so.PLANT_ID, ol.PART_ID, SUM(ol.QTY_ORDERED - ol.QTY_CANCELLED) / 365 AS ACTUAL_DAILY
  FROM SC.RAW_ERP.ORDER_LINES ol
  JOIN SC.RAW_ERP.SALES_ORDERS so ON so.SO_ID = ol.SO_ID
  WHERE ol.LINE_TYPE <> 'RETURN'
  GROUP BY 1, 2
)
SELECT
  p.PLANT_ID, p.TIMEZONE, sp.PART_ID, sp.BASE_UOM,
  p.PLANT_ID = 'IN01'                                          AS IS_PUNE,
  COALESCE(dm.ACTUAL_DAILY, 0)                                 AS ACTUAL_DAILY,
  GREATEST(COALESCE(dm.ACTUAL_DAILY, 0), 0.2)                  AS STOCKING_DAILY,
  UNIFORM(14, 35, RANDOM(1102))                                AS CYCLE_LEN,
  UNIFORM(0, 34, RANDOM(1103))                                 AS PHASE,
  IFF(p.PLANT_ID = 'IN01',
      UNIFORM(-6::FLOAT, 4::FLOAT, RANDOM(1104)),
      UNIFORM(5::FLOAT, 15::FLOAT, RANDOM(1105)))              AS SAFETY_DAYS,
  UNIFORM(3, 7, RANDOM(1106))                                  AS TRANSIT_LEAD,
  UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(1107))                    AS R_NOFC
FROM sp
CROSS JOIN SC.RAW_ERP.PLANTS p
LEFT JOIN dm ON dm.PLANT_ID = p.PLANT_ID AND dm.PART_ID = sp.PART_ID;

-- -----------------------------------------------------------------------------
-- INVENTORY_SNAPSHOTS (sawtooth: consume down, replenish every CYCLE_LEN days)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE INVENTORY_SNAPSHOTS AS
WITH days AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS DAY_IDX
  FROM TABLE(GENERATOR(ROWCOUNT => 365))
),
x AS (
  SELECT pr.*, d.DAY_IDX,
         DATEADD(day, d.DAY_IDX - 365, $AS_OF)::DATE          AS SNAP_LOCAL_DATE,
         MOD(d.DAY_IDX + pr.PHASE, pr.CYCLE_LEN)              AS POS,
         UNIFORM(-0.15::FLOAT, 0.15::FLOAT, RANDOM(1111))     AS NOISE,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(1112))            AS R_BLK,
         UNIFORM(0.02::FLOAT, 0.10::FLOAT, RANDOM(1113))      AS BLK_FRAC
  FROM _PAIRS pr CROSS JOIN days d
),
q AS (
  SELECT x.*,
         GREATEST(0, ROUND(STOCKING_DAILY * (SAFETY_DAYS + (CYCLE_LEN - POS)) * (1 + NOISE))) AS ON_HAND
  FROM x
)
SELECT
  'RFID-' || PLANT_ID || '-01'                                                         AS DEVICE_ID,
  PLANT_ID,
  PART_ID,
  -- end of the plant-local day, recorded in UTC
  CONVERT_TIMEZONE(TIMEZONE, 'UTC', DATEADD(minute, 1439, SNAP_LOCAL_DATE::TIMESTAMP_NTZ)) AS SNAPSHOT_TS_UTC,
  ON_HAND::NUMBER(12,0)                                                                AS ON_HAND_QTY,
  IFF(R_BLK < 0.05, ROUND(ON_HAND * BLK_FRAC), 0)::NUMBER(12,0)                        AS BLOCKED_QTY,
  IFF(POS >= CYCLE_LEN - TRANSIT_LEAD, ROUND(STOCKING_DAILY * CYCLE_LEN), 0)::NUMBER(12,0) AS IN_TRANSIT_QTY,
  BASE_UOM                                                                             AS UOM
FROM q
ORDER BY PLANT_ID, PART_ID, SNAPSHOT_TS_UTC;

-- -----------------------------------------------------------------------------
-- ARRIVAL_EVENTS (gate arrival 5-60 min before POD, never crossing local midnight)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE ARRIVAL_EVENTS AS
WITH s AS (
  SELECT * FROM SC.RAW_LOGISTICS.SHIPMENTS
  WHERE POD_TS_UTC IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY SHIPMENT_ID ORDER BY LOADED_TS) = 1
),
j AS (
  SELECT s.SHIPMENT_ID, s.POD_TS_UTC, c.SHIP_TO_TIMEZONE,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(1201))  AS R_COV,
         UNIFORM(5, 60, RANDOM(1202))               AS GAP_MIN,
         UNIFORM(10000, 99999, RANDOM(1203))        AS DEV_N
  FROM s
  JOIN SC.RAW_ERP.ORDER_LINES ol  ON ol.ORDER_LINE_ID = s.ORDER_LINE_ID
  JOIN SC.RAW_ERP.SALES_ORDERS so ON so.SO_ID         = ol.SO_ID
  JOIN SC.RAW_ERP.CUSTOMERS c     ON c.CUSTOMER_ID    = so.CUSTOMER_ID
),
k AS (
  SELECT j.*,
         CONVERT_TIMEZONE('UTC', SHIP_TO_TIMEZONE, POD_TS_UTC) AS POD_LOCAL_TS
  FROM j
  WHERE R_COV < 0.70
)
SELECT
  'EV' || LPAD(ROW_NUMBER() OVER (ORDER BY SHIPMENT_ID), 9, '0')                  AS EVENT_ID,
  'TRK-' || DEV_N                                                                 AS DEVICE_ID,
  SHIPMENT_ID,
  'GATE_ARRIVAL'                                                                  AS EVENT_TYPE,
  'CUSTOMER_SITE'                                                                 AS LOCATION_TYPE,
  DATEADD(minute,
          -LEAST(GAP_MIN, GREATEST(HOUR(POD_LOCAL_TS) * 60 + MINUTE(POD_LOCAL_TS) - 1, 0)),
          POD_TS_UTC)                                                             AS EVENT_TS_UTC
FROM k
ORDER BY EVENT_ID;

-- -----------------------------------------------------------------------------
-- SENSOR_READINGS (hourly, last 30 days, 3 zones per plant)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE SENSOR_READINGS AS
WITH h AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS H
  FROM TABLE(GENERATOR(ROWCOUNT => 720))
),
z AS (
  SELECT * FROM VALUES ('AMBIENT', 20.0, 3.0, 30.0), ('COLD', 4.0, 1.0, 8.0), ('FROZEN', -20.0, 1.5, -15.0)
  AS t(ZONE, SETPOINT, AMP, MAX_ALLOWED)
),
x AS (
  SELECT p.PLANT_ID, p.TIMEZONE, z.*, h.H,
         DATEADD(hour, h.H - 720, $AS_OF::TIMESTAMP_NTZ)                          AS TS_UTC,
         HOUR(CONVERT_TIMEZONE('UTC', p.TIMEZONE, DATEADD(hour, h.H - 720, $AS_OF::TIMESTAMP_NTZ))) AS LOCAL_HOUR,
         FLOOR(h.H / 24)                                                          AS DAY_N,
         UNIFORM(-0.5::FLOAT, 0.5::FLOAT, RANDOM(1301))                           AS NOISE
  FROM SC.RAW_ERP.PLANTS p CROSS JOIN z CROSS JOIN h
)
SELECT
  'TMP-' || PLANT_ID || '-' || ZONE                                               AS DEVICE_ID,
  PLANT_ID,
  PLANT_ID || '-' || ZONE                                                         AS WAREHOUSE_ZONE_ID,
  ZONE                                                                            AS WAREHOUSE_ZONE,
  TS_UTC                                                                          AS READING_TS_UTC,
  ROUND(SETPOINT
        + AMP * 0.3 * SIN(2 * PI() * (LOCAL_HOUR - 9) / 24)
        + NOISE
        + CASE
            -- Pune cold room: 3-day compressor fault
            WHEN PLANT_ID = 'IN01' AND ZONE = 'COLD' AND DAY_N BETWEEN 11 AND 13 THEN 5.5 + 1.5 * SIN(H)
            -- Pune cold room: afternoon spikes every 4th day
            WHEN PLANT_ID = 'IN01' AND ZONE = 'COLD' AND MOD(DAY_N, 4) = 0 AND LOCAL_HOUR BETWEEN 13 AND 16 THEN 4.5
            ELSE 0 END, 2)                                                        AS TEMPERATURE_C,
  SETPOINT                                                                        AS SETPOINT_C,
  MAX_ALLOWED                                                                     AS MAX_ALLOWED_C
FROM x
ORDER BY DEVICE_ID, READING_TS_UTC;

-- -----------------------------------------------------------------------------
-- DEMAND_FORECAST (weekly runs over the last year + current week, 28 daily buckets)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE DEMAND_FORECAST AS
WITH runs AS (
  SELECT DATEADD(week, -(ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1), DATE_TRUNC('week', $AS_OF))::DATE AS RUN_DATE
  FROM TABLE(GENERATOR(ROWCOUNT => 53))
),
hz AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS D
  FROM TABLE(GENERATOR(ROWCOUNT => 28))
),
x AS (
  SELECT pr.PLANT_ID, pr.PART_ID, pr.BASE_UOM, pr.ACTUAL_DAILY, pr.IS_PUNE, r.RUN_DATE,
         DATEADD(day, hz.D, r.RUN_DATE)::DATE                AS FORECAST_DATE,
         UNIFORM(0.75::FLOAT, 1.25::FLOAT, RANDOM(1401))     AS F
  FROM _PAIRS pr CROSS JOIN runs r CROSS JOIN hz
  WHERE pr.R_NOFC >= 0.05
)
SELECT
  RUN_DATE                                                      AS FORECAST_RUN_DATE,
  PLANT_ID,
  PART_ID,
  FORECAST_DATE,
  ROUND(ACTUAL_DAILY * F * IFF(IS_PUNE, 0.85, 1), 3)::NUMBER(12,3) AS FORECAST_QTY,
  BASE_UOM                                                      AS UOM,
  'CONSENSUS'                                                   AS FORECAST_TYPE
FROM x
ORDER BY FORECAST_RUN_DATE, PLANT_ID, PART_ID, FORECAST_DATE;

-- -----------------------------------------------------------------------------
-- Row counts
-- -----------------------------------------------------------------------------
SELECT 'INVENTORY_SNAPSHOTS' AS TABLE_NAME, COUNT(*) AS ROW_COUNT FROM INVENTORY_SNAPSHOTS
UNION ALL SELECT 'ARRIVAL_EVENTS',  COUNT(*) FROM ARRIVAL_EVENTS
UNION ALL SELECT 'SENSOR_READINGS', COUNT(*) FROM SENSOR_READINGS
UNION ALL SELECT 'DEMAND_FORECAST', COUNT(*) FROM DEMAND_FORECAST;
