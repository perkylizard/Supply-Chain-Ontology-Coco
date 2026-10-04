-- =============================================================================
-- 01a_raw_erp.sql
-- Synthetic ERP source data for SC.RAW_ERP (12 months ending today).
-- Built with GENERATOR / UNIFORM / RANDOM. Re-runnable (CREATE OR REPLACE).
--
-- Tables: PLANTS(8) CUSTOMERS(500) PARTS(2000) SALES_ORDERS(30k)
--         ORDER_LINES(100k) ERP_SHIPMENTS(one row per delivery)
--
-- Planted on purpose:
--   * ~30% of lines have REQUESTED_DATE < PROMISED_DATE (confirmation slip / reschedule)
--   * reschedules with reason codes (CUSTOMER_REQUEST resets commit; others don't)
--   * fully and partially cancelled lines, RETURN and FREE_OF_CHARGE lines
--   * intercompany customers (excluded by the OTD / Fill Rate contracts)
--   * ~15% of shippable lines split into 2-3 deliveries; some short-shipped lines
--   * ~0.5% part substitutions on deliveries; ~3% deliveries missing GOODS_RECEIPT_DATE
--   * Pune (IN01) underperforms: more confirmation slips, shortage reschedules,
--     late shipments, splits and short shipments
-- =============================================================================

USE ROLE SC_ADMIN;
USE WAREHOUSE SC_WH;
USE SCHEMA SC.RAW_ERP;
ALTER SESSION SET TIMEZONE = 'UTC';

SET AS_OF      = CURRENT_DATE();
SET START_DATE = DATEADD(day, -365, $AS_OF);

-- -----------------------------------------------------------------------------
-- PLANTS
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE PLANTS (
  PLANT_ID VARCHAR, PLANT_NAME VARCHAR, CITY VARCHAR, COUNTRY_CODE VARCHAR,
  REGION VARCHAR, TIMEZONE VARCHAR, PLANT_TYPE VARCHAR
) AS
SELECT * FROM VALUES
  ('IN01', 'Pune Assembly',          'Pune',      'IN', 'APAC', 'Asia/Kolkata',     'MANUFACTURING'),
  ('CN01', 'Suzhou Components',      'Suzhou',    'CN', 'APAC', 'Asia/Shanghai',    'MANUFACTURING'),
  ('SG01', 'Singapore Distribution', 'Singapore', 'SG', 'APAC', 'Asia/Singapore',   'DISTRIBUTION'),
  ('NL01', 'Rotterdam Distribution', 'Rotterdam', 'NL', 'EMEA', 'Europe/Amsterdam', 'DISTRIBUTION'),
  ('DE01', 'Stuttgart Precision',    'Stuttgart', 'DE', 'EMEA', 'Europe/Berlin',    'MANUFACTURING'),
  ('PL01', 'Wroclaw Assembly',       'Wroclaw',   'PL', 'EMEA', 'Europe/Warsaw',    'MANUFACTURING'),
  ('US01', 'Memphis Distribution',   'Memphis',   'US', 'NA',   'America/Chicago',  'DISTRIBUTION'),
  ('MX01', 'Monterrey Assembly',     'Monterrey', 'MX', 'NA',   'America/Monterrey','MANUFACTURING');

-- -----------------------------------------------------------------------------
-- CUSTOMERS (ship-to time zone drives the Customer OTD timezone rule)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE CUSTOMERS AS
WITH city AS (
  SELECT * FROM VALUES
    (0,'Mumbai','IN','APAC','Asia/Kolkata'),      (1,'Bengaluru','IN','APAC','Asia/Kolkata'),
    (2,'Shanghai','CN','APAC','Asia/Shanghai'),   (3,'Tokyo','JP','APAC','Asia/Tokyo'),
    (4,'Sydney','AU','APAC','Australia/Sydney'),  (5,'Singapore','SG','APAC','Asia/Singapore'),
    (6,'London','GB','EMEA','Europe/London'),     (7,'Paris','FR','EMEA','Europe/Paris'),
    (8,'Munich','DE','EMEA','Europe/Berlin'),     (9,'Milan','IT','EMEA','Europe/Rome'),
    (10,'Dubai','AE','EMEA','Asia/Dubai'),
    (11,'Chicago','US','NA','America/Chicago'),   (12,'Los Angeles','US','NA','America/Los_Angeles'),
    (13,'New York','US','NA','America/New_York'), (14,'Toronto','CA','NA','America/Toronto'),
    (15,'Mexico City','MX','NA','America/Mexico_City')
  AS t(CITY_IDX, CITY, COUNTRY_CODE, REGION, TZ)
),
g AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4())          AS N,
         UNIFORM(0, 15, RANDOM(101))                  AS CITY_IDX,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(102))     AS R_SEG,
         UNIFORM(0, 19, RANDOM(103))                  AS W1,
         UNIFORM(0, 14, RANDOM(104))                  AS W2,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(105))     AS R_IC
  FROM TABLE(GENERATOR(ROWCOUNT => 500))
)
SELECT
  'C' || LPAD(g.N, 5, '0')                                                      AS CUSTOMER_ID,
  IFF(g.R_IC < 0.03,
      'SC Intercompany ' || c.CITY,
      GET(ARRAY_CONSTRUCT('Apex','Blue Ridge','Cedar','Delta','Evergreen','Falcon','Granite','Harbor',
                          'Ironclad','Juniper','Keystone','Lakeside','Meridian','Northstar','Oakline',
                          'Pinnacle','Quantum','Redwood','Summit','Titan'), g.W1)::VARCHAR || ' ' ||
      GET(ARRAY_CONSTRUCT('Industries','Manufacturing','Retail','Systems','Foods','Automotive','Energy',
                          'Healthcare','Electronics','Logistics','Machinery','Building Supply',
                          'Appliances','Agritech','Aerospace'), g.W2)::VARCHAR)       AS CUSTOMER_NAME,
  CASE WHEN g.R_IC   < 0.03 THEN 'Intercompany'
       WHEN g.R_SEG  < 0.15 THEN 'Strategic'
       WHEN g.R_SEG  < 0.45 THEN 'Key Account'
       WHEN g.R_SEG  < 0.75 THEN 'Distributor'
       ELSE 'SMB' END                                                           AS SEGMENT,
  c.COUNTRY_CODE,
  c.REGION,
  c.CITY                                                                        AS SHIP_TO_CITY,
  c.TZ                                                                          AS SHIP_TO_TIMEZONE,
  g.R_IC < 0.03                                                                 AS IS_INTERCOMPANY
FROM g JOIN city c ON c.CITY_IDX = g.CITY_IDX;

-- -----------------------------------------------------------------------------
-- PARTS (Category > Family > SKU)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE PARTS AS
WITH fam AS (
  SELECT * FROM VALUES
    (0,'Electronics','Sensors'),   (1,'Electronics','Controllers'), (2,'Electronics','Connectors'),
    (3,'Mechanical','Bearings'),   (4,'Mechanical','Gears'),        (5,'Mechanical','Shafts'),
    (6,'Electrical','Motors'),     (7,'Electrical','Cables'),       (8,'Electrical','Switchgear'),
    (9,'Hydraulics','Pumps'),      (10,'Hydraulics','Valves'),      (11,'Hydraulics','Seals'),
    (12,'Packaging','Cartons'),    (13,'Packaging','Pallets'),      (14,'Packaging','Films'),
    (15,'Chemicals','Lubricants'), (16,'Chemicals','Adhesives'),    (17,'Chemicals','Coolants')
  AS t(FAM_IDX, CATEGORY, FAMILY)
),
g AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4())      AS N,
         UNIFORM(0, 17, RANDOM(301))              AS FAM_IDX,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(302)) AS R_COST,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(303)) AS R_WT,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(304)) AS R_STK
  FROM TABLE(GENERATOR(ROWCOUNT => 2000))
)
SELECT
  'P' || LPAD(g.N, 6, '0')                                              AS PART_ID,
  f.FAMILY || ' ' || CHR(65 + MOD(g.N, 26)) || '-' || LPAD(g.N, 4, '0') AS DESCRIPTION,
  f.CATEGORY,
  f.FAMILY,
  IFF(f.CATEGORY = 'Chemicals', 'L', 'EA')                              AS BASE_UOM,
  ROUND(CASE f.CATEGORY
          WHEN 'Electronics' THEN 5   + g.R_COST * 295
          WHEN 'Mechanical'  THEN 2   + g.R_COST * 150
          WHEN 'Electrical'  THEN 10  + g.R_COST * 490
          WHEN 'Hydraulics'  THEN 8   + g.R_COST * 400
          WHEN 'Packaging'   THEN 0.2 + g.R_COST * 15
          ELSE                    3   + g.R_COST * 60 END, 2)::NUMBER(12,2) AS STANDARD_COST,
  'USD'                                                                 AS COST_CURRENCY,
  ROUND(0.05 + g.R_WT * 25, 3)::NUMBER(10,3)                            AS UNIT_WEIGHT_KG,
  g.R_STK >= 0.05                                                       AS IS_STOCKED,
  f.CATEGORY = 'Chemicals'                                              AS IS_TEMP_CONTROLLED
FROM g JOIN fam f ON f.FAM_IDX = g.FAM_IDX;

-- -----------------------------------------------------------------------------
-- SALES_ORDERS (fulfilling plant chosen within the customer's region)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE SALES_ORDERS AS
WITH g AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4())      AS N,
         UNIFORM(1, 500, RANDOM(201))             AS CUST_N,
         UNIFORM(0, 364, RANDOM(202))             AS DAY_OFF,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(203)) AS R_PLANT,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(204)) AS R_TYPE
  FROM TABLE(GENERATOR(ROWCOUNT => 30000))
)
SELECT
  'SO' || LPAD(g.N, 7, '0')                                    AS SO_ID,
  c.CUSTOMER_ID,
  CASE c.REGION
    WHEN 'APAC' THEN CASE WHEN g.R_PLANT < 0.40 THEN 'IN01' WHEN g.R_PLANT < 0.75 THEN 'CN01' ELSE 'SG01' END
    WHEN 'EMEA' THEN CASE WHEN g.R_PLANT < 0.40 THEN 'NL01' WHEN g.R_PLANT < 0.75 THEN 'DE01' ELSE 'PL01' END
    ELSE             CASE WHEN g.R_PLANT < 0.60 THEN 'US01' ELSE 'MX01' END
  END                                                          AS PLANT_ID,
  DATEADD(day, g.DAY_OFF, $START_DATE)::DATE                   AS ORDER_DATE,
  IFF(g.R_TYPE < 0.08, 'RUSH', 'STANDARD')                     AS ORDER_TYPE,
  IFF(c.REGION = 'EMEA', 'EUR', 'USD')                         AS CURRENCY
FROM g JOIN CUSTOMERS c ON c.CUSTOMER_ID = 'C' || LPAD(g.CUST_N, 5, '0');

-- -----------------------------------------------------------------------------
-- Line plan (session-scoped): every ORDER_LINES / ERP_SHIPMENTS value derives
-- from this one materialized table so the two stay consistent.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE _LINE_PLAN AS
WITH g AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4())             AS N,
         UNIFORM(1, 30000, RANDOM(401))                  AS SO_RAND,
         UNIFORM(1, 2000,  RANDOM(402))                  AS PART_N,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(403))        AS R_QTY,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(404))        AS R_PRICE,
         UNIFORM(3, 21, RANDOM(405))                     AS REQ_LEAD,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(406))        AS R_CONF,
         UNIFORM(1, 10, RANDOM(407))                     AS CONF_SLIP,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(408))        AS R_RESCHED,
         UNIFORM(2, 12, RANDOM(409))                     AS RESCHED_DAYS,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(410))        AS R_REASON,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(411))        AS R_TYPE,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(412))        AS R_CANCEL,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(413))        AS R_DELAY,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(414))        AS R_DELAY_MAG,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(415))        AS R_SPLIT,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(416))        AS R_SHORT,
         UNIFORM(0.55::FLOAT, 0.95::FLOAT, RANDOM(417))  AS SHORT_FRAC,
         UNIFORM(1, 4, RANDOM(418))                      AS TRANSIT_DAYS,
         UNIFORM(2, 9, RANDOM(419))                      AS GAP2,
         UNIFORM(2, 9, RANDOM(420))                      AS GAP3
  FROM TABLE(GENERATOR(ROWCOUNT => 100000))
),
j AS (
  -- first 30k lines map 1:1 to orders so every order has at least one line
  SELECT g.*, so.SO_ID, so.ORDER_DATE, so.ORDER_TYPE, so.PLANT_ID, so.CURRENCY,
         pt.PART_ID, pt.STANDARD_COST, pt.BASE_UOM,
         so.PLANT_ID = 'IN01' AS IS_PUNE
  FROM g
  JOIN SALES_ORDERS so ON so.SO_ID   = 'SO' || LPAD(IFF(g.N <= 30000, g.N, g.SO_RAND), 7, '0')
  JOIN PARTS pt        ON pt.PART_ID = 'P'  || LPAD(g.PART_N, 6, '0')
),
d AS (
  SELECT j.*,
    CASE WHEN R_TYPE < 0.010 THEN 'FREE_OF_CHARGE' WHEN R_TYPE < 0.025 THEN 'RETURN' ELSE 'STANDARD' END AS LINE_TYPE,
    GREATEST(1, ROUND(POWER(R_QTY, 2.5) * 200))::INT                                   AS QTY_ABS,
    DATEADD(day, IFF(ORDER_TYPE = 'RUSH', 1 + MOD(REQ_LEAD, 3), REQ_LEAD), ORDER_DATE)::DATE AS REQUESTED_DATE,
    IFF(R_CONF < IFF(IS_PUNE, 0.40, 0.22), CONF_SLIP, 0)                               AS CONF_SLIP_DAYS,
    R_RESCHED < IFF(IS_PUNE, 0.25, 0.08)                                               AS IS_RESCHEDULED
  FROM j
),
e AS (
  SELECT d.*,
    DATEADD(day, CONF_SLIP_DAYS, REQUESTED_DATE)::DATE                                 AS FIRST_CONFIRMED_DATE,
    CASE WHEN NOT IS_RESCHEDULED            THEN NULL
         WHEN R_REASON < 0.35               THEN 'CUSTOMER_REQUEST'
         WHEN R_REASON < 0.80 OR IS_PUNE    THEN 'MATERIAL_SHORTAGE'
         ELSE 'CAPACITY' END                                                           AS RESCHEDULE_REASON,
    IFF(LINE_TYPE = 'RETURN', -QTY_ABS, QTY_ABS)                                       AS QTY_ORDERED,
    CASE WHEN LINE_TYPE = 'RETURN'                 THEN 0
         WHEN R_CANCEL < 0.03                      THEN QTY_ABS
         WHEN R_CANCEL < 0.05 AND QTY_ABS > 1      THEN LEAST(QTY_ABS - 1, 1 + FLOOR(QTY_ABS * 0.5 * (R_CANCEL - 0.03) / 0.02))
         ELSE 0 END                                                                    AS QTY_CANCELLED,
    IFF(LINE_TYPE = 'FREE_OF_CHARGE', 0,
        ROUND(STANDARD_COST * (1.25 + R_PRICE * 0.6) * IFF(CURRENCY = 'EUR', 0.92, 1), 2)) AS UNIT_PRICE,
    CASE WHEN NOT IS_PUNE THEN
           CASE WHEN R_DELAY < 0.82 THEN -FLOOR(R_DELAY_MAG * 2)
                WHEN R_DELAY < 0.96 THEN 1 + FLOOR(R_DELAY_MAG * 3)
                ELSE 4 + FLOOR(R_DELAY_MAG * 8) END
         ELSE
           CASE WHEN R_DELAY < 0.50 THEN -FLOOR(R_DELAY_MAG * 2)
                WHEN R_DELAY < 0.80 THEN 1 + FLOOR(R_DELAY_MAG * 5)
                ELSE 6 + FLOOR(R_DELAY_MAG * 12) END
    END                                                                                AS SHIP_DELAY_DAYS
  FROM d
),
f AS (
  SELECT e.*,
    DATEADD(day, IFF(IS_RESCHEDULED, RESCHED_DAYS, 0), FIRST_CONFIRMED_DATE)::DATE     AS PROMISED_DATE,
    IFF(LINE_TYPE = 'RETURN', 0, QTY_ORDERED - QTY_CANCELLED)                          AS REQUIRED_QTY
  FROM e
),
h AS (
  SELECT f.*,
    IFF(REQUIRED_QTY >= 2 AND R_SHORT < IFF(IS_PUNE, 0.10, 0.02),
        GREATEST(1, FLOOR(REQUIRED_QTY * SHORT_FRAC)), REQUIRED_QTY)                    AS TOTAL_SHIP_QTY,
    GREATEST(ORDER_DATE, DATEADD(day, SHIP_DELAY_DAYS - TRANSIT_DAYS, PROMISED_DATE))::DATE AS SHIP1_DATE
  FROM f
),
k AS (
  SELECT h.*,
    CASE WHEN TOTAL_SHIP_QTY = 0                                                   THEN 0
         WHEN TOTAL_SHIP_QTY >= 3 AND R_SPLIT < IFF(IS_PUNE, 0.12, 0.04)          THEN 3
         WHEN TOTAL_SHIP_QTY >= 3 AND R_SPLIT < IFF(IS_PUNE, 0.35, 0.12)          THEN 2
         ELSE 1 END                                                                AS SPLIT_CNT
  FROM h
)
SELECT
  'OL' || LPAD(N, 7, '0')                                     AS ORDER_LINE_ID,
  SO_ID,
  10 * ROW_NUMBER() OVER (PARTITION BY SO_ID ORDER BY N)      AS LINE_NO,
  PART_ID, PLANT_ID, IS_PUNE, BASE_UOM, CURRENCY, ORDER_DATE, LINE_TYPE,
  QTY_ORDERED, QTY_CANCELLED, REQUIRED_QTY, TOTAL_SHIP_QTY, UNIT_PRICE,
  REQUESTED_DATE, FIRST_CONFIRMED_DATE, PROMISED_DATE, RESCHEDULE_REASON,
  TRANSIT_DAYS, SPLIT_CNT,
  CASE SPLIT_CNT WHEN 1 THEN TOTAL_SHIP_QTY
                 WHEN 2 THEN GREATEST(1, FLOOR(TOTAL_SHIP_QTY * 0.6))
                 WHEN 3 THEN GREATEST(1, FLOOR(TOTAL_SHIP_QTY * 0.5))
                 ELSE 0 END                                   AS Q1,
  CASE SPLIT_CNT WHEN 2 THEN TOTAL_SHIP_QTY - GREATEST(1, FLOOR(TOTAL_SHIP_QTY * 0.6))
                 WHEN 3 THEN GREATEST(1, FLOOR(TOTAL_SHIP_QTY * 0.3))
                 ELSE 0 END                                   AS Q2,
  CASE SPLIT_CNT WHEN 3 THEN TOTAL_SHIP_QTY - GREATEST(1, FLOOR(TOTAL_SHIP_QTY * 0.5))
                                            - GREATEST(1, FLOOR(TOTAL_SHIP_QTY * 0.3))
                 ELSE 0 END                                   AS Q3,
  SHIP1_DATE                                                  AS S1,
  DATEADD(day, GAP2, SHIP1_DATE)::DATE                        AS S2,
  DATEADD(day, GAP2 + GAP3, SHIP1_DATE)::DATE                 AS S3
FROM k;

-- -----------------------------------------------------------------------------
-- ORDER_LINES
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE ORDER_LINES AS
WITH p AS (
  SELECT _LINE_PLAN.*,
    IFF(SPLIT_CNT >= 1 AND S1 < $AS_OF, Q1, 0)
  + IFF(SPLIT_CNT >= 2 AND S2 < $AS_OF, Q2, 0)
  + IFF(SPLIT_CNT  = 3 AND S3 < $AS_OF, Q3, 0)                              AS SHIPPED_QTY,
    DATEADD(day, TRANSIT_DAYS, CASE SPLIT_CNT WHEN 3 THEN S3 WHEN 2 THEN S2 ELSE S1 END) AS LAST_ARRIVAL
  FROM _LINE_PLAN
)
SELECT
  ORDER_LINE_ID, SO_ID, LINE_NO, PART_ID, PLANT_ID, LINE_TYPE,
  QTY_ORDERED, QTY_CANCELLED, BASE_UOM, UNIT_PRICE, CURRENCY,
  REQUESTED_DATE, FIRST_CONFIRMED_DATE, PROMISED_DATE, RESCHEDULE_REASON,
  CASE WHEN LINE_TYPE = 'RETURN'          THEN 'CLOSED'
       WHEN REQUIRED_QTY = 0              THEN 'CANCELLED'
       WHEN SHIPPED_QTY = 0               THEN 'OPEN'
       WHEN SHIPPED_QTY < TOTAL_SHIP_QTY  THEN 'PARTIALLY_SHIPPED'
       WHEN LAST_ARRIVAL >= $AS_OF        THEN 'SHIPPED'
       WHEN TOTAL_SHIP_QTY < REQUIRED_QTY THEN 'CLOSED_SHORT'
       ELSE 'DELIVERED' END               AS STATUS
FROM p
ORDER BY ORDER_LINE_ID;

-- -----------------------------------------------------------------------------
-- ERP_SHIPMENTS (outbound deliveries; one row per delivery that has shipped)
--   SHIP_DATE           goods issue, plant-local business date
--   GOODS_RECEIPT_DATE  customer receipt confirmation, ship-to local date
--                       (NULL if not yet arrived or never confirmed)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE ERP_SHIPMENTS AS
WITH s AS (
  SELECT p.ORDER_LINE_ID, p.SO_ID, p.PLANT_ID, p.PART_ID, p.TRANSIT_DAYS, x.SEQ,
         CASE x.SEQ WHEN 1 THEN p.Q1 WHEN 2 THEN p.Q2 ELSE p.Q3 END AS QTY,
         CASE x.SEQ WHEN 1 THEN p.S1 WHEN 2 THEN p.S2 ELSE p.S3 END AS SHIP_DATE
  FROM _LINE_PLAN p
  JOIN (SELECT COLUMN1 AS SEQ FROM VALUES (1), (2), (3)) x ON x.SEQ <= p.SPLIT_CNT
),
r AS (
  SELECT s.*,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(501)) AS R_GR,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(502)) AS R_SUB,
         UNIFORM(1, 2000, RANDOM(503))            AS SUB_N
  FROM s
  WHERE SHIP_DATE < $AS_OF
)
SELECT
  '80' || LPAD(ROW_NUMBER() OVER (ORDER BY ORDER_LINE_ID, SEQ), 8, '0')  AS DELIVERY_ID,
  ORDER_LINE_ID,
  SO_ID,
  SEQ                                                                    AS DELIVERY_SEQ,
  PLANT_ID,
  IFF(R_SUB < 0.005, 'P' || LPAD(SUB_N, 6, '0'), PART_ID)                AS PART_ID_SHIPPED,
  QTY                                                                    AS QTY_SHIPPED,
  SHIP_DATE,
  IFF(DATEADD(day, TRANSIT_DAYS, SHIP_DATE) < $AS_OF AND R_GR >= 0.03,
      DATEADD(day, TRANSIT_DAYS, SHIP_DATE)::DATE, NULL)                 AS GOODS_RECEIPT_DATE
FROM r
ORDER BY DELIVERY_ID;

-- -----------------------------------------------------------------------------
-- Row counts
-- -----------------------------------------------------------------------------
SELECT 'PLANTS' AS TABLE_NAME, COUNT(*) AS ROW_COUNT FROM PLANTS
UNION ALL SELECT 'CUSTOMERS',     COUNT(*) FROM CUSTOMERS
UNION ALL SELECT 'PARTS',         COUNT(*) FROM PARTS
UNION ALL SELECT 'SALES_ORDERS',  COUNT(*) FROM SALES_ORDERS
UNION ALL SELECT 'ORDER_LINES',   COUNT(*) FROM ORDER_LINES
UNION ALL SELECT 'ERP_SHIPMENTS', COUNT(*) FROM ERP_SHIPMENTS;
