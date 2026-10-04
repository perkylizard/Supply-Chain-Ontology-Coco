-- =============================================================================
-- 01e_raw_inbound_costs.sql
-- Synthetic inbound cost evidence for Landed Cost per Unit (12 months ending today).
-- Depends on: sql/01a_raw_erp.sql (PARTS, PLANTS), sql/01b_raw_supplier.sql
--             (ASNS, PURCHASE_ORDERS, SUPPLIERS, GOODS_RECEIPTS, OPS.GEN_INBOUND_PLAN),
--             sql/01c_raw_logistics.sql (CARRIERS)
-- Creates ONLY the two tables below; existing RAW tables are read, never rewritten.
-- Built with UNIFORM / RANDOM. Re-runnable (CREATE OR REPLACE).
--
-- Tables:
--   INBOUND_FREIGHT_INVOICES  carrier freight invoices (EDI 210) for buyer-paid
--                             Incoterms (EXW / FCA / FOB). One row per invoice line
--                             = one ASN on a consolidated load. LOAD_* amounts are
--                             load-level and repeat on every line of the invoice;
--                             allocate them to lines, never sum them across lines.
--   CUSTOMS_ENTRIES           import customs entries for cross-border, non-DDP ASNs
--                             (under DDP the supplier clears customs). One per ASN.
--
-- Planted on purpose:
--   * Loads: ASNs from the same supplier to the same plant on the same ship date
--     share one load and one freight invoice (allocation by max(actual, dim weight))
--   * ~2% of invoices miss line weights (allocation must fall back to line value)
--   * Invoice / entry lag: freight 3-30 days after arrival, customs 0-10 days, plus
--     ~4-5% never received -> roughly 90% coverage of the receipts that need them;
--     the gap is concentrated in the most recent weeks
--   * Demurrage / detention accessorials, more frequent for KRON / VELA loads
--   * Import VAT on entries is recoverable (excluded from Landed Cost by contract)
-- =============================================================================

USE ROLE SC_ADMIN;
USE WAREHOUSE SC_WH;
USE SCHEMA SC.RAW_SUPPLIER;
ALTER SESSION SET TIMEZONE = 'UTC';

SET AS_OF = CURRENT_DATE();

-- -----------------------------------------------------------------------------
-- Inbound ASN facts (temp): true arrival, weights, value, Incoterm, import flag
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE _INB AS
SELECT
  a.ASN_ID, a.PO_ID, a.PO_LINE_NO, a.SUPPLIER_ID, a.SHIP_TO_PLANT_ID, a.SHIP_DATE, a.QTY_SHIPPED,
  IFF(a.ASN_SEQ = 1, p.ARRIVAL1_DATE, p.ARRIVAL2_DATE)                 AS ARRIVAL_DATE,
  p.INCOTERM, p.IS_BAD, p.SUP_REGION, p.PLANT_REGION, p.LIST_PRICE,
  s.COUNTRY_CODE                                                       AS ORIGIN_COUNTRY_CODE,
  pl.COUNTRY_CODE                                                      AS DEST_COUNTRY_CODE,
  s.COUNTRY_CODE <> pl.COUNTRY_CODE                                    AS IS_IMPORT,
  COALESCE(pt.CATEGORY, 'Mechanical')                                  AS CATEGORY,
  ROUND(a.QTY_SHIPPED * COALESCE(pt.UNIT_WEIGHT_KG, 1), 1)             AS ACTUAL_WT
FROM SC.RAW_SUPPLIER.ASNS a
JOIN SC.OPS.GEN_INBOUND_PLAN p  ON p.PO_ID = a.PO_ID AND p.PO_LINE_NO = a.PO_LINE_NO
JOIN SC.RAW_SUPPLIER.SUPPLIERS s ON s.SUPPLIER_ID = a.SUPPLIER_ID
JOIN SC.RAW_ERP.PLANTS pl        ON pl.PLANT_ID = a.SHIP_TO_PLANT_ID
LEFT JOIN SC.RAW_ERP.PARTS pt    ON pt.PART_ID = p.PART_ID;

-- -----------------------------------------------------------------------------
-- INBOUND_FREIGHT_INVOICES
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE _LOADS AS
WITH l AS (
  SELECT SUPPLIER_ID, SHIP_TO_PLANT_ID, SHIP_DATE,
         ANY_VALUE(SUP_REGION = PLANT_REGION) AS IS_NEAR,
         ANY_VALUE(PLANT_REGION)              AS PLANT_REGION,
         BOOLOR_AGG(IS_BAD)                   AS IS_BAD,
         MAX(ARRIVAL_DATE)                    AS ARRIVAL_DATE
  FROM _INB
  WHERE INCOTERM IN ('EXW', 'FCA', 'FOB') AND ARRIVAL_DATE < $AS_OF
  GROUP BY 1, 2, 3
)
SELECT l.*,
       'LD' || LPAD(ROW_NUMBER() OVER (ORDER BY SHIP_DATE, SUPPLIER_ID, SHIP_TO_PLANT_ID), 7, '0') AS LOAD_ID,
       UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(1501))    AS R_MISS,
       UNIFORM(3, 30, RANDOM(1502))                 AS INV_LAG,
       UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(1503))    AS R_RATE,
       UNIFORM(0.08::FLOAT, 0.15::FLOAT, RANDOM(1504)) AS FUEL_PCT,
       UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(1505))    AS R_ACC,
       UNIFORM(50, 600, RANDOM(1506))               AS ACC_AMT,
       UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(1507))    AS R_ACC_T,
       UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(1508))    AS R_NOWT,
       UNIFORM(1, 3, RANDOM(1509))                  AS CARRIER_K
FROM l;

CREATE OR REPLACE TABLE INBOUND_FREIGHT_INVOICES AS
WITH ln AS (
  SELECT i.*, ld.LOAD_ID, ld.IS_NEAR, ld.PLANT_REGION AS LOAD_REGION, ld.IS_BAD AS LOAD_BAD,
         ld.ARRIVAL_DATE AS LOAD_ARRIVAL, ld.R_MISS, ld.INV_LAG, ld.R_RATE, ld.FUEL_PCT,
         ld.R_ACC, ld.ACC_AMT, ld.R_ACC_T, ld.R_NOWT, ld.CARRIER_K,
         ROUND(i.ACTUAL_WT * UNIFORM(0.6::FLOAT, 1.6::FLOAT, RANDOM(1511)), 1) AS DIM_WT
  FROM _INB i
  JOIN _LOADS ld ON ld.SUPPLIER_ID = i.SUPPLIER_ID AND ld.SHIP_TO_PLANT_ID = i.SHIP_TO_PLANT_ID AND ld.SHIP_DATE = i.SHIP_DATE
  WHERE i.INCOTERM IN ('EXW', 'FCA', 'FOB')
),
tot AS (
  SELECT ln.*,
         SUM(GREATEST(ACTUAL_WT, DIM_WT)) OVER (PARTITION BY LOAD_ID)      AS LOAD_CHG_WT,
         ROW_NUMBER() OVER (PARTITION BY LOAD_ID ORDER BY ASN_ID)          AS LINE_NO
  FROM ln
),
cr AS (
  SELECT SCAC, REGION, ROW_NUMBER() OVER (PARTITION BY REGION ORDER BY CARRIER_ID) AS K
  FROM SC.RAW_LOGISTICS.CARRIERS WHERE MODE <> 'PARCEL'
),
amt AS (
  SELECT tot.*, cr.SCAC,
         ROUND(IFF(IS_NEAR, 150 + LOAD_CHG_WT * (0.10 + R_RATE * 0.06),
                            600 + LOAD_CHG_WT * (0.35 + R_RATE * 0.20)), 2)  AS LINEHAUL
  FROM tot JOIN cr ON cr.REGION = tot.LOAD_REGION AND cr.K = tot.CARRIER_K
)
SELECT
  'FI' || LPAD(DENSE_RANK() OVER (ORDER BY LOAD_ID), 7, '0')               AS FREIGHT_INVOICE_ID,
  LINE_NO                                                                 AS INVOICE_LINE_NO,
  LOAD_ID, SCAC, ASN_ID, PO_ID, PO_LINE_NO, SUPPLIER_ID, SHIP_TO_PLANT_ID,
  DATEADD(day, INV_LAG, LOAD_ARRIVAL)::DATE                               AS INVOICE_DATE,
  IFF(R_NOWT < 0.02, NULL, ACTUAL_WT)::NUMBER(12,1)                       AS ACTUAL_WEIGHT_KG,
  IFF(R_NOWT < 0.02, NULL, DIM_WT)::NUMBER(12,1)                          AS DIM_WEIGHT_KG,
  LINEHAUL::NUMBER(12,2)                                                  AS LOAD_LINEHAUL_AMOUNT,
  ROUND(LINEHAUL * FUEL_PCT, 2)::NUMBER(12,2)                             AS LOAD_FUEL_AMOUNT,
  IFF(R_ACC < IFF(LOAD_BAD, 0.30, 0.10), ACC_AMT, 0)::NUMBER(12,2)        AS LOAD_ACCESSORIAL_AMOUNT,
  CASE WHEN R_ACC >= IFF(LOAD_BAD, 0.30, 0.10) THEN NULL
       WHEN LOAD_BAD OR R_ACC_T < 0.4         THEN 'DEMURRAGE'
       WHEN R_ACC_T < 0.8                     THEN 'DETENTION'
       ELSE 'LIFTGATE' END                                                AS ACCESSORIAL_TYPE,
  'USD'                                                                   AS CURRENCY
FROM amt
WHERE DATEADD(day, INV_LAG, LOAD_ARRIVAL) < $AS_OF AND R_MISS >= 0.04
ORDER BY FREIGHT_INVOICE_ID, INVOICE_LINE_NO;

-- -----------------------------------------------------------------------------
-- CUSTOMS_ENTRIES (cross-border, non-DDP)
--   CUSTOMS_VALUE: goods value, + 5% freight / insurance uplift unless CIF (already in)
--   DUTY_RATE by category; ~25% of entries duty-free under a trade agreement
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE CUSTOMS_ENTRIES AS
WITH e AS (
  SELECT i.*,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(1601))  AS R_MISS,
         UNIFORM(0, 10, RANDOM(1602))               AS FILE_LAG,
         UNIFORM(0, 2, RANDOM(1603))                AS ENTRY_OFF,
         UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(1604))  AS R_FTA,
         UNIFORM(0.8::FLOAT, 1.2::FLOAT, RANDOM(1605)) AS RATE_F
  FROM _INB i
  WHERE i.IS_IMPORT AND i.INCOTERM <> 'DDP'
),
v AS (
  SELECT e.*,
    DATEADD(day, -ENTRY_OFF, ARRIVAL_DATE)::DATE                               AS ENTRY_DATE,
    ROUND(QTY_SHIPPED * LIST_PRICE * IFF(INCOTERM = 'CIF', 1, 1.05), 2)        AS CUSTOMS_VALUE,
    IFF(R_FTA < 0.25, 0,
        ROUND(RATE_F * CASE CATEGORY WHEN 'Electronics' THEN 0.03 WHEN 'Mechanical' THEN 0.05
                                     WHEN 'Electrical'  THEN 0.04 WHEN 'Hydraulics' THEN 0.06
                                     WHEN 'Packaging'   THEN 0.08 ELSE 0.065 END, 4)) AS DUTY_RATE
  FROM e
)
SELECT
  'CE' || LPAD(ROW_NUMBER() OVER (ORDER BY ASN_ID), 8, '0')                   AS ENTRY_ID,
  ASN_ID, PO_ID, PO_LINE_NO, SUPPLIER_ID, SHIP_TO_PLANT_ID,
  ORIGIN_COUNTRY_CODE, DEST_COUNTRY_CODE AS DESTINATION_COUNTRY_CODE, INCOTERM,
  ENTRY_DATE,
  CUSTOMS_VALUE::NUMBER(14,2)                                                 AS CUSTOMS_VALUE,
  DUTY_RATE::NUMBER(6,4)                                                      AS DUTY_RATE,
  ROUND(CUSTOMS_VALUE * DUTY_RATE, 2)::NUMBER(14,2)                           AS DUTY_AMOUNT,
  ROUND((CUSTOMS_VALUE + CUSTOMS_VALUE * DUTY_RATE)
        * CASE PLANT_REGION WHEN 'EMEA' THEN 0.20 WHEN 'APAC' THEN 0.10 ELSE 0 END, 2)::NUMBER(14,2) AS IMPORT_VAT_AMOUNT,
  TRUE                                                                        AS IS_VAT_RECOVERABLE,
  'USD'                                                                       AS CURRENCY
FROM v
WHERE ARRIVAL_DATE < $AS_OF
  AND DATEADD(day, FILE_LAG, ENTRY_DATE) < $AS_OF
  AND R_MISS >= 0.05
ORDER BY ENTRY_ID;

-- -----------------------------------------------------------------------------
-- Row counts
-- -----------------------------------------------------------------------------
SELECT 'INBOUND_FREIGHT_INVOICES (lines)' AS TABLE_NAME, COUNT(*) AS ROW_COUNT FROM INBOUND_FREIGHT_INVOICES
UNION ALL SELECT 'INBOUND_FREIGHT_INVOICES (invoices)', COUNT(DISTINCT FREIGHT_INVOICE_ID) FROM INBOUND_FREIGHT_INVOICES
UNION ALL SELECT 'CUSTOMS_ENTRIES', COUNT(*) FROM CUSTOMS_ENTRIES;
