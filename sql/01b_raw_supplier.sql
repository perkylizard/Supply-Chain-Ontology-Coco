-- =============================================================================
-- 01b_raw_supplier.sql
-- Synthetic supplier-side data for SC.RAW_SUPPLIER (12 months ending today).
-- Depends on: sql/01a_raw_erp.sql (SC.RAW_ERP.PARTS, SC.RAW_ERP.PLANTS)
-- Built with GENERATOR / UNIFORM / RANDOM. Re-runnable (CREATE OR REPLACE).
--
-- Tables: SUPPLIERS(50) SUPPLIER_PARTS PURCHASE_ORDERS(20k PO lines) ASNS SUPPLIER_INVOICES GOODS_RECEIPTS
-- Internal: SC.OPS.GEN_INBOUND_PLAN keeps the generator's "true" inbound arrival
--           dates so later scripts (receipts, inbound logistics) stay consistent.
--
-- Planted on purpose:
--   * SUPPLIER_PART_NO in supplier format ('ACME-00123') vs ERP PART_ID ('P000123');
--     ~2% orphans whose number maps to no ERP part
--   * 2 clearly late suppliers: S0011 Kronos Castings (KRON), S0022 Vela Polymers (VELA)
--     - confirm late, reschedule often, ship late, split and short-ship more,
--       cheapest unit price but frequent expedite surcharges; ~50% of their POs ship to Pune
--   * unconfirmed PO lines (no FIRST_CONFIRMED_DATE), buyer vs supplier reschedules
--   * cancelled PO lines (STATUS CLOSED, QTY_CANCELLED = QTY_ORDERED)
--   * SERVICE / NON_STOCK lines (excluded by the Supplier OTD contract)
--   * invoice price variances; freight / duty on the invoice only for prepaid Incoterms
--   * recoverable tax on invoices (excluded from Landed Cost by contract)
-- =============================================================================

USE ROLE SC_ADMIN;
USE WAREHOUSE SC_WH;
USE SCHEMA SC.RAW_SUPPLIER;
ALTER SESSION SET TIMEZONE = 'UTC';

SET AS_OF      = CURRENT_DATE();
SET START_DATE = DATEADD(day, -365, $AS_OF);

-- -----------------------------------------------------------------------------
-- SUPPLIERS
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE SUPPLIERS AS
WITH s AS (
  SELECT * FROM VALUES
    (1,'ACME','Acme Components','US'),      (2,'BOLT','Boltline Fasteners','US'),
    (3,'CORE','Corelink Electronics','CN'), (4,'DYNA','Dynamo Motors','DE'),
    (5,'ELEC','Electra Cables','MX'),       (6,'FLUX','Flux Hydraulics','DE'),
    (7,'GEAR','Gearworks Precision','IN'),  (8,'HELI','Helios Sensors','JP'),
    (9,'IRON','Ironside Castings','PL'),    (10,'JADE','Jade Packaging','CN'),
    (11,'KRON','Kronos Castings','CN'),     (12,'LUMA','Luma Controls','KR'),
    (13,'MERI','Meridian Seals','IT'),      (14,'NOVA','Nova Plastics','IN'),
    (15,'OMNI','Omni Switchgear','FR'),     (16,'PRIM','Prime Bearings','DE'),
    (17,'QUAD','Quadra Valves','US'),       (18,'RIVT','Rivet & Co','GB'),
    (19,'SIGM','Sigma Pumps','IT'),         (20,'TERA','Tera Chemicals','NL'),
    (21,'ULTR','Ultra Films','VN'),         (22,'VELA','Vela Polymers','IN'),
    (23,'WAVE','Wave Electronics','TW'),    (24,'XENO','Xeno Adhesives','US'),
    (25,'YARR','Yarrow Pallets','MX'),      (26,'ZEPH','Zephyr Coolants','DE'),
    (27,'ALTA','Alta Shafts','CZ'),         (28,'BRAV','Bravo Cartons','PL'),
    (29,'CRES','Crest Lubricants','US'),    (30,'DELT','Delta Connectors','MY'),
    (31,'EAGL','Eagle Gears','MX'),         (32,'FORT','Fortis Motors','CN'),
    (33,'GRAN','Granite Bearings','IN'),    (34,'HARB','Harbor Packaging','SG'),
    (35,'INDI','Indigo Sensors','IN'),      (36,'JUNO','Juno Valves','ES'),
    (37,'KEST','Kestrel Pumps','GB'),       (38,'LYNX','Lynx Controllers','TW'),
    (39,'MAPL','Maple Cables','CA'),        (40,'NORD','Nordic Seals','SE'),
    (41,'ORIO','Orion Electronics','KR'),   (42,'PION','Pioneer Switchgear','US'),
    (43,'QUAR','Quartz Chemicals','DE'),    (44,'ROCK','Rockford Fasteners','US'),
    (45,'SOLA','Solaris Films','TH'),       (46,'TITN','Titan Castings','CN'),
    (47,'UNIT','Unity Adhesives','NL'),     (48,'VIST','Vista Coolants','FR'),
    (49,'WOLF','Wolfram Shafts','AT'),      (50,'ZENI','Zenith Motors','JP')
  AS t(N, SUPPLIER_CODE, SUPPLIER_NAME, COUNTRY_CODE)
)
SELECT
  'S' || LPAD(N, 4, '0')                                   AS SUPPLIER_ID,
  '1000' || LPAD(N, 3, '0')                                AS ERP_VENDOR_NO,
  SUPPLIER_CODE,
  SUPPLIER_NAME,
  COUNTRY_CODE,
  CASE WHEN COUNTRY_CODE IN ('US','MX','CA') THEN 'NA'
       WHEN COUNTRY_CODE IN ('CN','IN','JP','KR','VN','TW','MY','SG','TH') THEN 'APAC'
       ELSE 'EMEA' END                                     AS REGION,
  'USD'                                                    AS CURRENCY,
  GET(ARRAY_CONSTRUCT('NET30','NET45','NET60'), MOD(N, 3))::VARCHAR AS PAYMENT_TERMS,
  DATEADD(day, -(400 + N * 37), $AS_OF)::DATE              AS ONBOARDED_DATE
FROM s;

-- -----------------------------------------------------------------------------
-- Supplier-part sourcing (temp, keeps the true PART_ID for generation)
--   rank 1 for every part (8% KRON, 8% VELA, else random), rank 2 for 40%, rank 3 for 10%
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE _SP AS
WITH p AS (
  SELECT pt.PART_ID, TO_NUMBER(SUBSTR(pt.PART_ID, 2)) AS PART_NUM, pt.STANDARD_COST, pt.FAMILY,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(601)) AS R1, UNIFORM(1, 50, RANDOM(602)) AS S1N,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(603)) AS R2, UNIFORM(1, 50, RANDOM(604)) AS S2N,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(605)) AS R3, UNIFORM(1, 50, RANDOM(606)) AS S3N
  FROM SC.RAW_ERP.PARTS pt
),
slots AS (
            SELECT PART_ID, PART_NUM, STANDARD_COST, FAMILY, 1 AS SOURCE_RANK,
                   CASE WHEN R1 < 0.08 THEN 11 WHEN R1 < 0.16 THEN 22 ELSE S1N END AS SUP_N FROM p
  UNION ALL SELECT PART_ID, PART_NUM, STANDARD_COST, FAMILY, 2, S2N FROM p WHERE R2 < 0.40
  UNION ALL SELECT PART_ID, PART_NUM, STANDARD_COST, FAMILY, 3, S3N FROM p WHERE R3 < 0.10
),
dedup AS (
  SELECT * FROM slots
  QUALIFY ROW_NUMBER() OVER (PARTITION BY PART_ID, SUP_N ORDER BY SOURCE_RANK) = 1
),
r AS (
  SELECT d.*, s.SUPPLIER_ID, s.SUPPLIER_CODE,
         s.SUPPLIER_CODE IN ('KRON', 'VELA')         AS IS_BAD,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(611))    AS R_ORPH,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(612))    AS R_PRICE,
         UNIFORM(7, 45, RANDOM(613))                 AS LT,
         UNIFORM(0, 4, RANDOM(614))                  AS MOQ_I,
         UNIFORM(30, 1500, RANDOM(615))              AS VF
  FROM dedup d JOIN SUPPLIERS s ON s.SUPPLIER_ID = 'S' || LPAD(d.SUP_N, 4, '0')
)
SELECT
  SUPPLIER_ID, SUPPLIER_CODE, PART_ID, FAMILY, SOURCE_RANK, IS_BAD,
  R_ORPH < 0.02                                                                AS IS_ORPHAN,
  -- orphans: number shifted out of the ERP part range, so it maps to no PART_ID
  SUPPLIER_CODE || '-' || LPAD(IFF(R_ORPH < 0.02, PART_NUM + 7000, PART_NUM), 5, '0') AS SUPPLIER_PART_NO,
  -- late suppliers are the cheapest on paper
  ROUND(STANDARD_COST * IFF(IS_BAD, 0.50 + R_PRICE * 0.15, 0.60 + R_PRICE * 0.25), 2)  AS UNIT_PRICE,
  -- ...and quote short lead times
  IFF(IS_BAD, LEAST(LT, 20), LT)                                               AS LEAD_TIME_DAYS,
  GET(ARRAY_CONSTRUCT(1, 10, 25, 50, 100), MOQ_I)::INT                         AS MOQ,
  DATEADD(day, -VF, $AS_OF)::DATE                                              AS VALID_FROM
FROM r;

CREATE OR REPLACE TABLE SUPPLIER_PARTS AS
SELECT
  SUPPLIER_ID,
  SUPPLIER_PART_NO,
  UPPER(FAMILY) || ' ITEM ' || RIGHT(SUPPLIER_PART_NO, 5)  AS SUPPLIER_DESCRIPTION,
  UNIT_PRICE,
  'USD'                                                    AS CURRENCY,
  LEAD_TIME_DAYS,
  MOQ,
  SOURCE_RANK = 1                                          AS IS_PREFERRED,
  VALID_FROM,
  NULL::DATE                                               AS VALID_TO
FROM _SP
ORDER BY SUPPLIER_ID, SUPPLIER_PART_NO;

-- -----------------------------------------------------------------------------
-- PO headers (temp): 8,000 POs; KRON / VELA ship ~50% of their POs to Pune
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE _PO_HDR AS
WITH g AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4())      AS N,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(701)) AS R_SUP,
         UNIFORM(1, 50, RANDOM(702))              AS SUP_N,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(703)) AS R_PL,
         UNIFORM(1, 8, RANDOM(704))               AS PL_N,
         UNIFORM(0, 364, RANDOM(705))             AS DAY_OFF
  FROM TABLE(GENERATOR(ROWCOUNT => 8000))
),
pl AS (SELECT PLANT_ID, REGION, ROW_NUMBER() OVER (ORDER BY PLANT_ID) AS PL_N FROM SC.RAW_ERP.PLANTS)
SELECT
  'PO' || LPAD(g.N, 7, '0')                   AS PO_ID,
  s.SUPPLIER_ID,
  s.REGION                                    AS SUP_REGION,
  s.SUPPLIER_CODE IN ('KRON', 'VELA')         AS IS_BAD,
  pl.PLANT_ID,
  pl.REGION                                   AS PLANT_REGION,
  DATEADD(day, g.DAY_OFF, $START_DATE)::DATE  AS ORDER_DATE
FROM g
JOIN SUPPLIERS s ON s.SUPPLIER_ID = 'S' || LPAD(CASE WHEN g.R_SUP < 0.08 THEN 11 WHEN g.R_SUP < 0.16 THEN 22 ELSE g.SUP_N END, 4, '0')
JOIN pl ON IFF(s.SUPPLIER_CODE IN ('KRON', 'VELA') AND g.R_PL < 0.5, pl.PLANT_ID = 'IN01', pl.PL_N = g.PL_N);

-- -----------------------------------------------------------------------------
-- Inbound plan: one row per PO line with every generated outcome.
-- Persisted in SC.OPS (not visible to personas) so later inbound sources
-- (goods receipts, inbound shipments / POD) can reuse the same truth.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE SC.OPS.GEN_INBOUND_PLAN AS
WITH g AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4())           AS N,
         UNIFORM(1, 8000, RANDOM(801))                 AS HDR_RAND,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(802))      AS R_PART,
         UNIFORM(1, 20, RANDOM(803))                   AS QTY_MULT,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(804))      AS R_TYPE,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(805))      AS R_CONF,
         UNIFORM(1, 7, RANDOM(806))                    AS CONF_SLIP,
         UNIFORM(3, 15, RANDOM(807))                   AS CONF_SLIP_BAD,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(808))      AS R_UNCONF,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(809))      AS R_RESCHED,
         UNIFORM(2, 14, RANDOM(810))                   AS RESCHED_DAYS,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(811))      AS R_REASON,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(812))      AS R_DELAY,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(813))      AS R_DELAY_MAG,
         UNIFORM(2, 5, RANDOM(814))                    AS TRANSIT_NEAR,
         UNIFORM(12, 30, RANDOM(815))                  AS TRANSIT_FAR,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(816))      AS R_SPLIT,
         UNIFORM(3, 12, RANDOM(817))                   AS GAP,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(818))      AS R_SHORT,
         UNIFORM(0.90::FLOAT, 0.99::FLOAT, RANDOM(819)) AS SHORT_FRAC_N,
         UNIFORM(0.60::FLOAT, 0.90::FLOAT, RANDOM(820)) AS SHORT_FRAC_B,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(821))      AS R_CANCEL,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(822))      AS R_INCO
  FROM TABLE(GENERATOR(ROWCOUNT => 20000))
),
h AS (
  -- first 8k lines map 1:1 to headers so every PO has at least one line
  SELECT g.*, hd.*
  FROM g JOIN _PO_HDR hd ON hd.PO_ID = 'PO' || LPAD(IFF(g.N <= 8000, g.N, g.HDR_RAND), 7, '0')
),
spn AS (
  SELECT _SP.*,
         ROW_NUMBER() OVER (PARTITION BY SUPPLIER_ID ORDER BY SUPPLIER_PART_NO) AS K,
         COUNT(*)     OVER (PARTITION BY SUPPLIER_ID)                           AS NK
  FROM _SP
),
l AS (
  SELECT h.*, spn.SUPPLIER_PART_NO, spn.PART_ID, spn.IS_ORPHAN,
         spn.UNIT_PRICE AS LIST_PRICE, spn.LEAD_TIME_DAYS, spn.MOQ
  FROM h JOIN spn ON spn.SUPPLIER_ID = h.SUPPLIER_ID AND spn.K = 1 + FLOOR(h.R_PART * spn.NK)
),
d AS (
  SELECT l.*,
    10 * ROW_NUMBER() OVER (PARTITION BY PO_ID ORDER BY N)                        AS PO_LINE_NO,
    CASE WHEN R_TYPE < 0.02 THEN 'SERVICE' WHEN R_TYPE < 0.05 THEN 'NON_STOCK' ELSE 'STOCK' END AS ITEM_CATEGORY,
    MOQ * QTY_MULT                                                                AS QTY_ORDERED,
    IFF(SUP_REGION = PLANT_REGION, TRANSIT_NEAR, TRANSIT_FAR)                     AS TRANSIT_DAYS,
    CASE WHEN SUP_REGION = PLANT_REGION
         THEN CASE WHEN R_INCO < 0.4 THEN 'DAP' WHEN R_INCO < 0.7 THEN 'FCA' ELSE 'EXW' END
         ELSE CASE WHEN R_INCO < 0.5 THEN 'FOB' WHEN R_INCO < 0.8 THEN 'CIF' ELSE 'DDP' END
    END                                                                           AS INCOTERM
  FROM l
),
e AS (
  SELECT d.*,
    -- buyer's need date = quoted lead time + transit
    DATEADD(day, LEAD_TIME_DAYS + TRANSIT_DAYS, ORDER_DATE)::DATE                 AS DUE_DATE
  FROM d
),
f AS (
  SELECT e.*,
    IFF(R_UNCONF < IFF(IS_BAD, 0.10, 0.04), NULL,
        DATEADD(day, IFF(IS_BAD, IFF(R_CONF < 0.40, 0, CONF_SLIP_BAD),
                                 IFF(R_CONF < 0.85, 0, CONF_SLIP)), DUE_DATE))::DATE AS FIRST_CONFIRMED_DATE,
    R_RESCHED < IFF(IS_BAD, 0.30, 0.10)                                           AS IS_RESCHEDULED,
    IFF(R_CANCEL < 0.03, QTY_ORDERED, 0)                                          AS QTY_CANCELLED,
    CASE WHEN NOT IS_BAD THEN
           CASE WHEN R_DELAY < 0.80 THEN -FLOOR(R_DELAY_MAG * 2)
                WHEN R_DELAY < 0.95 THEN 1 + FLOOR(R_DELAY_MAG * 3)
                ELSE 4 + FLOOR(R_DELAY_MAG * 7) END
         ELSE
           CASE WHEN R_DELAY < 0.30 THEN -FLOOR(R_DELAY_MAG * 2)
                WHEN R_DELAY < 0.60 THEN 2 + FLOOR(R_DELAY_MAG * 6)
                ELSE 8 + FLOOR(R_DELAY_MAG * 18) END
    END                                                                           AS ARRIVAL_DELAY_DAYS
  FROM e
),
k AS (
  SELECT f.*,
    CASE WHEN NOT IS_RESCHEDULED                 THEN NULL
         WHEN IS_BAD OR R_REASON >= 0.30         THEN 'SUPPLIER_DELAY'
         ELSE 'BUYER_REQUEST' END                                                 AS RESCHEDULE_REASON,
    DATEADD(day, IFF(IS_RESCHEDULED, RESCHED_DAYS, 0), COALESCE(FIRST_CONFIRMED_DATE, DUE_DATE))::DATE AS LATEST_CONFIRMED_DATE,
    QTY_ORDERED - QTY_CANCELLED                                                   AS REQUIRED_QTY
  FROM f
),
m AS (
  SELECT k.*,
    CASE WHEN REQUIRED_QTY = 0 THEN 0
         WHEN R_SHORT < IFF(IS_BAD, 0.15, 0.02)
           THEN GREATEST(1, FLOOR(REQUIRED_QTY * IFF(IS_BAD, SHORT_FRAC_B, SHORT_FRAC_N)))
         ELSE REQUIRED_QTY END                                                    AS TOTAL_SHIP_QTY,
    GREATEST(DATEADD(day, TRANSIT_DAYS + 1, ORDER_DATE),
             DATEADD(day, ARRIVAL_DELAY_DAYS, LATEST_CONFIRMED_DATE))::DATE       AS ARRIVAL1_DATE
  FROM k
)
SELECT
  PO_ID, PO_LINE_NO, SUPPLIER_ID, IS_BAD, SUP_REGION, PLANT_ID, PLANT_REGION,
  SUPPLIER_PART_NO, PART_ID, IS_ORPHAN, ITEM_CATEGORY, INCOTERM,
  ORDER_DATE, DUE_DATE, FIRST_CONFIRMED_DATE, LATEST_CONFIRMED_DATE, RESCHEDULE_REASON,
  QTY_ORDERED, QTY_CANCELLED, REQUIRED_QTY, TOTAL_SHIP_QTY, LIST_PRICE, TRANSIT_DAYS,
  CASE WHEN TOTAL_SHIP_QTY = 0 THEN 0
       WHEN TOTAL_SHIP_QTY >= 2 AND R_SPLIT < IFF(IS_BAD, 0.25, 0.08) THEN 2
       ELSE 1 END                                                                 AS ASN_CNT,
  IFF(ASN_CNT = 2, GREATEST(1, FLOOR(TOTAL_SHIP_QTY * 0.6)), TOTAL_SHIP_QTY)      AS Q1,
  IFF(ASN_CNT = 2, TOTAL_SHIP_QTY - GREATEST(1, FLOOR(TOTAL_SHIP_QTY * 0.6)), 0)  AS Q2,
  ARRIVAL1_DATE,
  DATEADD(day, GAP, ARRIVAL1_DATE)::DATE                                          AS ARRIVAL2_DATE,
  DATEADD(day, -TRANSIT_DAYS, ARRIVAL1_DATE)::DATE                                AS SHIP1_DATE,
  DATEADD(day, GAP - TRANSIT_DAYS, ARRIVAL1_DATE)::DATE                           AS SHIP2_DATE
FROM m;

-- -----------------------------------------------------------------------------
-- PURCHASE_ORDERS (one row per PO line)
--   STATUS: CLOSED = fully cancelled, or all ASNs shipped and arrived; else OPEN
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE PURCHASE_ORDERS AS
SELECT
  PO_ID, PO_LINE_NO, SUPPLIER_ID, SUPPLIER_PART_NO,
  PLANT_ID                                      AS SHIP_TO_PLANT_ID,
  ITEM_CATEGORY, ORDER_DATE,
  QTY_ORDERED, QTY_CANCELLED,
  LIST_PRICE                                    AS UNIT_PRICE,
  'USD'                                         AS CURRENCY,
  INCOTERM,
  DUE_DATE, FIRST_CONFIRMED_DATE, LATEST_CONFIRMED_DATE, RESCHEDULE_REASON,
  CASE WHEN REQUIRED_QTY = 0 THEN 'CLOSED'
       WHEN IFF(ASN_CNT = 2, ARRIVAL2_DATE, ARRIVAL1_DATE) < $AS_OF THEN 'CLOSED'
       ELSE 'OPEN' END                          AS STATUS
FROM SC.OPS.GEN_INBOUND_PLAN
ORDER BY PO_ID, PO_LINE_NO;

-- -----------------------------------------------------------------------------
-- ASNS (one row per advance ship notice that has shipped)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE ASNS AS
WITH a AS (
  SELECT p.PO_ID, p.PO_LINE_NO, p.SUPPLIER_ID, p.SUPPLIER_PART_NO, p.PLANT_ID, p.TRANSIT_DAYS, x.SEQ,
         IFF(x.SEQ = 1, p.SHIP1_DATE, p.SHIP2_DATE) AS SHIP_DATE,
         IFF(x.SEQ = 1, p.Q1, p.Q2)                 AS QTY
  FROM SC.OPS.GEN_INBOUND_PLAN p
  JOIN (SELECT COLUMN1 AS SEQ FROM VALUES (1), (2)) x ON x.SEQ <= p.ASN_CNT
)
SELECT
  'ASN' || LPAD(ROW_NUMBER() OVER (ORDER BY PO_ID, PO_LINE_NO, SEQ), 8, '0') AS ASN_ID,
  PO_ID, PO_LINE_NO, SUPPLIER_ID, SUPPLIER_PART_NO,
  PLANT_ID                                               AS SHIP_TO_PLANT_ID,
  SEQ                                                    AS ASN_SEQ,
  SHIP_DATE,
  DATEADD(day, TRANSIT_DAYS, SHIP_DATE)::DATE            AS EXPECTED_DELIVERY_DATE,
  QTY                                                    AS QTY_SHIPPED
FROM a
WHERE SHIP_DATE < $AS_OF
ORDER BY ASN_ID;

-- -----------------------------------------------------------------------------
-- SUPPLIER_INVOICES (one per ASN, once issued)
--   FREIGHT_AMOUNT / DUTY_AMOUNT only when the supplier prepays (CIF / DAP / DDP);
--   otherwise freight is billed by the carrier (logistics freight invoices).
--   TAX_AMOUNT is recoverable VAT / GST: excluded from Landed Cost by contract.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE SUPPLIER_INVOICES AS
WITH a AS (
  SELECT a.ASN_ID, a.PO_ID, a.PO_LINE_NO, a.SUPPLIER_ID, a.SUPPLIER_PART_NO, a.SHIP_DATE, a.QTY_SHIPPED,
         p.INCOTERM, p.LIST_PRICE, p.IS_BAD, p.PLANT_REGION,
         COALESCE(pt.UNIT_WEIGHT_KG, 1)                    AS UNIT_WEIGHT_KG,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(901))          AS R_PV,
         UNIFORM(-0.08::FLOAT, 0.08::FLOAT, RANDOM(902))   AS PV,
         UNIFORM(0, 10, RANDOM(903))                       AS INV_LAG,
         UNIFORM(0.15::FLOAT, 0.60::FLOAT, RANDOM(904))    AS FRT_RATE,
         UNIFORM(0.02::FLOAT, 0.12::FLOAT, RANDOM(905))    AS DUTY_RATE,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(906))          AS R_OTHER,
         UNIFORM(25, 400, RANDOM(907))                     AS OTHER_AMT
  FROM ASNS a
  JOIN SC.OPS.GEN_INBOUND_PLAN p ON p.PO_ID = a.PO_ID AND p.PO_LINE_NO = a.PO_LINE_NO
  LEFT JOIN SC.RAW_ERP.PARTS pt  ON pt.PART_ID = p.PART_ID
),
b AS (
  SELECT a.*,
    DATEADD(day, INV_LAG, SHIP_DATE)::DATE                              AS INVOICE_DATE,
    ROUND(LIST_PRICE * IFF(R_PV < 0.05, 1 + PV, 1), 2)                  AS INV_UNIT_PRICE
  FROM a
),
c AS (
  SELECT b.*,
    ROUND(QTY_SHIPPED * INV_UNIT_PRICE, 2)                                                AS GOODS_AMOUNT,
    IFF(INCOTERM IN ('CIF', 'DAP', 'DDP'), ROUND(40 + QTY_SHIPPED * UNIT_WEIGHT_KG * FRT_RATE, 2), 0) AS FREIGHT_AMOUNT,
    IFF(R_OTHER < IFF(IS_BAD, 0.35, 0.10), OTHER_AMT, 0)                                  AS OTHER_CHARGES,
    CASE WHEN R_OTHER >= IFF(IS_BAD, 0.35, 0.10) THEN NULL
         WHEN IS_BAD                              THEN 'EXPEDITE_SURCHARGE'
         WHEN R_OTHER < 0.05                      THEN 'PACKAGING'
         ELSE 'HANDLING' END                                                              AS OTHER_CHARGES_TYPE
  FROM b
)
SELECT
  'INV' || LPAD(ROW_NUMBER() OVER (ORDER BY ASN_ID), 8, '0')   AS INVOICE_ID,
  SUPPLIER_ID, PO_ID, PO_LINE_NO, ASN_ID, SUPPLIER_PART_NO,
  INVOICE_DATE,
  QTY_SHIPPED                                                  AS QTY_INVOICED,
  INV_UNIT_PRICE                                               AS UNIT_PRICE,
  GOODS_AMOUNT,
  FREIGHT_AMOUNT,
  IFF(INCOTERM = 'DDP', ROUND(GOODS_AMOUNT * DUTY_RATE, 2), 0) AS DUTY_AMOUNT,
  OTHER_CHARGES,
  OTHER_CHARGES_TYPE,
  ROUND(GOODS_AMOUNT * CASE PLANT_REGION WHEN 'EMEA' THEN 0.20 WHEN 'APAC' THEN 0.10 ELSE 0 END, 2) AS TAX_AMOUNT,
  TRUE                                                         AS IS_TAX_RECOVERABLE,
  'USD'                                                        AS CURRENCY,
  INCOTERM
FROM c
WHERE INVOICE_DATE < $AS_OF
ORDER BY INVOICE_ID;

-- -----------------------------------------------------------------------------
-- GOODS_RECEIPTS (one ERP goods receipt per ASN that has arrived and been posted)
--   ARRIVAL_LOCAL_DATE = generator's true dock arrival (plan ARRIVAL1/2_DATE), so
--     KRON / VELA receipts inherit their planted late arrivals.
--   POSTING_DATE (GR posting, plant-local business date) lags arrival:
--     normal 0-2 days (~70% 1-2 days); KRON / VELA 1-5 days (QC inspection holds).
--   QTY_REJECTED: quality rejects, ~1% of receipts normally, ~12% for KRON / VELA.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE GOODS_RECEIPTS AS
WITH a AS (
  SELECT a.ASN_ID, a.PO_ID, a.PO_LINE_NO, a.SUPPLIER_ID, a.SUPPLIER_PART_NO, a.SHIP_TO_PLANT_ID,
         a.ASN_SEQ, a.QTY_SHIPPED, p.IS_BAD,
         IFF(a.ASN_SEQ = 1, p.ARRIVAL1_DATE, p.ARRIVAL2_DATE)    AS ARRIVAL_LOCAL_DATE,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(951))                AS R_LAG,
         UNIFORM(1, 5, RANDOM(952))                              AS LAG_BAD,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(953))                AS R_REJ,
         UNIFORM(0.02::FLOAT, 0.20::FLOAT, RANDOM(954))          AS REJ_FRAC
  FROM ASNS a
  JOIN SC.OPS.GEN_INBOUND_PLAN p ON p.PO_ID = a.PO_ID AND p.PO_LINE_NO = a.PO_LINE_NO
),
b AS (
  SELECT a.*,
    DATEADD(day, IFF(IS_BAD, LAG_BAD,
                     CASE WHEN R_LAG < 0.30 THEN 0 WHEN R_LAG < 0.80 THEN 1 ELSE 2 END),
            ARRIVAL_LOCAL_DATE)::DATE                                            AS POSTING_DATE,
    IFF(R_REJ < IFF(IS_BAD, 0.12, 0.01), GREATEST(1, FLOOR(QTY_SHIPPED * REJ_FRAC)), 0) AS QTY_REJECTED
  FROM a
)
SELECT
  'GR' || LPAD(ROW_NUMBER() OVER (ORDER BY ASN_ID), 8, '0')   AS GR_ID,
  PO_ID, PO_LINE_NO, ASN_ID, SUPPLIER_ID, SUPPLIER_PART_NO, SHIP_TO_PLANT_ID,
  ARRIVAL_LOCAL_DATE,
  POSTING_DATE,
  QTY_SHIPPED                                                  AS QTY_RECEIVED,
  QTY_REJECTED,
  QTY_SHIPPED - QTY_REJECTED                                   AS QTY_ACCEPTED
FROM b
WHERE POSTING_DATE < $AS_OF
ORDER BY GR_ID;

-- -----------------------------------------------------------------------------
-- Row counts
-- -----------------------------------------------------------------------------
SELECT 'SUPPLIERS' AS TABLE_NAME, COUNT(*) AS ROW_COUNT FROM SUPPLIERS
UNION ALL SELECT 'SUPPLIER_PARTS',    COUNT(*) FROM SUPPLIER_PARTS
UNION ALL SELECT 'PURCHASE_ORDERS',   COUNT(*) FROM PURCHASE_ORDERS
UNION ALL SELECT 'ASNS',              COUNT(*) FROM ASNS
UNION ALL SELECT 'SUPPLIER_INVOICES', COUNT(*) FROM SUPPLIER_INVOICES
UNION ALL SELECT 'GOODS_RECEIPTS',    COUNT(*) FROM GOODS_RECEIPTS;
