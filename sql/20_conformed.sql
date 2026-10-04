-- =============================================================================
-- 20_conformed.sql
-- SC.CONFORMED: ontology entities (docs/ontology.md) as dynamic tables, with the
-- milestone attributes of docs/metric_contracts.md §1.1 (v1.1).
-- Depends on: sql/00_setup.sql, sql/01a..01f (RAW_*).
-- Idempotent: CREATE OR REPLACE throughout.
--
-- Boundary (AGENTS.md hard rule 1): this layer resolves keys, crosswalks, dedup,
-- UTC / plant- or customer-local dates, base UoM and DQ flags, and computes the
-- §1.1 milestones. It does NOT apply on-time windows, in-full tests, population
-- filters, ratios or weighting. Those live only in SC.SEMANTIC.SV_SUPPLY_CHAIN.
--
-- Lag: DT_* = DOWNSTREAM; DIM_* / FACT_* = '1 hour' on SC_WH. DIM_DATE is a
-- generated view so its relative-period offsets track CURRENT_DATE().
--
-- Objects
--   DIM_DATE (view)             DIM_PLANT     DIM_WAREHOUSE   DIM_CARRIER
--   DIM_CUSTOMER                DIM_PART      DIM_SUPPLIER    DIM_SUPPLIER_PART
--   DT_SUPPLIER_PART_XWALK      DT_SHIPMENT_ARRIVAL           DT_ORDER_LINE_MILESTONES
--   DT_INBOUND_ARRIVAL          DT_PO_LINE_MILESTONES         DT_INBOUND_FREIGHT_ALLOC
--   DT_INVENTORY_DEMAND_WINDOW
--   DT_CONTRACT_TERMS (AI_EXTRACT)  DIM_CONTRACT  DT_CONTRACT_CHUNK (Cortex Search source)
--   FACT_SHIPMENT  FACT_ORDER_LINE  FACT_PO_LINE  FACT_GOODS_RECEIPT  FACT_INVENTORY_SNAPSHOT
--
-- Source-to-ontology key mapping
--   PLANT_CODE = RAW_ERP.PLANTS.PLANT_ID        CUSTOMER_NO = CUSTOMERS.CUSTOMER_ID
--   PART_NO    = RAW_ERP.PARTS.PART_ID          SO_NO       = SALES_ORDERS.SO_ID
--   SUPPLIER_NO = RAW_SUPPLIER.SUPPLIERS.ERP_VENDOR_NO (portal SUPPLIER_ID kept as SUPPLIER_PORTAL_ID)
--   SCAC       = RAW_LOGISTICS.CARRIERS.SCAC     PO_NO       = PURCHASE_ORDERS.PO_ID
--
-- Assumptions (see the change summary; revisit with owners)
--   * Reporting currency is USD (all RAW amounts are USD). Non-USD -> NULL + NO_FX_RATE.
--   * Fiscal calendar: 4-4-5 on ISO years / ISO weeks (week 53 joins period 12).
--   * Inbound arrival (since 2026-10-03, sql/01f): IoT geofence entry, then carrier
--     POD, then the GR posting date (GR_FALLBACK), per ASN in DT_INBOUND_ARRIVAL. The
--     GR dock arrival date is carried as GR_DOCK_ARRIVAL_DATE but is not a contract source.
-- =============================================================================

USE ROLE SC_ADMIN;
USE WAREHOUSE SC_WH;
USE SCHEMA SC.CONFORMED;
ALTER SESSION SET TIMEZONE = 'UTC';

-- -----------------------------------------------------------------------------
-- DIM_DATE (generated view; Time hierarchy, ontology.md §4)
--   A view, not a table, so the relative-period offsets (0 = current period,
--   -1 = previous) are always computed against the session's CURRENT_DATE(), the
--   same as-of date the semantic view uses for due lines. A stored table would go
--   stale at midnight; dynamic tables only allow CURRENT_DATE() in filters.
--   ROW_NUMBER (not SEQ4, which may leave gaps) keeps every day present.
-- -----------------------------------------------------------------------------
EXECUTE IMMEDIATE $$
BEGIN
  -- DIM_DATE was a plain table up to 2026-10-03; replace it with the view once
  IF (EXISTS (SELECT 1 FROM SC.INFORMATION_SCHEMA.TABLES
              WHERE TABLE_SCHEMA = 'CONFORMED' AND TABLE_NAME = 'DIM_DATE' AND TABLE_TYPE = 'BASE TABLE')) THEN
    DROP TABLE SC.CONFORMED.DIM_DATE;
  END IF;
  RETURN 'ok';
END;
$$;

CREATE OR REPLACE VIEW SC.CONFORMED.DIM_DATE (
  DATE                    COMMENT 'Calendar day (leaf of the Time hierarchy). Role-played as order, commit, arrival, GR posting and snapshot date.',
  YEAR                    COMMENT 'Calendar year.',
  QUARTER                 COMMENT 'Calendar quarter 1-4.',
  MONTH                   COMMENT 'Calendar month 1-12.',
  MONTH_NAME              COMMENT 'Calendar month abbreviation (Jan..Dec).',
  DAY_OF_WEEK_ISO         COMMENT 'ISO day of week, 1 = Monday .. 7 = Sunday.',
  IS_WEEKEND              COMMENT 'TRUE on Saturday and Sunday.',
  WEEK_START_DATE         COMMENT 'Monday of the ISO week containing DATE.',
  FISCAL_YEAR             COMMENT 'Fiscal year = ISO week-numbering year (fiscal year starts on the Monday of ISO week 1).',
  FISCAL_WEEK             COMMENT 'Fiscal week 1-53 = ISO week of year.',
  FISCAL_QUARTER          COMMENT 'Fiscal quarter 1-4 = 13 fiscal weeks each; week 53 belongs to Q4.',
  FISCAL_PERIOD           COMMENT 'Fiscal period 1-12 on a 4-4-5 pattern per quarter; week 53 belongs to period 12.',
  FISCAL_PERIOD_LABEL     COMMENT 'Display label, e.g. FY2026-P03.',
  FISCAL_QUARTER_LABEL    COMMENT 'Display label, e.g. FY2026-Q3.',
  FISCAL_PERIOD_START_DATE COMMENT 'First day (Monday) of the fiscal period containing DATE.',
  FISCAL_PERIOD_END_DATE  COMMENT 'Last day (Sunday) of the fiscal period containing DATE.',
  FISCAL_QUARTER_START_DATE COMMENT 'First day (Monday) of the fiscal quarter containing DATE.',
  FISCAL_QUARTER_END_DATE COMMENT 'Last day (Sunday) of the fiscal quarter containing DATE.',
  FISCAL_WEEK_OFFSET      COMMENT 'Fiscal weeks between DATE and CURRENT_DATE(): 0 = current week, -1 = previous week, 1 = next week.',
  FISCAL_MONTH_OFFSET     COMMENT 'Fiscal periods (4-4-5 months) between DATE and CURRENT_DATE(): 0 = current fiscal month, -1 = previous ("last month").',
  FISCAL_QUARTER_OFFSET   COMMENT 'Fiscal quarters between DATE and CURRENT_DATE(): 0 = current fiscal quarter, -1 = previous ("last quarter").',
  FISCAL_YEAR_OFFSET      COMMENT 'Fiscal years between DATE and CURRENT_DATE(): 0 = current fiscal year, -1 = previous ("last year").',
  FISCAL_WEEK_LABEL       COMMENT 'Fiscal week display label, e.g. FY2026-W39 (contract v1.3 §7.1).',
  FISCAL_WEEK_END_DATE    COMMENT 'Last day (Sunday) of the fiscal week containing DATE; first day is WEEK_START_DATE.',
  FISCAL_YEAR_LABEL       COMMENT 'Fiscal year display label, e.g. FY2026.',
  FISCAL_YEAR_START_DATE  COMMENT 'First day (Monday of ISO week 1) of the fiscal year containing DATE.',
  FISCAL_YEAR_END_DATE    COMMENT 'Last day (Sunday) of the fiscal year containing DATE.',
  CALENDAR_MONTH_LABEL    COMMENT 'Calendar month display label, e.g. Sep 2026. Used only when the user names a calendar month (contract v1.3 §7.1).',
  CALENDAR_MONTH_START_DATE COMMENT 'First day of the calendar month containing DATE.',
  CALENDAR_MONTH_END_DATE COMMENT 'Last day of the calendar month containing DATE.',
  CALENDAR_MONTH_OFFSET   COMMENT 'Calendar months between DATE and CURRENT_DATE(): 0 = current calendar month, -1 = last complete calendar month (period rule of Supplier Contractual OTD %, contract v1.4).'
) COMMENT = 'Conformed calendar (generated view): one row per day 2024-01-01..2028-12-31 with calendar and 4-4-5 fiscal attributes, period labels with first / last days, plus relative-period offsets against the session CURRENT_DATE(). Period boundaries for every metric come from here (metric_contracts.md §1.2, §7.1).'
AS
WITH d AS (
  SELECT DATEADD(day, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2024-01-01'::DATE) AS DT
  FROM TABLE(GENERATOR(ROWCOUNT => 1827))
),
f AS (
  SELECT DT, YEAROFWEEKISO(DT) AS FY, WEEKISO(DT) AS FW, LEAST(4, CEIL(WEEKISO(DT) / 13)) AS FQ,
         DATEADD(day, 1 - DAYOFWEEKISO(DT), DT) AS WK
  FROM d
),
p AS (
  SELECT f.*,
         3 * (FQ - 1) + CASE WHEN FW - 13 * (FQ - 1) <= 4 THEN 1 WHEN FW - 13 * (FQ - 1) <= 8 THEN 2 ELSE 3 END AS FP
  FROM f
),
b AS (
  SELECT p.*,
         MIN(DT) OVER (PARTITION BY FY, FP) AS FP_START, MAX(DT) OVER (PARTITION BY FY, FP) AS FP_END,
         MIN(DT) OVER (PARTITION BY FY, FQ) AS FQ_START, MAX(DT) OVER (PARTITION BY FY, FQ) AS FQ_END,
         MIN(DT) OVER (PARTITION BY FY) AS FY_START, MAX(DT) OVER (PARTITION BY FY) AS FY_END
  FROM p
),
t AS (SELECT FY, FQ, FP, WK FROM p WHERE DT = CURRENT_DATE())
SELECT
  b.DT, YEAR(b.DT), QUARTER(b.DT), MONTH(b.DT), MONTHNAME(b.DT), DAYOFWEEKISO(b.DT), DAYOFWEEKISO(b.DT) >= 6,
  b.WK, b.FY, b.FW, b.FQ, b.FP,
  'FY' || b.FY || '-P' || LPAD(b.FP, 2, '0'),
  'FY' || b.FY || '-Q' || b.FQ,
  b.FP_START, b.FP_END, b.FQ_START, b.FQ_END,
  (DATEDIFF(day, t.WK, b.WK) / 7)::INTEGER,
  ((b.FY * 12 + b.FP) - (t.FY * 12 + t.FP))::INTEGER,
  ((b.FY * 4 + b.FQ) - (t.FY * 4 + t.FQ))::INTEGER,
  (b.FY - t.FY)::INTEGER,
  'FY' || b.FY || '-W' || LPAD(b.FW, 2, '0'),
  DATEADD(day, 6, b.WK),
  'FY' || b.FY,
  b.FY_START, b.FY_END,
  MONTHNAME(b.DT) || ' ' || YEAR(b.DT),
  DATE_TRUNC(month, b.DT),
  LAST_DAY(b.DT),
  DATEDIFF(month, DATE_TRUNC(month, CURRENT_DATE()), DATE_TRUNC(month, b.DT))::INTEGER
FROM b
LEFT JOIN t ON TRUE;

-- -----------------------------------------------------------------------------
-- DIM_PLANT (Geography hierarchy: Region > Country > Plant)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SC.CONFORMED.DIM_PLANT (
  PLANT_CODE    COMMENT 'Natural key: ERP plant code. A physical company site that makes, receives or ships goods.',
  PLANT_NAME    COMMENT 'Plant name from the ERP plant master.',
  CITY          COMMENT 'City where the plant is located.',
  COUNTRY_CODE  COMMENT 'ISO 3166-1 alpha-2 country of the plant (Geography level 2).',
  REGION        COMMENT 'Company region AMER/EMEA/APAC as mapped in ERP (Geography level 1; source uses NA for the Americas).',
  TIMEZONE      COMMENT 'IANA time zone of the plant. Receiving-location zone for inbound dates and fallback zone for outbound (TZ_FALLBACK).',
  PLANT_TYPE    COMMENT 'MANUFACTURING or DISTRIBUTION.'
)
  TARGET_LAG = '1 hour' WAREHOUSE = SC_WH REFRESH_MODE = AUTO
  COMMENT = 'Plant: physical company site; leaf of the Geography hierarchy. One row per PLANT_CODE. SoR: ERP.'
AS
SELECT PLANT_ID, PLANT_NAME, CITY, COUNTRY_CODE, REGION, TIMEZONE, PLANT_TYPE
FROM SC.RAW_ERP.PLANTS;

-- -----------------------------------------------------------------------------
-- DIM_WAREHOUSE (only source of storage-area identifiers today: IoT sensor zones)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SC.CONFORMED.DIM_WAREHOUSE (
  WAREHOUSE_CODE  COMMENT 'Natural key: storage area within a plant (<PLANT_CODE>-<ZONE>). Taken from IoT sensor zones; RAW ERP has no storage-location master yet.',
  PLANT_CODE      COMMENT 'Plant the warehouse belongs to (R14).',
  WAREHOUSE_TYPE  COMMENT 'Storage condition of the area: AMBIENT, COLD or FROZEN.',
  SETPOINT_C      COMMENT 'Target temperature of the area in degrees Celsius.',
  MAX_ALLOWED_C   COMMENT 'Upper temperature limit in degrees Celsius; readings above it are excursions.'
)
  TARGET_LAG = '1 hour' WAREHOUSE = SC_WH REFRESH_MODE = AUTO
  COMMENT = 'Warehouse: storage area within a Plant where inventory is held. One row per WAREHOUSE_CODE. Inventory and shipments are plant-grain in RAW, so they do not reference this table yet.'
AS
SELECT WAREHOUSE_ZONE_ID, PLANT_ID, WAREHOUSE_ZONE, MAX(SETPOINT_C), MAX(MAX_ALLOWED_C)
FROM SC.RAW_IOT.SENSOR_READINGS
GROUP BY WAREHOUSE_ZONE_ID, PLANT_ID, WAREHOUSE_ZONE;

-- -----------------------------------------------------------------------------
-- DIM_CARRIER
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SC.CONFORMED.DIM_CARRIER (
  SCAC                COMMENT 'Natural key: Standard Carrier Alpha Code. A company that physically moves goods for us.',
  CARRIER_NAME        COMMENT 'Carrier legal / trading name.',
  MODE                COMMENT 'Transport mode offered: FTL, LTL or PARCEL.',
  REGION              COMMENT 'Region the carrier serves.',
  SOURCE_CARRIER_ID   COMMENT 'TMS carrier identifier in RAW_LOGISTICS (lineage only; join on SCAC).'
)
  TARGET_LAG = '1 hour' WAREHOUSE = SC_WH REFRESH_MODE = AUTO
  COMMENT = 'Carrier: company that physically moves goods. One row per SCAC. SoR: Logistics (TMS).'
AS
SELECT SCAC, CARRIER_NAME, MODE, REGION, CARRIER_ID
FROM SC.RAW_LOGISTICS.CARRIERS;

-- -----------------------------------------------------------------------------
-- DIM_CUSTOMER (Customer hierarchy: Segment > Customer)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SC.CONFORMED.DIM_CUSTOMER (
  CUSTOMER_NO       COMMENT 'Natural key: ERP sold-to number. A legal entity that buys from us.',
  CUSTOMER_NAME     COMMENT 'Customer name.',
  SEGMENT           COMMENT 'Customer segment (Customer hierarchy level 1): Strategic, Key Account, Distributor, SMB, Intercompany.',
  COUNTRY_CODE      COMMENT 'ISO 3166-1 alpha-2 country of the ship-to.',
  REGION            COMMENT 'Company region of the ship-to.',
  SHIP_TO_CITY      COMMENT 'Ship-to city.',
  SHIP_TO_TIMEZONE  COMMENT 'IANA time zone of the customer ship-to. Outbound arrival timestamps are converted to this zone before a date is taken.',
  IS_INTERCOMPANY   COMMENT 'TRUE when the sold-to is a company entity (intercompany sale). Used by the semantic view to exclude intercompany lines.'
)
  TARGET_LAG = '1 hour' WAREHOUSE = SC_WH REFRESH_MODE = AUTO
  COMMENT = 'Customer: sold-to party; leaf of the Customer hierarchy. One row per CUSTOMER_NO (current segment; no segment history in RAW yet). SoR: ERP.'
AS
SELECT CUSTOMER_ID, CUSTOMER_NAME, SEGMENT, COUNTRY_CODE, REGION, SHIP_TO_CITY, SHIP_TO_TIMEZONE, IS_INTERCOMPANY
FROM SC.RAW_ERP.CUSTOMERS;

-- -----------------------------------------------------------------------------
-- DIM_PART (Part hierarchy: Category > Family > SKU)
--   Plus one unknown member '#UNMAPPED' (category / family 'UNMAPPED PART') so facts
--   whose supplier part number maps to no ERP part (UNMAPPED_PART, PART_NO NULL) roll
--   up under a visible label instead of a blank. Facts keep PART_NO NULL; the
--   semantic view joins them with COALESCE(PART_NO, '#UNMAPPED').
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SC.CONFORMED.DIM_PART (
  PART_NO             COMMENT 'Natural key: ERP material number. A distinct item we buy, make, stock or sell (SKU, leaf of the Part hierarchy). #UNMAPPED = unknown member for supplier part numbers that map to no ERP part.',
  DESCRIPTION         COMMENT 'Material description.',
  CATEGORY            COMMENT 'Part hierarchy level 1 (material group category); UNMAPPED PART for the unknown member.',
  FAMILY              COMMENT 'Part hierarchy level 2 (product family); UNMAPPED PART for the unknown member.',
  BASE_UOM            COMMENT 'Base unit of measure; every *_QTY column in CONFORMED is in this unit.',
  STANDARD_COST_AMT   COMMENT 'ERP standard cost per base UoM in reporting currency (USD). Weight for DOI roll-ups above Part level.',
  UNIT_WEIGHT_KG      COMMENT 'Actual weight of one base unit in kg.',
  IS_STOCKED          COMMENT 'TRUE for stocked parts; FALSE for non-stock / expense parts (excluded from DOI, Supplier OTD and Landed Cost by the semantic view). NULL (unknown) for #UNMAPPED.',
  IS_TEMP_CONTROLLED  COMMENT 'TRUE when the part must be stored and moved under temperature control.'
)
  TARGET_LAG = '1 hour' WAREHOUSE = SC_WH REFRESH_MODE = AUTO
  COMMENT = 'Part: item we buy, make, stock or sell, in its base UoM. One row per PART_NO, plus the unknown member #UNMAPPED. SoR: ERP material master.'
AS
SELECT PART_ID, DESCRIPTION, CATEGORY, FAMILY, BASE_UOM,
       IFF(COST_CURRENCY = 'USD', STANDARD_COST, NULL),
       UNIT_WEIGHT_KG, IS_STOCKED, IS_TEMP_CONTROLLED
FROM SC.RAW_ERP.PARTS
UNION ALL
SELECT '#UNMAPPED', 'Supplier part number not mapped to an ERP part (UNMAPPED_PART)', 'UNMAPPED PART', 'UNMAPPED PART',
       NULL::VARCHAR, NULL::NUMBER(12,2), NULL::NUMBER(10,3), NULL::BOOLEAN, NULL::BOOLEAN;

-- -----------------------------------------------------------------------------
-- DIM_SUPPLIER (SUPPLIER_NO = ERP vendor number; portal id kept for lineage)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SC.CONFORMED.DIM_SUPPLIER (
  SUPPLIER_NO         COMMENT 'Natural key: ERP vendor number. A legal entity we buy parts or materials from.',
  SUPPLIER_PORTAL_ID  COMMENT 'Supplier-portal identifier (RAW_SUPPLIER.SUPPLIER_ID), resolved to SUPPLIER_NO here.',
  SUPPLIER_CODE       COMMENT 'Short supplier code used as prefix of supplier part numbers.',
  SUPPLIER_NAME       COMMENT 'Supplier legal name.',
  COUNTRY_CODE        COMMENT 'ISO 3166-1 alpha-2 country of the supplier.',
  REGION              COMMENT 'Company region of the supplier.',
  PAYMENT_TERMS       COMMENT 'Agreed payment terms (NET30 / NET45 / NET60).',
  ONBOARDED_DATE      COMMENT 'Date the supplier was approved.'
)
  TARGET_LAG = '1 hour' WAREHOUSE = SC_WH REFRESH_MODE = AUTO
  COMMENT = 'Supplier: legal entity we buy from. One row per SUPPLIER_NO (ERP vendor number), with the portal id resolved.'
AS
SELECT ERP_VENDOR_NO, SUPPLIER_ID, SUPPLIER_CODE, SUPPLIER_NAME, COUNTRY_CODE, REGION, PAYMENT_TERMS, ONBOARDED_DATE
FROM SC.RAW_SUPPLIER.SUPPLIERS;

-- -----------------------------------------------------------------------------
-- DT_CONTRACT_TERMS: contract terms extracted with AI_EXTRACT from the parsed
--   signed PDFs (RAW_DOCS.CONTRACT_PAGES, sql/01g). The PDF is the legal source
--   (ontology.md §1). Only type / unit normalization here: percentages become
--   0-1 fractions (metric_contracts.md §1.3 storage rule), VALID_TO = effective
--   date + term - 1 day. Contract targets are term attributes, not metric values.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SC.CONFORMED.DT_CONTRACT_TERMS (
  DOC_FILE_PATH                 COMMENT 'Path of the signed contract PDF on @SC.RAW_DOCS.CONTRACTS.',
  DOC_FILE_MD5                  COMMENT 'MD5 of the PDF version the terms were extracted from.',
  DOC_PAGE_COUNT                COMMENT 'Pages in the PDF.',
  CONTRACT_NO                   COMMENT 'Contract number as printed on the PDF (e.g. CTR-S0011-2026).',
  DOC_SUPPLIER_PORTAL_ID        COMMENT 'Supplier identifier printed on the PDF (supplier-portal id, e.g. S0011); resolved to SUPPLIER_NO in DIM_CONTRACT.',
  DOC_SUPPLIER_NAME             COMMENT 'Supplier name printed on the PDF.',
  VALID_FROM                    COMMENT 'Contract effective date.',
  TERM_MONTHS                   COMMENT 'Contract term in months.',
  VALID_TO                      COMMENT 'Last day the contract is valid = VALID_FROM + TERM_MONTHS - 1 day.',
  DELIVERY_TARGET_FRACTION      COMMENT 'Contracted on-time delivery target as a 0-1 fraction (96% = 0.96). Contract term attribute, not a measured metric.',
  DELIVERY_TARGET_BASIS         COMMENT 'How the PDF says the delivery target is measured (e.g. "monthly", share of PO lines).',
  LEAD_TIME_DAYS                COMMENT 'Contracted standard lead time in calendar days.',
  LEAD_TIME_BASIS               COMMENT 'Event the contracted lead time is counted from (e.g. PO acknowledgement).',
  LATE_GRACE_DAYS               COMMENT 'Days after the confirmed date a PO line may arrive before the late-delivery penalty applies.',
  LATE_PENALTY_PER_DAY_FRACTION COMMENT 'Late-delivery credit per day late as a 0-1 fraction of the line value (1.0% = 0.01).',
  LATE_PENALTY_CAP_FRACTION     COMMENT 'Cap of the late-delivery credit as a 0-1 fraction of the line value.',
  PENALTY_CLAUSE_TEXT           COMMENT 'Late-delivery penalty clause as worded in the PDF.',
  INCOTERM                      COMMENT 'Contracted Incoterm (three-letter code).',
  INCOTERM_VERSION              COMMENT 'Incoterms edition referenced (e.g. Incoterms 2020).',
  CURRENCY                      COMMENT 'Contract currency (ISO 4217).',
  PAYMENT_TERMS                 COMMENT 'Contracted payment terms code (e.g. NET60).',
  EXTRACTION_ERROR              COMMENT 'AI_EXTRACT error message; NULL on success.',
  EXTRACTED_JSON                COMMENT 'Raw AI_EXTRACT response (strings as extracted), kept for lineage and review.'
)
  TARGET_LAG = DOWNSTREAM WAREHOUSE = SC_WH REFRESH_MODE = AUTO
  COMMENT = 'Intermediate: contract terms extracted with AI_EXTRACT from the signed contract PDFs. One row per contract PDF.'
AS
WITH doc AS (
  SELECT RELATIVE_PATH, FILE_MD5, MAX(PAGE_COUNT) AS PAGE_COUNT,
         LISTAGG(PAGE_TEXT, '\n\n') WITHIN GROUP (ORDER BY PAGE_INDEX) AS DOC_TEXT
  FROM SC.RAW_DOCS.CONTRACT_PAGES
  WHERE PARSE_ERROR IS NULL
  GROUP BY RELATIVE_PATH, FILE_MD5
),
x AS (
  SELECT doc.*, AI_EXTRACT(text => DOC_TEXT, responseFormat => {
    'contract_no':             'What is the contract number?',
    'supplier_id':             'What is the supplier identifier code in parentheses after the supplier name (format S followed by 4 digits)?',
    'supplier_name':           'What is the supplier company name?',
    'effective_date':          'What is the effective date of the contract, in YYYY-MM-DD format?',
    'term_months':             'What is the contract term in months (number only)?',
    'otd_target_percent':      'What is the contracted on-time delivery target in percent (number only)?',
    'otd_measurement_basis':   'How and how often is the on-time delivery target measured?',
    'lead_time_days':          'What is the standard lead time in calendar days (number only)?',
    'lead_time_basis':         'From which event is the standard lead time counted?',
    'grace_days':              'How many days after the confirmed date may a PO line be delivered before the late-delivery penalty applies (number only)?',
    'penalty_per_day_percent': 'What percent of the line value is credited per day late (number only)?',
    'penalty_cap_percent':     'What is the maximum penalty as a percent of the line value (number only)?',
    'penalty_clause_text':     'Quote verbatim the complete late-delivery penalty clause.',
    'incoterm':                'What is the Incoterm (three-letter code only)?',
    'incoterm_version':        'Which Incoterms edition is referenced (e.g. Incoterms 2020)?',
    'currency':                'What is the contract currency code?',
    'payment_terms':           'What are the payment terms code (e.g. NET30)?'
  }) AS X
  FROM doc
),
v AS (
  SELECT x.*,
         TRY_TO_DATE(TRIM(X:response:effective_date::VARCHAR))                                    AS VF,
         TRY_TO_NUMBER(REGEXP_SUBSTR(X:response:term_months::VARCHAR, '[0-9]+'))                  AS TM
  FROM x
)
SELECT RELATIVE_PATH, FILE_MD5, PAGE_COUNT,
       NULLIF(UPPER(TRIM(X:response:contract_no::VARCHAR)), ''),
       NULLIF(UPPER(TRIM(X:response:supplier_id::VARCHAR)), ''),
       NULLIF(TRIM(X:response:supplier_name::VARCHAR), ''),
       VF,
       TM,
       DATEADD(day, -1, DATEADD(month, TM, VF))::DATE,
       (TRY_TO_NUMBER(REGEXP_SUBSTR(X:response:otd_target_percent::VARCHAR, '[0-9]+(\\.[0-9]+)?'), 9, 4) / 100)::NUMBER(9,6),
       NULLIF(TRIM(X:response:otd_measurement_basis::VARCHAR), ''),
       TRY_TO_NUMBER(REGEXP_SUBSTR(X:response:lead_time_days::VARCHAR, '[0-9]+')),
       NULLIF(TRIM(X:response:lead_time_basis::VARCHAR), ''),
       TRY_TO_NUMBER(REGEXP_SUBSTR(X:response:grace_days::VARCHAR, '[0-9]+')),
       (TRY_TO_NUMBER(REGEXP_SUBSTR(X:response:penalty_per_day_percent::VARCHAR, '[0-9]+(\\.[0-9]+)?'), 9, 4) / 100)::NUMBER(9,6),
       (TRY_TO_NUMBER(REGEXP_SUBSTR(X:response:penalty_cap_percent::VARCHAR, '[0-9]+(\\.[0-9]+)?'), 9, 4) / 100)::NUMBER(9,6),
       NULLIF(TRIM(X:response:penalty_clause_text::VARCHAR), ''),
       NULLIF(UPPER(REGEXP_SUBSTR(X:response:incoterm::VARCHAR, '[A-Za-z]{3}')), ''),
       NULLIF(TRIM(X:response:incoterm_version::VARCHAR), ''),
       NULLIF(UPPER(TRIM(X:response:currency::VARCHAR)), ''),
       NULLIF(UPPER(REPLACE(TRIM(X:response:payment_terms::VARCHAR), ' ', '')), ''),
       X:error::VARCHAR,
       X:response
FROM v;

-- -----------------------------------------------------------------------------
-- DIM_CONTRACT (ontology.md Contract entity, key CONTRACT_NO; R5 -> DIM_SUPPLIER)
--   Values come from the signed PDF (legal source). They are reconciled, never
--   overwritten, against the supplier system (RAW_SUPPLIER has no CONTRACT_TERMS
--   table; the comparable fields are SUPPLIERS.PAYMENT_TERMS / CURRENCY,
--   SUPPLIER_PARTS.LEAD_TIME_DAYS and PURCHASE_ORDERS.INCOTERM). Differences are
--   DQ flags here; per-term detail is in SC.OPS.DQ_CONTRACT_TERMS_RECON.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SC.CONFORMED.DIM_CONTRACT (
  CONTRACT_NO                   COMMENT 'Natural key: contract number on the signed PDF. A supply agreement with one Supplier defining Incoterm, lead time, delivery target and penalties.',
  SUPPLIER_NO                   COMMENT 'Supplier counterparty (ERP vendor number), resolved from the supplier id on the PDF (R5 Contract -> Supplier).',
  SUPPLIER_PORTAL_ID            COMMENT 'Supplier-portal id printed on the PDF (lineage).',
  SUPPLIER_NAME_ON_CONTRACT     COMMENT 'Supplier name as printed on the PDF.',
  VALID_FROM                    COMMENT 'Contract effective date.',
  VALID_TO                      COMMENT 'Last day the contract is valid.',
  TERM_MONTHS                   COMMENT 'Contract term in months.',
  DELIVERY_TARGET_FRACTION      COMMENT 'Contracted on-time delivery target, 0-1 fraction of PO lines (96% = 0.96). A contract term, not a measured metric; it is not Supplier OTD % (different date basis and tolerance).',
  DELIVERY_TARGET_BASIS         COMMENT 'Measurement basis of the delivery target as worded in the PDF (e.g. monthly).',
  LEAD_TIME_DAYS                COMMENT 'Contracted standard lead time in calendar days.',
  LEAD_TIME_BASIS               COMMENT 'Event the contracted lead time is counted from.',
  LATE_GRACE_DAYS               COMMENT 'Days after the confirmed date a PO line may arrive before the late-delivery penalty applies.',
  LATE_PENALTY_PER_DAY_FRACTION COMMENT 'Late-delivery credit per day late, 0-1 fraction of the line value.',
  LATE_PENALTY_CAP_FRACTION     COMMENT 'Cap of the late-delivery credit, 0-1 fraction of the line value.',
  PENALTY_CLAUSE_TEXT           COMMENT 'Late-delivery penalty clause as worded in the PDF.',
  INCOTERM                      COMMENT 'Contracted Incoterm (three-letter code).',
  INCOTERM_VERSION              COMMENT 'Incoterms edition referenced.',
  CURRENCY                      COMMENT 'Contract currency (ISO 4217).',
  PAYMENT_TERMS                 COMMENT 'Contracted payment terms code.',
  DOC_FILE_PATH                 COMMENT 'Path of the signed contract PDF on @SC.RAW_DOCS.CONTRACTS (legal source).',
  DOC_FILE_MD5                  COMMENT 'MD5 of the PDF version the terms come from.',
  DQ_FLAGS                      COMMENT 'Data-quality flags: SUPPLIER_UNRESOLVED, EXTRACTION_INCOMPLETE, SUPPLIER_NAME_MISMATCH, PAYMENT_TERMS_MISMATCH, CURRENCY_MISMATCH (vs supplier master), INCOTERM_MISMATCH_PO_LINES (supplier PO lines on another Incoterm), LEAD_TIME_MISMATCH_SUPPLIER_PARTS (supplier parts quoting another lead time).'
)
  TARGET_LAG = '1 hour' WAREHOUSE = SC_WH REFRESH_MODE = AUTO
  COMMENT = 'Contract: supply agreement with one Supplier, terms from the signed PDF (legal source), reconciled against the supplier system via DQ_FLAGS. One row per CONTRACT_NO.'
AS
WITH po AS (
  SELECT SUPPLIER_ID, ARRAY_UNIQUE_AGG(INCOTERM) AS INCOTERMS FROM SC.RAW_SUPPLIER.PURCHASE_ORDERS GROUP BY SUPPLIER_ID
),
sp AS (
  SELECT SUPPLIER_ID, ARRAY_UNIQUE_AGG(LEAD_TIME_DAYS) AS LEAD_TIMES FROM SC.RAW_SUPPLIER.SUPPLIER_PARTS GROUP BY SUPPLIER_ID
)
SELECT t.CONTRACT_NO, s.ERP_VENDOR_NO, t.DOC_SUPPLIER_PORTAL_ID, t.DOC_SUPPLIER_NAME,
       t.VALID_FROM, t.VALID_TO, t.TERM_MONTHS,
       t.DELIVERY_TARGET_FRACTION, t.DELIVERY_TARGET_BASIS, t.LEAD_TIME_DAYS, t.LEAD_TIME_BASIS,
       t.LATE_GRACE_DAYS, t.LATE_PENALTY_PER_DAY_FRACTION, t.LATE_PENALTY_CAP_FRACTION, t.PENALTY_CLAUSE_TEXT,
       t.INCOTERM, t.INCOTERM_VERSION, t.CURRENCY, t.PAYMENT_TERMS,
       t.DOC_FILE_PATH, t.DOC_FILE_MD5,
       ARRAY_COMPACT(ARRAY_CONSTRUCT(
         IFF(s.SUPPLIER_ID IS NULL, 'SUPPLIER_UNRESOLVED', NULL),
         IFF(t.EXTRACTION_ERROR IS NOT NULL OR t.CONTRACT_NO IS NULL OR t.VALID_FROM IS NULL OR t.VALID_TO IS NULL
             OR t.DELIVERY_TARGET_FRACTION IS NULL OR t.LEAD_TIME_DAYS IS NULL OR t.LATE_GRACE_DAYS IS NULL
             OR t.LATE_PENALTY_PER_DAY_FRACTION IS NULL OR t.LATE_PENALTY_CAP_FRACTION IS NULL OR t.PENALTY_CLAUSE_TEXT IS NULL
             OR t.INCOTERM IS NULL OR t.CURRENCY IS NULL OR t.PAYMENT_TERMS IS NULL, 'EXTRACTION_INCOMPLETE', NULL),
         IFF(s.SUPPLIER_ID IS NOT NULL AND UPPER(s.SUPPLIER_NAME) IS DISTINCT FROM UPPER(t.DOC_SUPPLIER_NAME), 'SUPPLIER_NAME_MISMATCH', NULL),
         IFF(s.SUPPLIER_ID IS NOT NULL AND s.PAYMENT_TERMS IS DISTINCT FROM t.PAYMENT_TERMS, 'PAYMENT_TERMS_MISMATCH', NULL),
         IFF(s.SUPPLIER_ID IS NOT NULL AND s.CURRENCY IS DISTINCT FROM t.CURRENCY, 'CURRENCY_MISMATCH', NULL),
         IFF(ARRAY_SIZE(ARRAY_REMOVE(COALESCE(po.INCOTERMS, ARRAY_CONSTRUCT()), t.INCOTERM::VARIANT)) > 0, 'INCOTERM_MISMATCH_PO_LINES', NULL),
         IFF(ARRAY_SIZE(ARRAY_REMOVE(COALESCE(sp.LEAD_TIMES, ARRAY_CONSTRUCT()), t.LEAD_TIME_DAYS::VARIANT)) > 0, 'LEAD_TIME_MISMATCH_SUPPLIER_PARTS', NULL)))
FROM SC.CONFORMED.DT_CONTRACT_TERMS t
LEFT JOIN SC.RAW_SUPPLIER.SUPPLIERS s ON s.SUPPLIER_ID = t.DOC_SUPPLIER_PORTAL_ID
LEFT JOIN po ON po.SUPPLIER_ID = s.SUPPLIER_ID
LEFT JOIN sp ON sp.SUPPLIER_ID = s.SUPPLIER_ID;

-- -----------------------------------------------------------------------------
-- DT_CONTRACT_CHUNK: parsed contract text split by Markdown section (one chunk
--   per heading), each carrying its file, page, contract and supplier keys.
--   Source of the Cortex Search service SC.AGENTS.CSS_CONTRACTS (sql/40). Explicit
--   lag (not DOWNSTREAM) because its consumer is a search service, not a DT, and
--   REFRESH_MODE = INCREMENTAL because Cortex Search needs change tracking (not
--   available on FULL-refresh DTs). Keys therefore come from the incremental
--   DT_CONTRACT_TERMS with the same supplier-id resolution as DIM_CONTRACT
--   (DIM_CONTRACT itself is FULL); the tests assert both agree.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SC.CONFORMED.DT_CONTRACT_CHUNK (
  CHUNK_ID        COMMENT 'Chunk key: <DOC_FILE_PATH>#p<PAGE_INDEX>#c<CHUNK_SEQ>.',
  DOC_FILE_PATH   COMMENT 'Path of the signed contract PDF on @SC.RAW_DOCS.CONTRACTS.',
  FILE_NAME       COMMENT 'File name of the PDF.',
  PAGE_INDEX      COMMENT 'Page of the PDF the chunk comes from, 0-based.',
  CHUNK_SEQ       COMMENT 'Position of the chunk within the page, 0-based.',
  CONTRACT_NO     COMMENT 'Contract the chunk belongs to (same key as DIM_CONTRACT).',
  SUPPLIER_NO     COMMENT 'Supplier counterparty of the contract (ERP vendor number).',
  SUPPLIER_NAME   COMMENT 'Supplier name as printed on the contract.',
  SECTION_TITLE   COMMENT 'Markdown section heading of the chunk (e.g. 2. Late-Delivery Penalty); NULL for the preamble.',
  CHUNK_TEXT      COMMENT 'Searchable text: document title, contract number and section heading, then the section text.'
)
  TARGET_LAG = '1 hour' WAREHOUSE = SC_WH REFRESH_MODE = INCREMENTAL
  COMMENT = 'Intermediate: contract PDF text chunked by section for Cortex Search, with file path, contract and supplier keys per chunk. One row per CHUNK_ID.'
AS
SELECT p.RELATIVE_PATH || '#p' || p.PAGE_INDEX || '#c' || ch.INDEX,
       p.RELATIVE_PATH, p.FILE_NAME, p.PAGE_INDEX, ch.INDEX,
       t.CONTRACT_NO, s.ERP_VENDOR_NO, t.DOC_SUPPLIER_NAME,
       ch.VALUE:headers:section::VARCHAR,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(ch.VALUE:headers:doc_title::VARCHAR, 'Contract ' || t.CONTRACT_NO,
                                               ch.VALUE:headers:section::VARCHAR), ' | ')
         || '\n' || ch.VALUE:chunk::VARCHAR
FROM SC.RAW_DOCS.CONTRACT_PAGES p
JOIN SC.CONFORMED.DT_CONTRACT_TERMS t ON t.DOC_FILE_PATH = p.RELATIVE_PATH AND t.DOC_FILE_MD5 = p.FILE_MD5
LEFT JOIN SC.RAW_SUPPLIER.SUPPLIERS s ON s.SUPPLIER_ID = t.DOC_SUPPLIER_PORTAL_ID,
LATERAL FLATTEN(INPUT => SNOWFLAKE.CORTEX.SPLIT_TEXT_MARKDOWN_HEADER(
         p.PAGE_TEXT, OBJECT_CONSTRUCT('#', 'doc_title', '##', 'section'), 1000, 0)) ch;

-- -----------------------------------------------------------------------------
-- DT_SUPPLIER_PART_XWALK: supplier part number -> ERP PART_NO
--   Rule: 'ACME-00123' -> 'P000123'. Numbers that hit no ERP part are kept with
--   PART_NO NULL and flag UNMAPPED_PART (planted ~2%).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SC.CONFORMED.DT_SUPPLIER_PART_XWALK (
  SUPPLIER_PORTAL_ID  COMMENT 'Supplier-portal identifier as used on supplier documents.',
  SUPPLIER_NO         COMMENT 'Resolved ERP vendor number.',
  SUPPLIER_PART_NO    COMMENT 'Part number in supplier format (<SUPPLIER_CODE>-<5 digits>).',
  CANDIDATE_PART_NO   COMMENT 'ERP part number derived from the supplier number by the crosswalk rule, before validation.',
  PART_NO             COMMENT 'Validated ERP part number; NULL when the candidate is not in the ERP material master.',
  HAS_ERP_PART        COMMENT 'TRUE when the supplier part number resolves to an ERP part.',
  DQ_FLAGS            COMMENT 'Data-quality flags: UNMAPPED_PART when no ERP part matches.'
)
  TARGET_LAG = DOWNSTREAM WAREHOUSE = SC_WH REFRESH_MODE = AUTO
  COMMENT = 'Crosswalk resolving supplier part numbers to ERP PART_NO (SupplierPart key resolution). One row per supplier x supplier part number.'
AS
SELECT sp.SUPPLIER_ID, s.ERP_VENDOR_NO, sp.SUPPLIER_PART_NO,
       'P' || LPAD(REGEXP_SUBSTR(sp.SUPPLIER_PART_NO, '[0-9]+$'), 6, '0'),
       p.PART_ID,
       p.PART_ID IS NOT NULL,
       ARRAY_COMPACT(ARRAY_CONSTRUCT(IFF(p.PART_ID IS NULL, 'UNMAPPED_PART', NULL)))
FROM SC.RAW_SUPPLIER.SUPPLIER_PARTS sp
JOIN SC.RAW_SUPPLIER.SUPPLIERS s ON s.SUPPLIER_ID = sp.SUPPLIER_ID
LEFT JOIN SC.RAW_ERP.PARTS p     ON p.PART_ID = 'P' || LPAD(REGEXP_SUBSTR(sp.SUPPLIER_PART_NO, '[0-9]+$'), 6, '0');

-- -----------------------------------------------------------------------------
-- DIM_SUPPLIER_PART
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SC.CONFORMED.DIM_SUPPLIER_PART (
  SUPPLIER_NO           COMMENT 'Supplier (ERP vendor number). Key part 1.',
  SUPPLIER_PART_NO      COMMENT 'Supplier part number. Key part 2 (unique per supplier; PART_NO alone can be NULL for unmapped numbers).',
  PART_NO               COMMENT 'ERP part the supplier is approved to supply; NULL when unmapped (UNMAPPED_PART).',
  SUPPLIER_DESCRIPTION  COMMENT 'Description on the supplier catalogue.',
  UNIT_PRICE_AMT        COMMENT 'Catalogue / contract unit price per base UoM in reporting currency (USD).',
  LEAD_TIME_DAYS        COMMENT 'Quoted lead time in days.',
  MOQ                   COMMENT 'Minimum order quantity in base UoM.',
  IS_PREFERRED          COMMENT 'TRUE for the preferred (rank 1) source of the part.',
  CONTRACT_NO           COMMENT 'Governing contract (R6): the supplier''s contract in DIM_CONTRACT (supplier-level contract, covers all its parts); NULL = no contract (spot buy).',
  VALID_FROM            COMMENT 'First day the sourcing record is valid.',
  VALID_TO              COMMENT 'Last day the sourcing record is valid; NULL = open-ended.',
  DQ_FLAGS              COMMENT 'Data-quality flags inherited from the crosswalk (UNMAPPED_PART).'
)
  TARGET_LAG = '1 hour' WAREHOUSE = SC_WH REFRESH_MODE = AUTO
  COMMENT = 'SupplierPart: a Supplier approved to supply a Part, with the supplier part number and sourcing terms. One row per SUPPLIER_NO x SUPPLIER_PART_NO.'
AS
WITH ctr AS (
  -- contract PDFs carry no part schedule: a supplier's contract governs all its parts;
  -- if a supplier ever has several, the latest effective one wins
  SELECT SUPPLIER_NO, CONTRACT_NO FROM SC.CONFORMED.DIM_CONTRACT
  WHERE SUPPLIER_NO IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY SUPPLIER_NO ORDER BY VALID_FROM DESC, CONTRACT_NO DESC) = 1
)
SELECT x.SUPPLIER_NO, sp.SUPPLIER_PART_NO, x.PART_NO, sp.SUPPLIER_DESCRIPTION,
       IFF(sp.CURRENCY = 'USD', sp.UNIT_PRICE, NULL),
       sp.LEAD_TIME_DAYS, sp.MOQ, sp.IS_PREFERRED,
       ctr.CONTRACT_NO, sp.VALID_FROM, sp.VALID_TO, x.DQ_FLAGS
FROM SC.RAW_SUPPLIER.SUPPLIER_PARTS sp
JOIN SC.CONFORMED.DT_SUPPLIER_PART_XWALK x
  ON x.SUPPLIER_PORTAL_ID = sp.SUPPLIER_ID AND x.SUPPLIER_PART_NO = sp.SUPPLIER_PART_NO
LEFT JOIN ctr ON ctr.SUPPLIER_NO = x.SUPPLIER_NO;

-- -----------------------------------------------------------------------------
-- DT_SHIPMENT_ARRIVAL: dedup EDI re-sends, link ERP delivery, arrival precedence
--   Arrival = (1) IoT gate arrival at customer site, (2) carrier POD.
--   (3) carrier "arrived" event: not in RAW. (4) GR fallback: inbound only.
--   Local date in customer ship-to zone; plant zone + TZ_FALLBACK if unknown.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SC.CONFORMED.DT_SHIPMENT_ARRIVAL (
  SHIPMENT_NO           COMMENT 'TMS shipment id (deduplicated: first-loaded row of each EDI re-send kept).',
  SO_NO                 COMMENT 'Sales order of the shipped line.',
  LINE_NO               COMMENT 'Sales order line number.',
  SOURCE_ORDER_LINE_ID  COMMENT 'ERP order line id (lineage).',
  ORDERED_PART_NO       COMMENT 'Part ordered on the line.',
  SHIPPED_PART_NO       COMMENT 'Part actually shipped per the ERP delivery.',
  ERP_DELIVERY_NO       COMMENT 'ERP outbound delivery (goods issue document).',
  SHIPMENT_SEQ          COMMENT 'Sequence of this shipment within the order line (1 = first).',
  SCAC                  COMMENT 'Carrier that moved the shipment.',
  ORIGIN_PLANT_CODE     COMMENT 'Shipping plant.',
  CUSTOMER_NO           COMMENT 'Sold-to customer of the order.',
  SHIPPED_QTY           COMMENT 'Quantity on this shipment in base UoM.',
  GROSS_WEIGHT_KG       COMMENT 'Gross weight of the shipment in kg.',
  GOODS_ISSUE_DATE      COMMENT 'ERP goods-issue date, plant-local business date.',
  PICKUP_TS             COMMENT 'Carrier pickup timestamp, UTC.',
  POD_TS                COMMENT 'Carrier proof-of-delivery timestamp, UTC.',
  IOT_ARRIVAL_TS        COMMENT 'First IoT gate-arrival event at the customer site, UTC.',
  CUSTOMER_GR_DATE      COMMENT 'Customer receipt confirmation date from ERP (not an arrival source for outbound).',
  FREIGHT_COST          COMMENT 'Carrier freight cost as invoiced, in FREIGHT_CURRENCY; NULL if not yet invoiced.',
  FREIGHT_CURRENCY      COMMENT 'Currency of FREIGHT_COST.',
  ARRIVAL_TZ            COMMENT 'Time zone used for ARRIVAL_LOCAL_DATE (customer ship-to; plant if unknown).',
  ARRIVAL_TS            COMMENT 'Arrival timestamp, UTC: first of IoT gate arrival, then carrier POD (metric_contracts.md §1.1).',
  ARRIVAL_SOURCE        COMMENT 'Source chosen for ARRIVAL_TS: IOT_GEOFENCE or CARRIER_POD; NULL when no evidence.',
  ARRIVAL_LOCAL_DATE    COMMENT 'Date of ARRIVAL_TS in ARRIVAL_TZ.',
  IS_SUBSTITUTION       COMMENT 'TRUE when a different part than ordered was shipped (counts as unfilled).',
  DQ_FLAGS              COMMENT 'NO_ARRIVAL_EVIDENCE, TZ_FALLBACK, SUBSTITUTION.'
)
  TARGET_LAG = DOWNSTREAM WAREHOUSE = SC_WH REFRESH_MODE = AUTO
  COMMENT = 'Intermediate: deduplicated outbound shipments with resolved keys and contract arrival precedence. One row per SHIPMENT_NO.'
AS
WITH s AS (
  SELECT SHIPMENT_ID, ORDER_LINE_ID, ERP_DELIVERY_ID, SHIPMENT_SEQ, CARRIER_ID, ORIGIN_PLANT_ID,
         QTY_SHIPPED, GROSS_WEIGHT_KG, PICKUP_TS_UTC, POD_TS_UTC, FREIGHT_COST, FREIGHT_CURRENCY
  FROM SC.RAW_LOGISTICS.SHIPMENTS
  QUALIFY ROW_NUMBER() OVER (PARTITION BY SHIPMENT_ID ORDER BY LOADED_TS) = 1
),
iot AS (
  SELECT SHIPMENT_ID, MIN(EVENT_TS_UTC) AS EVENT_TS_UTC
  FROM SC.RAW_IOT.ARRIVAL_EVENTS
  WHERE EVENT_TYPE = 'GATE_ARRIVAL' AND LOCATION_TYPE = 'CUSTOMER_SITE'
  GROUP BY SHIPMENT_ID
),
j AS (
  SELECT s.*, ol.SO_ID, ol.LINE_NO, ol.PART_ID AS ORDERED_PART_ID, e.PART_ID_SHIPPED, e.SHIP_DATE,
         e.GOODS_RECEIPT_DATE, c.SCAC, so.CUSTOMER_ID, iot.EVENT_TS_UTC,
         cu.SHIP_TO_TIMEZONE, p.TIMEZONE AS PLANT_TZ,
         COALESCE(iot.EVENT_TS_UTC, s.POD_TS_UTC) AS ARR_NTZ
  FROM s
  JOIN SC.RAW_ERP.ORDER_LINES ol         ON ol.ORDER_LINE_ID = s.ORDER_LINE_ID
  JOIN SC.RAW_ERP.SALES_ORDERS so        ON so.SO_ID = ol.SO_ID
  LEFT JOIN SC.RAW_ERP.CUSTOMERS cu      ON cu.CUSTOMER_ID = so.CUSTOMER_ID
  LEFT JOIN SC.RAW_ERP.PLANTS p          ON p.PLANT_ID = s.ORIGIN_PLANT_ID
  LEFT JOIN SC.RAW_ERP.ERP_SHIPMENTS e   ON e.DELIVERY_ID = s.ERP_DELIVERY_ID
  LEFT JOIN SC.RAW_LOGISTICS.CARRIERS c  ON c.CARRIER_ID = s.CARRIER_ID
  LEFT JOIN iot                          ON iot.SHIPMENT_ID = s.SHIPMENT_ID
)
SELECT
  SHIPMENT_ID, SO_ID, LINE_NO, ORDER_LINE_ID, ORDERED_PART_ID, COALESCE(PART_ID_SHIPPED, ORDERED_PART_ID),
  ERP_DELIVERY_ID, SHIPMENT_SEQ, SCAC, ORIGIN_PLANT_ID, CUSTOMER_ID,
  QTY_SHIPPED::NUMBER(18,3), GROSS_WEIGHT_KG, SHIP_DATE,
  TIMESTAMP_TZ_FROM_PARTS(YEAR(PICKUP_TS_UTC), MONTH(PICKUP_TS_UTC), DAY(PICKUP_TS_UTC), HOUR(PICKUP_TS_UTC), MINUTE(PICKUP_TS_UTC), SECOND(PICKUP_TS_UTC), DATE_PART(nanosecond, PICKUP_TS_UTC), 'UTC'),
  TIMESTAMP_TZ_FROM_PARTS(YEAR(POD_TS_UTC), MONTH(POD_TS_UTC), DAY(POD_TS_UTC), HOUR(POD_TS_UTC), MINUTE(POD_TS_UTC), SECOND(POD_TS_UTC), DATE_PART(nanosecond, POD_TS_UTC), 'UTC'),
  TIMESTAMP_TZ_FROM_PARTS(YEAR(EVENT_TS_UTC), MONTH(EVENT_TS_UTC), DAY(EVENT_TS_UTC), HOUR(EVENT_TS_UTC), MINUTE(EVENT_TS_UTC), SECOND(EVENT_TS_UTC), DATE_PART(nanosecond, EVENT_TS_UTC), 'UTC'),
  GOODS_RECEIPT_DATE, FREIGHT_COST, FREIGHT_CURRENCY,
  COALESCE(SHIP_TO_TIMEZONE, PLANT_TZ),
  TIMESTAMP_TZ_FROM_PARTS(YEAR(ARR_NTZ), MONTH(ARR_NTZ), DAY(ARR_NTZ), HOUR(ARR_NTZ), MINUTE(ARR_NTZ), SECOND(ARR_NTZ), DATE_PART(nanosecond, ARR_NTZ), 'UTC'),
  CASE WHEN EVENT_TS_UTC IS NOT NULL THEN 'IOT_GEOFENCE' WHEN POD_TS_UTC IS NOT NULL THEN 'CARRIER_POD' END,
  CONVERT_TIMEZONE('UTC', COALESCE(SHIP_TO_TIMEZONE, PLANT_TZ), ARR_NTZ)::DATE,
  COALESCE(PART_ID_SHIPPED, ORDERED_PART_ID) <> ORDERED_PART_ID,
  ARRAY_COMPACT(ARRAY_CONSTRUCT(
    IFF(ARR_NTZ IS NULL, 'NO_ARRIVAL_EVIDENCE', NULL),
    IFF(SHIP_TO_TIMEZONE IS NULL, 'TZ_FALLBACK', NULL),
    IFF(COALESCE(PART_ID_SHIPPED, ORDERED_PART_ID) <> ORDERED_PART_ID, 'SUBSTITUTION', NULL)))
FROM j;

-- -----------------------------------------------------------------------------
-- FACT_SHIPMENT (grain: shipment x order line; one line per shipment in RAW)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SC.CONFORMED.FACT_SHIPMENT (
  SHIPMENT_NO         COMMENT 'Key part 1: TMS shipment id (deduplicated).',
  SO_NO               COMMENT 'Key part 2: sales order.',
  LINE_NO             COMMENT 'Key part 3: sales order line.',
  SCAC                COMMENT 'Carrier that moved the shipment (R12).',
  ORIGIN_PLANT_CODE   COMMENT 'Shipping plant.',
  WAREHOUSE_CODE      COMMENT 'Origin warehouse (R13). NULL: RAW shipments carry plant only.',
  CUSTOMER_NO         COMMENT 'Sold-to customer of the order.',
  ERP_DELIVERY_NO     COMMENT 'ERP outbound delivery document.',
  SHIPMENT_SEQ        COMMENT 'Sequence of this shipment within the order line.',
  ORDERED_PART_NO     COMMENT 'Part ordered on the line.',
  SHIPPED_PART_NO     COMMENT 'Part physically shipped.',
  IS_SUBSTITUTION     COMMENT 'TRUE when SHIPPED_PART_NO differs from ORDERED_PART_NO.',
  SHIPPED_QTY         COMMENT 'Quantity on the shipment in base UoM.',
  GROSS_WEIGHT_KG     COMMENT 'Actual gross weight in kg.',
  GOODS_ISSUE_DATE    COMMENT 'ERP goods-issue date, plant-local business date.',
  PICKUP_TS           COMMENT 'Carrier pickup, UTC.',
  POD_TS              COMMENT 'Carrier proof of delivery, UTC.',
  IOT_ARRIVAL_TS      COMMENT 'IoT gate arrival at the customer site, UTC.',
  ARRIVAL_TS          COMMENT 'Contract arrival timestamp, UTC (IoT geofence, then carrier POD).',
  ARRIVAL_SOURCE      COMMENT 'IOT_GEOFENCE or CARRIER_POD; NULL when there is no arrival evidence.',
  ARRIVAL_TZ          COMMENT 'Receiving-location time zone used for the local date (customer ship-to; plant on fallback).',
  ARRIVAL_LOCAL_DATE  COMMENT 'Arrival date in the customer ship-to time zone.',
  CUSTOMER_GR_DATE    COMMENT 'Customer goods-receipt confirmation date from ERP (informational).',
  FREIGHT_AMT         COMMENT 'Actual carrier freight for the shipment in reporting currency (USD); NULL until invoiced.',
  HAS_FREIGHT_INVOICE COMMENT 'TRUE when a carrier freight cost has been received.',
  DQ_FLAGS            COMMENT 'NO_ARRIVAL_EVIDENCE, TZ_FALLBACK, SUBSTITUTION, NO_FREIGHT_INVOICE, NO_FX_RATE.'
)
  TARGET_LAG = '1 hour' WAREHOUSE = SC_WH REFRESH_MODE = AUTO
  COMMENT = 'Shipment: physical movement of (part of) one OrderLine by one Carrier, with arrival and freight facts. Grain SHIPMENT_NO x SO_NO x LINE_NO. EDI duplicates removed.'
AS
SELECT SHIPMENT_NO, SO_NO, LINE_NO, SCAC, ORIGIN_PLANT_CODE, NULL::VARCHAR, CUSTOMER_NO, ERP_DELIVERY_NO, SHIPMENT_SEQ,
       ORDERED_PART_NO, SHIPPED_PART_NO, IS_SUBSTITUTION, SHIPPED_QTY, GROSS_WEIGHT_KG, GOODS_ISSUE_DATE,
       PICKUP_TS, POD_TS, IOT_ARRIVAL_TS, ARRIVAL_TS, ARRIVAL_SOURCE, ARRIVAL_TZ, ARRIVAL_LOCAL_DATE, CUSTOMER_GR_DATE,
       IFF(FREIGHT_CURRENCY = 'USD', FREIGHT_COST, NULL)::NUMBER(18,2),
       FREIGHT_COST IS NOT NULL,
       ARRAY_CAT(DQ_FLAGS, ARRAY_COMPACT(ARRAY_CONSTRUCT(
         IFF(FREIGHT_COST IS NULL, 'NO_FREIGHT_INVOICE', NULL),
         IFF(FREIGHT_COST IS NOT NULL AND FREIGHT_CURRENCY <> 'USD', 'NO_FX_RATE', NULL))))
FROM SC.CONFORMED.DT_SHIPMENT_ARRIVAL;

-- -----------------------------------------------------------------------------
-- DT_ORDER_LINE_MILESTONES (metric_contracts.md §1.1, outbound)
--   Commit date: FIRST_CONFIRMED_DATE; a reschedule with reason CUSTOMER_REQUEST
--   resets it to the confirmation issued after the change (PROMISED_DATE).
--   Arrived qty excludes substituted parts. Complete-arrival = local date of the
--   arrival that brings cumulative arrived qty to >= required qty.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SC.CONFORMED.DT_ORDER_LINE_MILESTONES (
  SOURCE_ORDER_LINE_ID        COMMENT 'ERP order line id.',
  FIRST_COMMIT_DATE           COMMENT 'Commit date (§1.1): first confirmed date, reset only by a customer-requested change.',
  IS_COMMIT_RESET             COMMENT 'TRUE when a CUSTOMER_REQUEST reschedule reset the commit date.',
  REQUIRED_QTY                COMMENT 'Required qty (§1.1): ordered minus customer-cancelled, base UoM.',
  SHIPMENT_COUNT              COMMENT 'Number of shipments for the line.',
  SHIPPED_QTY                 COMMENT 'Total shipped qty, base UoM, including substituted parts.',
  SUBSTITUTED_QTY             COMMENT 'Shipped qty of a substitute part (never counts as filled).',
  ARRIVED_QTY                 COMMENT 'Arrived qty of the ordered part with arrival evidence, base UoM.',
  ARRIVED_BY_COMMIT_QTY       COMMENT 'Qty arrived by commit date (§1.1): arrived qty of the ordered part with local arrival date <= commit date. Uncapped; the semantic view caps at required qty.',
  FIRST_ARRIVAL_LOCAL_DATE    COMMENT 'Local date of the first arrival.',
  LAST_ARRIVAL_LOCAL_DATE     COMMENT 'Local date of the last arrival.',
  COMPLETE_ARRIVAL_TS         COMMENT 'UTC timestamp of the arrival that made the line complete.',
  COMPLETE_ARRIVAL_SOURCE     COMMENT 'Arrival source of that completing arrival.',
  COMPLETE_ARRIVAL_LOCAL_DATE COMMENT 'Complete-arrival date (§1.1): local date when cumulative arrived qty reached required qty. NULL while incomplete.',
  HAS_ARRIVAL_GAP             COMMENT 'TRUE when at least one shipment of the line has no arrival evidence.',
  HAS_SUBSTITUTION            COMMENT 'TRUE when any shipment carried a substitute part.',
  HAS_TZ_FALLBACK             COMMENT 'TRUE when the customer ship-to zone was unknown and the plant zone was used.'
)
  TARGET_LAG = DOWNSTREAM WAREHOUSE = SC_WH REFRESH_MODE = AUTO
  COMMENT = 'Intermediate: §1.1 milestone attributes per outbound order line. One row per ERP order line.'
AS
WITH ol AS (
  SELECT ORDER_LINE_ID,
         IFF(RESCHEDULE_REASON = 'CUSTOMER_REQUEST', PROMISED_DATE, FIRST_CONFIRMED_DATE) AS COMMIT_DATE,
         RESCHEDULE_REASON = 'CUSTOMER_REQUEST' AND PROMISED_DATE IS NOT NULL               AS IS_RESET,
         QTY_ORDERED - QTY_CANCELLED                                                       AS REQ_QTY
  FROM SC.RAW_ERP.ORDER_LINES
),
sh AS (
  SELECT a.*, ol.REQ_QTY,
         SUM(IFF(NOT a.IS_SUBSTITUTION AND a.ARRIVAL_TS IS NOT NULL, a.SHIPPED_QTY, 0))
           OVER (PARTITION BY a.SOURCE_ORDER_LINE_ID ORDER BY a.ARRIVAL_TS, a.SHIPMENT_NO
                 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)                          AS CUM_ARRIVED
  FROM SC.CONFORMED.DT_SHIPMENT_ARRIVAL a
  JOIN ol ON ol.ORDER_LINE_ID = a.SOURCE_ORDER_LINE_ID
),
agg AS (
  SELECT
    sh.SOURCE_ORDER_LINE_ID,
    COUNT(*)                                                                         AS SHIPMENT_COUNT,
    SUM(sh.SHIPPED_QTY)                                                              AS SHIPPED_QTY,
    SUM(IFF(sh.IS_SUBSTITUTION, sh.SHIPPED_QTY, 0))                                  AS SUBSTITUTED_QTY,
    SUM(IFF(NOT sh.IS_SUBSTITUTION AND sh.ARRIVAL_TS IS NOT NULL, sh.SHIPPED_QTY, 0)) AS ARRIVED_QTY,
    MIN(sh.ARRIVAL_LOCAL_DATE)                                                       AS FIRST_ARR,
    MAX(sh.ARRIVAL_LOCAL_DATE)                                                       AS LAST_ARR,
    MIN(IFF(sh.REQ_QTY > 0 AND NOT sh.IS_SUBSTITUTION AND sh.ARRIVAL_TS IS NOT NULL AND sh.CUM_ARRIVED >= sh.REQ_QTY, sh.ARRIVAL_TS, NULL)) AS COMPLETE_TS,
    BOOLOR_AGG(sh.ARRIVAL_TS IS NULL)                                                AS HAS_GAP,
    BOOLOR_AGG(sh.IS_SUBSTITUTION)                                                   AS HAS_SUB,
    BOOLOR_AGG(ARRAY_CONTAINS('TZ_FALLBACK'::VARIANT, sh.DQ_FLAGS))                  AS HAS_TZFB
  FROM sh
  GROUP BY sh.SOURCE_ORDER_LINE_ID
),
cmp AS (
  SELECT SOURCE_ORDER_LINE_ID, ARRIVAL_TS, ARRIVAL_SOURCE, ARRIVAL_LOCAL_DATE
  FROM sh
  WHERE REQ_QTY > 0 AND NOT IS_SUBSTITUTION AND ARRIVAL_TS IS NOT NULL AND CUM_ARRIVED >= REQ_QTY
  QUALIFY ROW_NUMBER() OVER (PARTITION BY SOURCE_ORDER_LINE_ID ORDER BY ARRIVAL_TS, SHIPMENT_NO) = 1
),
abc AS (
  SELECT sh.SOURCE_ORDER_LINE_ID,
         SUM(IFF(NOT sh.IS_SUBSTITUTION AND sh.ARRIVAL_TS IS NOT NULL AND sh.ARRIVAL_LOCAL_DATE <= ol.COMMIT_DATE, sh.SHIPPED_QTY, 0)) AS ABC_QTY
  FROM sh JOIN ol ON ol.ORDER_LINE_ID = sh.SOURCE_ORDER_LINE_ID
  GROUP BY sh.SOURCE_ORDER_LINE_ID
)
SELECT
  ol.ORDER_LINE_ID, ol.COMMIT_DATE, ol.IS_RESET, ol.REQ_QTY::NUMBER(18,3),
  COALESCE(agg.SHIPMENT_COUNT, 0),
  COALESCE(agg.SHIPPED_QTY, 0)::NUMBER(18,3),
  COALESCE(agg.SUBSTITUTED_QTY, 0)::NUMBER(18,3),
  COALESCE(agg.ARRIVED_QTY, 0)::NUMBER(18,3),
  IFF(ol.COMMIT_DATE IS NULL, NULL, COALESCE(abc.ABC_QTY, 0))::NUMBER(18,3),
  agg.FIRST_ARR, agg.LAST_ARR,
  cmp.ARRIVAL_TS, cmp.ARRIVAL_SOURCE, cmp.ARRIVAL_LOCAL_DATE,
  COALESCE(agg.HAS_GAP, FALSE), COALESCE(agg.HAS_SUB, FALSE), COALESCE(agg.HAS_TZFB, FALSE)
FROM ol
LEFT JOIN agg ON agg.SOURCE_ORDER_LINE_ID = ol.ORDER_LINE_ID
LEFT JOIN cmp ON cmp.SOURCE_ORDER_LINE_ID = ol.ORDER_LINE_ID
LEFT JOIN abc ON abc.SOURCE_ORDER_LINE_ID = ol.ORDER_LINE_ID;

-- -----------------------------------------------------------------------------
-- FACT_ORDER_LINE (grain: SO_NO + LINE_NO; Customer OTD % and Fill Rate %)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SC.CONFORMED.FACT_ORDER_LINE (
  SO_NO                       COMMENT 'Key part 1: sales order (customer request to buy, as accepted).',
  LINE_NO                     COMMENT 'Key part 2: line on the sales order.',
  SOURCE_ORDER_LINE_ID        COMMENT 'ERP order line id (lineage; deduplicated on SO_NO + LINE_NO).',
  CUSTOMER_NO                 COMMENT 'Sold-to customer (R8).',
  PART_NO                     COMMENT 'Part ordered (R9).',
  PLANT_CODE                  COMMENT 'Fulfilling / shipping plant (R10).',
  ORDER_DATE                  COMMENT 'Order date of the sales order (Time role: order date).',
  ORDER_TYPE                  COMMENT 'STANDARD or RUSH.',
  LINE_TYPE                   COMMENT 'STANDARD, RETURN or FREE_OF_CHARGE. The semantic view excludes RETURN and FREE_OF_CHARGE.',
  LINE_STATUS                 COMMENT 'ERP line status: OPEN, PARTIALLY_SHIPPED, SHIPPED, DELIVERED, CLOSED_SHORT, CANCELLED, CLOSED.',
  ORDER_QTY                   COMMENT 'Ordered qty in base UoM (negative for returns).',
  CANCELLED_QTY               COMMENT 'Qty cancelled by the customer, base UoM.',
  REQUIRED_QTY                COMMENT 'Required qty (§1.1) = ORDER_QTY - CANCELLED_QTY, base UoM.',
  BASE_UOM                    COMMENT 'Base unit of measure of all *_QTY columns.',
  UNIT_PRICE                  COMMENT 'Net selling price per base UoM in CURRENCY (document currency).',
  CURRENCY                    COMMENT 'Document currency of UNIT_PRICE.',
  REQUESTED_DATE              COMMENT 'Date the customer asked for (basis of On-Time to Request; not the commit).',
  FIRST_CONFIRMED_DATE        COMMENT 'First date we confirmed for the line.',
  PROMISED_DATE               COMMENT 'Latest confirmed (rescheduled) date. Not used as commit unless the customer requested the change.',
  RESCHEDULE_REASON           COMMENT 'Reason code of the reschedule: CUSTOMER_REQUEST, MATERIAL_SHORTAGE, CAPACITY; NULL if never rescheduled.',
  FIRST_COMMIT_DATE           COMMENT 'Commit date (§1.1): FIRST_CONFIRMED_DATE, reset to PROMISED_DATE only for CUSTOMER_REQUEST. Time anchor of Customer OTD % and Fill Rate %.',
  IS_COMMIT_RESET             COMMENT 'TRUE when the commit date was reset by a customer-requested change.',
  SHIPMENT_COUNT              COMMENT 'Number of shipments for the line (2+ = split).',
  SHIPPED_QTY                 COMMENT 'Total shipped qty, base UoM, including substitutes.',
  SUBSTITUTED_QTY             COMMENT 'Shipped qty that was a substitute part.',
  ARRIVED_QTY                 COMMENT 'Arrived qty of the ordered part with arrival evidence.',
  ARRIVED_BY_COMMIT_QTY       COMMENT 'Qty arrived by commit date (§1.1): ordered part, customer-local arrival date <= FIRST_COMMIT_DATE. Uncapped; NULL when no commit date.',
  FIRST_ARRIVAL_LOCAL_DATE    COMMENT 'Customer-local date of the first arrival.',
  LAST_ARRIVAL_LOCAL_DATE     COMMENT 'Customer-local date of the last arrival.',
  COMPLETE_ARRIVAL_TS         COMMENT 'UTC timestamp of the arrival that completed the line.',
  COMPLETE_ARRIVAL_SOURCE     COMMENT 'Arrival source of the completing arrival (IOT_GEOFENCE / CARRIER_POD).',
  COMPLETE_ARRIVAL_LOCAL_DATE COMMENT 'Complete-arrival date (§1.1) in the customer ship-to zone; NULL while the line is incomplete. The semantic view compares it with the on-time window.',
  ARRIVAL_TZ                  COMMENT 'Time zone of the local arrival dates (customer ship-to; plant on TZ_FALLBACK).',
  DQ_FLAGS                    COMMENT 'NO_COMMIT, COMMIT_RESET, NO_ARRIVAL_EVIDENCE, SUBSTITUTION, TZ_FALLBACK.'
)
  TARGET_LAG = '1 hour' WAREHOUSE = SC_WH REFRESH_MODE = AUTO
  COMMENT = 'OrderLine: one Part, quantity and commit date on a SalesOrder, with §1.1 outbound milestones. Grain for Customer OTD % and Fill Rate %. One row per SO_NO + LINE_NO; no on-time or in-full logic here.'
AS
SELECT
  ol.SO_ID, ol.LINE_NO, ol.ORDER_LINE_ID, so.CUSTOMER_ID, ol.PART_ID, ol.PLANT_ID, so.ORDER_DATE, so.ORDER_TYPE,
  ol.LINE_TYPE, ol.STATUS, ol.QTY_ORDERED::NUMBER(18,3), ol.QTY_CANCELLED::NUMBER(18,3), m.REQUIRED_QTY, ol.BASE_UOM,
  ol.UNIT_PRICE, ol.CURRENCY, ol.REQUESTED_DATE, ol.FIRST_CONFIRMED_DATE, ol.PROMISED_DATE, ol.RESCHEDULE_REASON,
  m.FIRST_COMMIT_DATE, m.IS_COMMIT_RESET, m.SHIPMENT_COUNT, m.SHIPPED_QTY, m.SUBSTITUTED_QTY, m.ARRIVED_QTY,
  m.ARRIVED_BY_COMMIT_QTY, m.FIRST_ARRIVAL_LOCAL_DATE, m.LAST_ARRIVAL_LOCAL_DATE,
  m.COMPLETE_ARRIVAL_TS, m.COMPLETE_ARRIVAL_SOURCE, m.COMPLETE_ARRIVAL_LOCAL_DATE,
  COALESCE(cu.SHIP_TO_TIMEZONE, p.TIMEZONE),
  ARRAY_COMPACT(ARRAY_CONSTRUCT(
    IFF(m.FIRST_COMMIT_DATE IS NULL, 'NO_COMMIT', NULL),
    IFF(m.IS_COMMIT_RESET, 'COMMIT_RESET', NULL),
    IFF(m.HAS_ARRIVAL_GAP, 'NO_ARRIVAL_EVIDENCE', NULL),
    IFF(m.HAS_SUBSTITUTION, 'SUBSTITUTION', NULL),
    IFF(cu.SHIP_TO_TIMEZONE IS NULL OR m.HAS_TZ_FALLBACK, 'TZ_FALLBACK', NULL)))
FROM SC.RAW_ERP.ORDER_LINES ol
JOIN SC.RAW_ERP.SALES_ORDERS so               ON so.SO_ID = ol.SO_ID
JOIN SC.CONFORMED.DT_ORDER_LINE_MILESTONES m  ON m.SOURCE_ORDER_LINE_ID = ol.ORDER_LINE_ID
LEFT JOIN SC.RAW_ERP.CUSTOMERS cu             ON cu.CUSTOMER_ID = so.CUSTOMER_ID
LEFT JOIN SC.RAW_ERP.PLANTS p                 ON p.PLANT_ID = ol.PLANT_ID
QUALIFY ROW_NUMBER() OVER (PARTITION BY ol.SO_ID, ol.LINE_NO ORDER BY ol.ORDER_LINE_ID) = 1;

-- -----------------------------------------------------------------------------
-- DT_INBOUND_ARRIVAL: inbound arrival precedence per ASN (metric_contracts.md §1.1)
--   (1) IoT geofence entry at the receiving plant (first event; re-pings ignored),
--   (2) carrier POD at the plant dock, (3) carrier "arrived" event: not in RAW,
--   (4) ERP GR posting date, flagged GR_FALLBACK. Local date in the receiving
--   plant's time zone. A shipped ASN with none of them is NO_ARRIVAL_EVIDENCE.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SC.CONFORMED.DT_INBOUND_ARRIVAL (
  ASN_NO                COMMENT 'Advance ship notice (one inbound consignment of a PO line).',
  PO_NO                 COMMENT 'Purchase order of the ASN.',
  PO_LINE_NO            COMMENT 'PO line of the ASN.',
  PLANT_CODE            COMMENT 'Receiving plant.',
  ARRIVAL_TZ            COMMENT 'Receiving plant time zone used for ARRIVAL_LOCAL_DATE.',
  ASN_QTY               COMMENT 'Qty notified on the ASN, base UoM (arrived qty once the ASN has arrival evidence).',
  GR_NO                 COMMENT 'Goods receipt posted for the ASN; NULL until posted.',
  GR_POSTING_DATE       COMMENT 'GR posting date, plant-local business date (source 4).',
  GR_DOCK_ARRIVAL_DATE  COMMENT 'Dock arrival date recorded on the GR, plant-local (lineage; not a contract source).',
  IOT_ARRIVAL_TS        COMMENT 'First IoT geofence entry at the receiving plant, UTC (source 1).',
  CARRIER_POD_TS        COMMENT 'Carrier proof of delivery at the plant dock, UTC (source 2).',
  ARRIVAL_TS            COMMENT 'Physical arrival timestamp, UTC: IoT geofence, then carrier POD; NULL when only the GR fallback exists.',
  ARRIVAL_SOURCE        COMMENT 'IOT_GEOFENCE, CARRIER_POD or GR_POSTING (GR_FALLBACK); NULL when there is no evidence.',
  ARRIVAL_LOCAL_DATE    COMMENT 'Arrival date in the receiving plant time zone; the GR posting date under GR_FALLBACK.',
  DQ_FLAGS              COMMENT 'GR_FALLBACK, NO_ARRIVAL_EVIDENCE.'
)
  TARGET_LAG = DOWNSTREAM WAREHOUSE = SC_WH REFRESH_MODE = AUTO
  COMMENT = 'Intermediate: inbound ASNs with contract arrival precedence (IoT geofence > carrier POD > GR posting). One row per ASN_NO.'
AS
WITH geo AS (
  SELECT ASN_ID, MIN(EVENT_TS_UTC) AS TS
  FROM SC.RAW_IOT.INBOUND_GEOFENCE_EVENTS
  WHERE EVENT_TYPE = 'GEOFENCE_ENTER' AND LOCATION_TYPE = 'RECEIVING_PLANT'
  GROUP BY ASN_ID
),
pod AS (
  SELECT ASN_ID, MIN(POD_TS_UTC) AS TS FROM SC.RAW_LOGISTICS.INBOUND_CARRIER_POD GROUP BY ASN_ID
),
j AS (
  SELECT a.ASN_ID, a.PO_ID, a.PO_LINE_NO, a.SHIP_TO_PLANT_ID, p.TIMEZONE, a.QTY_SHIPPED,
         g.GR_ID, g.POSTING_DATE, g.ARRIVAL_LOCAL_DATE AS DOCK_DATE,
         geo.TS AS GEO_TS, pod.TS AS POD_TS, COALESCE(geo.TS, pod.TS) AS ARR_NTZ
  FROM SC.RAW_SUPPLIER.ASNS a
  JOIN SC.RAW_ERP.PLANTS p                   ON p.PLANT_ID = a.SHIP_TO_PLANT_ID
  LEFT JOIN SC.RAW_SUPPLIER.GOODS_RECEIPTS g ON g.ASN_ID = a.ASN_ID
  LEFT JOIN geo                              ON geo.ASN_ID = a.ASN_ID
  LEFT JOIN pod                              ON pod.ASN_ID = a.ASN_ID
)
SELECT
  ASN_ID, PO_ID, PO_LINE_NO, SHIP_TO_PLANT_ID, TIMEZONE, QTY_SHIPPED::NUMBER(18,3),
  GR_ID, POSTING_DATE, DOCK_DATE,
  TIMESTAMP_TZ_FROM_PARTS(YEAR(GEO_TS), MONTH(GEO_TS), DAY(GEO_TS), HOUR(GEO_TS), MINUTE(GEO_TS), SECOND(GEO_TS), DATE_PART(nanosecond, GEO_TS), 'UTC'),
  TIMESTAMP_TZ_FROM_PARTS(YEAR(POD_TS), MONTH(POD_TS), DAY(POD_TS), HOUR(POD_TS), MINUTE(POD_TS), SECOND(POD_TS), DATE_PART(nanosecond, POD_TS), 'UTC'),
  TIMESTAMP_TZ_FROM_PARTS(YEAR(ARR_NTZ), MONTH(ARR_NTZ), DAY(ARR_NTZ), HOUR(ARR_NTZ), MINUTE(ARR_NTZ), SECOND(ARR_NTZ), DATE_PART(nanosecond, ARR_NTZ), 'UTC'),
  CASE WHEN GEO_TS IS NOT NULL THEN 'IOT_GEOFENCE' WHEN POD_TS IS NOT NULL THEN 'CARRIER_POD' WHEN GR_ID IS NOT NULL THEN 'GR_POSTING' END,
  COALESCE(CONVERT_TIMEZONE('UTC', TIMEZONE, ARR_NTZ)::DATE, POSTING_DATE),
  ARRAY_COMPACT(ARRAY_CONSTRUCT(
    IFF(ARR_NTZ IS NULL AND GR_ID IS NOT NULL, 'GR_FALLBACK', NULL),
    IFF(ARR_NTZ IS NULL AND GR_ID IS NULL, 'NO_ARRIVAL_EVIDENCE', NULL)))
FROM j;

-- -----------------------------------------------------------------------------
-- DT_PO_LINE_MILESTONES (metric_contracts.md §1.1, inbound)
--   Commit: supplier FIRST_CONFIRMED_DATE; BUYER_REQUEST reschedule resets it to
--   LATEST_CONFIRMED_DATE; never confirmed -> DUE_DATE, flag UNCONFIRMED.
--   Arrival: per ASN from DT_INBOUND_ARRIVAL (IoT geofence > carrier POD > GR
--   posting date, GR_FALLBACK). Arrived qty = ASN qty of ASNs with evidence.
--   Complete-arrival = plant-local date of the arrival that brings cumulative
--   arrived qty to >= required qty. GR quantities are kept for receipts / rejects.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SC.CONFORMED.DT_PO_LINE_MILESTONES (
  PO_NO                       COMMENT 'Purchase order.',
  PO_LINE_NO                  COMMENT 'Purchase order line.',
  FIRST_COMMIT_DATE           COMMENT 'Supplier commit date (§1.1).',
  IS_COMMIT_RESET             COMMENT 'TRUE when a BUYER_REQUEST reschedule reset the commit date.',
  IS_UNCONFIRMED              COMMENT 'TRUE when the supplier never confirmed; commit falls back to DUE_DATE.',
  REQUIRED_QTY                COMMENT 'Required qty (§1.1): ordered minus buyer-cancelled, base UoM.',
  ASN_COUNT                   COMMENT 'Number of advance ship notices received.',
  ASN_SHIPPED_QTY             COMMENT 'Qty the supplier notified as shipped.',
  GR_COUNT                    COMMENT 'Number of goods receipts posted.',
  RECEIVED_QTY                COMMENT 'Total qty received (posted GR qty before quality rejects).',
  REJECTED_QTY                COMMENT 'Total qty rejected at receipt inspection.',
  ARRIVED_QTY                 COMMENT 'Qty of ASNs with arrival evidence (IoT, POD or GR), base UoM.',
  ARRIVED_BY_COMMIT_QTY       COMMENT 'Qty arrived by commit date (§1.1): arrived qty with plant-local arrival date <= commit date. Uncapped.',
  FIRST_ARRIVAL_LOCAL_DATE    COMMENT 'First arrival date, plant-local.',
  LAST_ARRIVAL_LOCAL_DATE     COMMENT 'Last arrival date, plant-local.',
  COMPLETE_ARRIVAL_LOCAL_DATE COMMENT 'Complete-arrival date (§1.1): plant-local date when cumulative arrived qty reached required qty; NULL while incomplete.',
  COMPLETE_ARRIVAL_SOURCE     COMMENT 'Arrival source of the completing ASN: IOT_GEOFENCE, CARRIER_POD or GR_POSTING.',
  HAS_GR_FALLBACK             COMMENT 'TRUE when at least one arrival of the line comes from the GR posting date (GR_FALLBACK).',
  HAS_ARRIVAL_GAP             COMMENT 'TRUE when at least one shipped ASN of the line has no arrival evidence at all (NO_ARRIVAL_EVIDENCE).'
)
  TARGET_LAG = DOWNSTREAM WAREHOUSE = SC_WH REFRESH_MODE = AUTO
  COMMENT = 'Intermediate: §1.1 milestone attributes per inbound PO line. One row per PO_NO + PO_LINE_NO.'
AS
WITH po AS (
  SELECT PO_ID, PO_LINE_NO,
         CASE WHEN RESCHEDULE_REASON = 'BUYER_REQUEST' THEN LATEST_CONFIRMED_DATE
              WHEN FIRST_CONFIRMED_DATE IS NULL       THEN DUE_DATE
              ELSE FIRST_CONFIRMED_DATE END              AS COMMIT_DATE,
         RESCHEDULE_REASON = 'BUYER_REQUEST'             AS IS_RESET,
         FIRST_CONFIRMED_DATE IS NULL                    AS IS_UNCONF,
         QTY_ORDERED - QTY_CANCELLED                     AS REQ_QTY
  FROM SC.RAW_SUPPLIER.PURCHASE_ORDERS
),
arr AS (
  SELECT a.PO_NO, a.PO_LINE_NO, a.ASN_NO, a.ARRIVAL_LOCAL_DATE, a.ARRIVAL_SOURCE, a.ASN_QTY, po.REQ_QTY, po.COMMIT_DATE,
         SUM(a.ASN_QTY) OVER (PARTITION BY a.PO_NO, a.PO_LINE_NO ORDER BY a.ARRIVAL_LOCAL_DATE, a.ASN_NO
                              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS CUM_ARR
  FROM SC.CONFORMED.DT_INBOUND_ARRIVAL a
  JOIN po ON po.PO_ID = a.PO_NO AND po.PO_LINE_NO = a.PO_LINE_NO
  WHERE a.ARRIVAL_SOURCE IS NOT NULL
),
xagg AS (
  SELECT PO_NO, PO_LINE_NO, SUM(ASN_QTY) AS ARR_QTY,
         SUM(IFF(ARRIVAL_LOCAL_DATE <= COMMIT_DATE, ASN_QTY, 0)) AS ARR_BY_COMMIT,
         MIN(ARRIVAL_LOCAL_DATE) AS FIRST_ARR, MAX(ARRIVAL_LOCAL_DATE) AS LAST_ARR,
         BOOLOR_AGG(ARRIVAL_SOURCE = 'GR_POSTING') AS HAS_GRFB
  FROM arr GROUP BY PO_NO, PO_LINE_NO
),
cmp AS (
  SELECT PO_NO, PO_LINE_NO, ARRIVAL_LOCAL_DATE, ARRIVAL_SOURCE
  FROM arr
  WHERE REQ_QTY > 0 AND CUM_ARR >= REQ_QTY
  QUALIFY ROW_NUMBER() OVER (PARTITION BY PO_NO, PO_LINE_NO ORDER BY ARRIVAL_LOCAL_DATE, ASN_NO) = 1
),
gagg AS (
  SELECT PO_ID, PO_LINE_NO, COUNT(*) AS GR_COUNT, SUM(QTY_RECEIVED) AS REC, SUM(QTY_REJECTED) AS REJ
  FROM SC.RAW_SUPPLIER.GOODS_RECEIPTS GROUP BY PO_ID, PO_LINE_NO
),
aagg AS (
  SELECT PO_NO, PO_LINE_NO, COUNT(*) AS ASN_COUNT, SUM(ASN_QTY) AS ASN_QTY, BOOLOR_AGG(ARRIVAL_SOURCE IS NULL) AS HAS_GAP
  FROM SC.CONFORMED.DT_INBOUND_ARRIVAL GROUP BY PO_NO, PO_LINE_NO
)
SELECT
  po.PO_ID, po.PO_LINE_NO, po.COMMIT_DATE, po.IS_RESET, po.IS_UNCONF, po.REQ_QTY::NUMBER(18,3),
  COALESCE(aagg.ASN_COUNT, 0), COALESCE(aagg.ASN_QTY, 0)::NUMBER(18,3),
  COALESCE(gagg.GR_COUNT, 0), COALESCE(gagg.REC, 0)::NUMBER(18,3), COALESCE(gagg.REJ, 0)::NUMBER(18,3),
  COALESCE(xagg.ARR_QTY, 0)::NUMBER(18,3), COALESCE(xagg.ARR_BY_COMMIT, 0)::NUMBER(18,3),
  xagg.FIRST_ARR, xagg.LAST_ARR, cmp.ARRIVAL_LOCAL_DATE, cmp.ARRIVAL_SOURCE,
  COALESCE(xagg.HAS_GRFB, FALSE), COALESCE(aagg.HAS_GAP, FALSE)
FROM po
LEFT JOIN xagg ON xagg.PO_NO = po.PO_ID AND xagg.PO_LINE_NO = po.PO_LINE_NO
LEFT JOIN cmp  ON cmp.PO_NO  = po.PO_ID AND cmp.PO_LINE_NO  = po.PO_LINE_NO
LEFT JOIN gagg ON gagg.PO_ID = po.PO_ID AND gagg.PO_LINE_NO = po.PO_LINE_NO
LEFT JOIN aagg ON aagg.PO_NO = po.PO_ID AND aagg.PO_LINE_NO = po.PO_LINE_NO;

-- -----------------------------------------------------------------------------
-- FACT_PO_LINE (grain: PO_NO + PO_LINE_NO; Supplier OTD %)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SC.CONFORMED.FACT_PO_LINE (
  PO_NO                       COMMENT 'Key part 1: purchase order (commitment to buy from a Supplier for delivery to a Plant).',
  PO_LINE_NO                  COMMENT 'Key part 2: PO line (PurchaseOrderLine extension, ontology.md §6).',
  SUPPLIER_NO                 COMMENT 'Supplier (ERP vendor number) the PO is placed with (R3).',
  PLANT_CODE                  COMMENT 'Receiving (ship-to) plant (R4).',
  SUPPLIER_PART_NO            COMMENT 'Supplier part number on the PO line.',
  PART_NO                     COMMENT 'ERP part resolved through DT_SUPPLIER_PART_XWALK; NULL when unmapped.',
  ITEM_CATEGORY               COMMENT 'STOCK, NON_STOCK or SERVICE. The semantic view keeps STOCK lines only.',
  PO_DATE                     COMMENT 'PO order date (Time role: order date).',
  ORDER_QTY                   COMMENT 'Ordered qty, base UoM.',
  CANCELLED_QTY               COMMENT 'Qty cancelled by our buyer, base UoM.',
  REQUIRED_QTY                COMMENT 'Required qty (§1.1) = ORDER_QTY - CANCELLED_QTY.',
  UNIT_PRICE_AMT              COMMENT 'PO unit price per base UoM in reporting currency (USD).',
  INCOTERM                    COMMENT 'Incoterm of the PO line (EXW, FCA, FOB, CIF, DAP, DDP).',
  DUE_DATE                    COMMENT 'PO requested delivery date (buyer need date). Commit fallback when unconfirmed.',
  FIRST_CONFIRMED_DATE        COMMENT 'First supplier confirmation (EDI 855 / portal).',
  LATEST_CONFIRMED_DATE       COMMENT 'Latest supplier confirmation (basis of Supplier Contractual OTD, not the canonical metric).',
  RESCHEDULE_REASON           COMMENT 'SUPPLIER_DELAY or BUYER_REQUEST; NULL if never rescheduled.',
  FIRST_COMMIT_DATE           COMMENT 'Supplier commit date (§1.1). Time anchor of Supplier OTD %.',
  IS_COMMIT_RESET             COMMENT 'TRUE when a buyer-requested change reset the commit.',
  IS_UNCONFIRMED              COMMENT 'TRUE when the supplier never confirmed (commit = DUE_DATE).',
  LINE_STATUS                 COMMENT 'OPEN or CLOSED in the supplier portal.',
  ASN_COUNT                   COMMENT 'Advance ship notices received for the line.',
  ASN_SHIPPED_QTY             COMMENT 'Qty notified as shipped by the supplier.',
  GR_COUNT                    COMMENT 'Goods receipts posted for the line.',
  RECEIVED_QTY                COMMENT 'Total received qty (before rejects), base UoM.',
  REJECTED_QTY                COMMENT 'Total qty rejected at inspection, base UoM.',
  ARRIVED_QTY                 COMMENT 'Qty of ASNs with arrival evidence (IoT geofence, carrier POD or GR posting), base UoM.',
  ARRIVED_BY_COMMIT_QTY       COMMENT 'Qty arrived by commit date (§1.1): plant-local arrival date <= FIRST_COMMIT_DATE. Uncapped.',
  FIRST_ARRIVAL_LOCAL_DATE    COMMENT 'First arrival, plant-local.',
  LAST_ARRIVAL_LOCAL_DATE     COMMENT 'Last arrival, plant-local.',
  COMPLETE_ARRIVAL_LOCAL_DATE COMMENT 'Complete-arrival date (§1.1), plant-local; NULL while incomplete. The semantic view compares it with the on-time window.',
  COMPLETE_ARRIVAL_SOURCE     COMMENT 'Arrival source of the completing ASN: IOT_GEOFENCE, CARRIER_POD or GR_POSTING (GR_FALLBACK).',
  DQ_FLAGS                    COMMENT 'UNMAPPED_PART, UNCONFIRMED, COMMIT_RESET, GR_FALLBACK (an arrival of the line is the GR posting date), NO_ARRIVAL_EVIDENCE (a shipped ASN has no arrival source), NO_FX_RATE.',
  CONTRACT_NO                 COMMENT 'Governing contract (contract v1.4 §1.1 "Contract terms per PO line"): DIM_SUPPLIER_PART.CONTRACT_NO of the line''s supplier part (R6); NULL = no contract. Lookup only, regardless of contract validity.',
  CONTRACT_LATE_GRACE_DAYS    COMMENT 'Late-delivery grace days of the governing contract, as printed on the signed PDF.',
  CONTRACT_DELIVERY_TARGET_FRACTION COMMENT 'Contracted delivery target of the governing contract, 0-1 fraction (a contract term, not a metric value).',
  CONTRACT_VALID_FROM         COMMENT 'Valid-from date of the governing contract. The semantic view compares it with PO_DATE (in validity vs pro-forma).',
  CONTRACT_VALID_TO           COMMENT 'Valid-to date of the governing contract.'
)
  TARGET_LAG = '1 hour' WAREHOUSE = SC_WH REFRESH_MODE = AUTO
  COMMENT = 'PurchaseOrderLine: one supplier part, quantity and commit on a PO, with §1.1 inbound milestones. Grain for Supplier OTD %. One row per PO_NO + PO_LINE_NO.'
AS
SELECT
  po.PO_ID, po.PO_LINE_NO, x.SUPPLIER_NO, po.SHIP_TO_PLANT_ID, po.SUPPLIER_PART_NO, x.PART_NO, po.ITEM_CATEGORY,
  po.ORDER_DATE, po.QTY_ORDERED::NUMBER(18,3), po.QTY_CANCELLED::NUMBER(18,3), m.REQUIRED_QTY,
  IFF(po.CURRENCY = 'USD', po.UNIT_PRICE, NULL), po.INCOTERM,
  po.DUE_DATE, po.FIRST_CONFIRMED_DATE, po.LATEST_CONFIRMED_DATE, po.RESCHEDULE_REASON,
  m.FIRST_COMMIT_DATE, m.IS_COMMIT_RESET, m.IS_UNCONFIRMED, po.STATUS,
  m.ASN_COUNT, m.ASN_SHIPPED_QTY, m.GR_COUNT, m.RECEIVED_QTY, m.REJECTED_QTY, m.ARRIVED_QTY, m.ARRIVED_BY_COMMIT_QTY,
  m.FIRST_ARRIVAL_LOCAL_DATE, m.LAST_ARRIVAL_LOCAL_DATE, m.COMPLETE_ARRIVAL_LOCAL_DATE, m.COMPLETE_ARRIVAL_SOURCE,
  ARRAY_CAT(COALESCE(x.DQ_FLAGS, ARRAY_CONSTRUCT()), ARRAY_COMPACT(ARRAY_CONSTRUCT(
    IFF(m.IS_UNCONFIRMED, 'UNCONFIRMED', NULL),
    IFF(m.IS_COMMIT_RESET, 'COMMIT_RESET', NULL),
    IFF(m.HAS_GR_FALLBACK, 'GR_FALLBACK', NULL),
    IFF(m.HAS_ARRIVAL_GAP, 'NO_ARRIVAL_EVIDENCE', NULL),
    IFF(po.CURRENCY <> 'USD', 'NO_FX_RATE', NULL)))),
  sp.CONTRACT_NO, c.LATE_GRACE_DAYS, c.DELIVERY_TARGET_FRACTION, c.VALID_FROM, c.VALID_TO
FROM SC.RAW_SUPPLIER.PURCHASE_ORDERS po
JOIN SC.CONFORMED.DT_PO_LINE_MILESTONES m ON m.PO_NO = po.PO_ID AND m.PO_LINE_NO = po.PO_LINE_NO
LEFT JOIN SC.CONFORMED.DT_SUPPLIER_PART_XWALK x
  ON x.SUPPLIER_PORTAL_ID = po.SUPPLIER_ID AND x.SUPPLIER_PART_NO = po.SUPPLIER_PART_NO
LEFT JOIN SC.CONFORMED.DIM_SUPPLIER_PART sp
  ON sp.SUPPLIER_NO = x.SUPPLIER_NO AND sp.SUPPLIER_PART_NO = po.SUPPLIER_PART_NO
LEFT JOIN SC.CONFORMED.DIM_CONTRACT c ON c.CONTRACT_NO = sp.CONTRACT_NO;

-- -----------------------------------------------------------------------------
-- DT_INBOUND_FREIGHT_ALLOC: carrier freight (EDI 210) allocated to ASN lines
--   Load-level linehaul + fuel and accessorials are shared across the lines of a
--   freight invoice by max(actual weight, dimensional weight) (metric_contracts.md
--   §1.1 v1.1). If any line of the invoice lacks a weight, the whole invoice is
--   shared by line value (ASN qty x PO price), flagged ALLOC_BY_VALUE.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SC.CONFORMED.DT_INBOUND_FREIGHT_ALLOC (
  FREIGHT_INVOICE_NO       COMMENT 'Carrier freight invoice (one per consolidated inbound load).',
  INVOICE_LINE_NO          COMMENT 'Line of the freight invoice (one per ASN on the load).',
  LOAD_NO                  COMMENT 'Consolidated inbound load (supplier x plant x ship date).',
  SCAC                     COMMENT 'Carrier that billed the load.',
  ASN_NO                   COMMENT 'ASN carried on this invoice line.',
  CHARGEABLE_WEIGHT_KG     COMMENT 'max(actual weight, dimensional weight) of the line in kg; NULL when a weight is missing.',
  LINE_VALUE_AMT           COMMENT 'ASN qty x PO unit price, reporting currency; allocation key on ALLOC_BY_VALUE.',
  ALLOC_SHARE              COMMENT 'Share of the load charges allocated to this line (0-1; shares of an invoice sum to 1).',
  ALLOC_BASIS              COMMENT 'WEIGHT or ALLOC_BY_VALUE.',
  FREIGHT_AMT              COMMENT 'Allocated linehaul + fuel for the line, reporting currency.',
  ACCESSORIAL_AMT          COMMENT 'Allocated carrier accessorials (demurrage, detention, liftgate) for the line, reporting currency.',
  ACCESSORIAL_TYPE         COMMENT 'Type of the load accessorial.',
  IS_USD                   COMMENT 'TRUE when the invoice is in reporting currency (USD); otherwise amounts are NULL (NO_FX_RATE).'
)
  TARGET_LAG = DOWNSTREAM WAREHOUSE = SC_WH REFRESH_MODE = AUTO
  COMMENT = 'Intermediate: inbound carrier freight allocated from load to ASN line by chargeable weight. One row per freight invoice line (= ASN).'
AS
WITH l AS (
  SELECT f.FREIGHT_INVOICE_ID, f.INVOICE_LINE_NO, f.LOAD_ID, f.SCAC, f.ASN_ID,
         GREATEST(f.ACTUAL_WEIGHT_KG, f.DIM_WEIGHT_KG)                   AS CHG_WT,
         a.QTY_SHIPPED * po.UNIT_PRICE                                    AS LINE_VALUE,
         f.LOAD_LINEHAUL_AMOUNT + f.LOAD_FUEL_AMOUNT                      AS LOAD_FREIGHT,
         f.LOAD_ACCESSORIAL_AMOUNT, f.ACCESSORIAL_TYPE, f.CURRENCY = 'USD' AS IS_USD
  FROM SC.RAW_SUPPLIER.INBOUND_FREIGHT_INVOICES f
  JOIN SC.RAW_SUPPLIER.ASNS a             ON a.ASN_ID = f.ASN_ID
  JOIN SC.RAW_SUPPLIER.PURCHASE_ORDERS po ON po.PO_ID = a.PO_ID AND po.PO_LINE_NO = a.PO_LINE_NO
),
s AS (
  SELECT l.*,
         COUNT_IF(CHG_WT IS NULL) OVER (PARTITION BY FREIGHT_INVOICE_ID) = 0 AS BY_WT,
         SUM(CHG_WT)     OVER (PARTITION BY FREIGHT_INVOICE_ID)              AS INV_WT,
         SUM(LINE_VALUE) OVER (PARTITION BY FREIGHT_INVOICE_ID)              AS INV_VALUE
  FROM l
),
sh AS (
  SELECT s.*, IFF(BY_WT, CHG_WT / NULLIF(INV_WT, 0), LINE_VALUE / NULLIF(INV_VALUE, 0)) AS SHARE
  FROM s
)
SELECT FREIGHT_INVOICE_ID, INVOICE_LINE_NO, LOAD_ID, SCAC, ASN_ID,
       CHG_WT, LINE_VALUE::NUMBER(18,2), SHARE::NUMBER(12,8),
       IFF(BY_WT, 'WEIGHT', 'ALLOC_BY_VALUE'),
       IFF(IS_USD, ROUND(LOAD_FREIGHT * SHARE, 2), NULL)::NUMBER(18,2),
       IFF(IS_USD, ROUND(LOAD_ACCESSORIAL_AMOUNT * SHARE, 2), NULL)::NUMBER(18,2),
       ACCESSORIAL_TYPE, IS_USD
FROM sh;

-- -----------------------------------------------------------------------------
-- FACT_GOODS_RECEIPT (grain: PO line x goods receipt; Landed Cost per Unit inputs)
--   Components only (metric_contracts.md §1.1 v1.1). Totals and the per-unit
--   ratio are computed in the semantic view. One GR per ASN, so ASN-level costs
--   map 1:1 to receipts. Sources per component:
--     price      supplier invoice (else PO price, PROVISIONAL)
--     freight    CIF/DAP/DDP: supplier invoice; EXW/FCA/FOB: allocated carrier invoice
--     accessorial supplier-invoice other charges + allocated carrier accessorials
--     duty       DDP: supplier invoice; other imports: customs entry; domestic: 0
--   Recoverable tax (invoice VAT, import VAT) is not carried.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SC.CONFORMED.FACT_GOODS_RECEIPT (
  GR_NO                   COMMENT 'Key: ERP goods-receipt document.',
  PO_NO                   COMMENT 'Purchase order received against.',
  PO_LINE_NO              COMMENT 'PO line received against.',
  ASN_NO                  COMMENT 'Advance ship notice the receipt matches.',
  SUPPLIER_NO             COMMENT 'Supplier (ERP vendor number).',
  PLANT_CODE              COMMENT 'Receiving plant.',
  PART_NO                 COMMENT 'ERP part (NULL when the supplier part number is unmapped).',
  INCOTERM                COMMENT 'Incoterm of the PO line; decides who pays freight and who clears customs.',
  IS_IMPORT               COMMENT 'TRUE when supplier country differs from the receiving plant country.',
  GR_DOCK_ARRIVAL_DATE    COMMENT 'Dock arrival date recorded on the GR, plant-local (lineage; not a contract arrival source).',
  POSTING_DATE            COMMENT 'GR posting date, plant-local business date. Time anchor of Landed Cost per Unit.',
  ARRIVAL_LOCAL_DATE      COMMENT 'Contract arrival date of the receipt (§1.1), plant-local: IoT geofence, then carrier POD, else GR posting date (GR_FALLBACK).',
  ARRIVAL_SOURCE          COMMENT 'IOT_GEOFENCE, CARRIER_POD or GR_POSTING (GR_FALLBACK), from DT_INBOUND_ARRIVAL.',
  RECEIVED_QTY            COMMENT 'Qty received on the GR, base UoM.',
  REJECTED_QTY            COMMENT 'Qty rejected at inspection, base UoM. No return-to-vendor reversal documents exist in RAW yet.',
  ACCEPTED_QTY            COMMENT 'RECEIVED_QTY - REJECTED_QTY.',
  INVOICE_NO              COMMENT 'Supplier invoice for the ASN; NULL until received.',
  FREIGHT_INVOICE_NO      COMMENT 'Carrier freight invoice covering the ASN (buyer-paid Incoterms); NULL until received.',
  CUSTOMS_ENTRY_NO        COMMENT 'Customs entry for the ASN (non-DDP imports); NULL until filed.',
  UNIT_PRICE_AMT          COMMENT 'Invoiced unit price per base UoM, reporting currency; PO price when the invoice is missing (PROVISIONAL).',
  PRICE_SOURCE            COMMENT 'SUPPLIER_INVOICE or PO_PRICE.',
  FREIGHT_AMT             COMMENT 'Freight for this receipt, reporting currency: supplier-invoiced freight (CIF/DAP/DDP) or carrier freight allocated by chargeable weight (EXW/FCA/FOB). NULL while missing (PROVISIONAL).',
  FREIGHT_SOURCE          COMMENT 'SUPPLIER_INVOICE or CARRIER_INVOICE; NULL when freight is unknown.',
  FREIGHT_ALLOC_BASIS     COMMENT 'Allocation basis from shipment to PO line: SINGLE_LINE (supplier invoice for one ASN), WEIGHT, or ALLOC_BY_VALUE (weight missing).',
  FREIGHT_ALLOC_SHARE     COMMENT 'Share of the load freight allocated to this receipt (1 for SINGLE_LINE).',
  ACCESSORIAL_AMT         COMMENT 'Accessorials, reporting currency: supplier-invoice other charges (expedite, handling, packaging) + allocated carrier accessorials (demurrage, detention, liftgate). NULL when no cost document has arrived.',
  ACCESSORIAL_TYPE        COMMENT 'Types of accessorial charges present, comma-separated.',
  DUTY_AMT                COMMENT 'Non-recoverable duties: DDP supplier-invoice duty; customs-entry duty for other imports; 0 for domestic receipts; NULL for imports without an entry (PROVISIONAL).',
  DUTY_SOURCE             COMMENT 'SUPPLIER_INVOICE, CUSTOMS_ENTRY or DOMESTIC; NULL when unknown.',
  CUSTOMS_VALUE_AMT       COMMENT 'Declared customs value on the entry, reporting currency.',
  INSURANCE_AMT           COMMENT 'Cargo insurance cost. NULL: no source system yet (not counted as PROVISIONAL).',
  IS_PROVISIONAL          COMMENT 'TRUE when price, freight or duty is estimated or missing (contract PROVISIONAL).',
  DQ_FLAGS                COMMENT 'PROVISIONAL, NO_SUPPLIER_INVOICE, NO_FREIGHT_SOURCE, NO_CUSTOMS_ENTRY, ALLOC_BY_VALUE, UNMAPPED_PART, GR_FALLBACK (no IoT / POD arrival for the ASN), NO_FX_RATE.'
)
  TARGET_LAG = '1 hour' WAREHOUSE = SC_WH REFRESH_MODE = AUTO
  COMMENT = 'Goods receipt: one posted receipt of a PO line, with arrival and landed-cost components (no totals or ratios). Grain for Landed Cost per Unit. One row per GR_NO.'
AS
WITH b AS (
  SELECT g.GR_ID, g.PO_ID, g.PO_LINE_NO, g.ASN_ID, g.SHIP_TO_PLANT_ID, g.ARRIVAL_LOCAL_DATE, g.POSTING_DATE,
         g.QTY_RECEIVED, g.QTY_REJECTED, g.QTY_ACCEPTED,
         po.INCOTERM, po.UNIT_PRICE AS PO_PRICE, po.CURRENCY AS PO_CURRENCY,
         x.SUPPLIER_NO, x.PART_NO, x.DQ_FLAGS AS X_FLAGS,
         i.INVOICE_ID, i.UNIT_PRICE AS INV_PRICE, i.FREIGHT_AMOUNT, i.DUTY_AMOUNT, i.OTHER_CHARGES, i.OTHER_CHARGES_TYPE,
         i.CURRENCY AS INV_CURRENCY,
         fa.FREIGHT_INVOICE_NO, fa.FREIGHT_AMT AS CAR_FRT, fa.ACCESSORIAL_AMT AS CAR_ACC, fa.ACCESSORIAL_TYPE AS CAR_ACC_TYPE,
         fa.ALLOC_BASIS, fa.ALLOC_SHARE, fa.IS_USD AS FI_USD,
         ce.ENTRY_ID, ce.DUTY_AMOUNT AS CE_DUTY, ce.CUSTOMS_VALUE, ce.CURRENCY AS CE_CURRENCY,
         s.COUNTRY_CODE AS SUP_COUNTRY, p.COUNTRY_CODE AS PLANT_COUNTRY,
         ia.ARRIVAL_LOCAL_DATE AS ARR_DATE, ia.ARRIVAL_SOURCE AS ARR_SRC
  FROM SC.RAW_SUPPLIER.GOODS_RECEIPTS g
  JOIN SC.RAW_SUPPLIER.PURCHASE_ORDERS po ON po.PO_ID = g.PO_ID AND po.PO_LINE_NO = g.PO_LINE_NO
  LEFT JOIN SC.CONFORMED.DT_SUPPLIER_PART_XWALK x    ON x.SUPPLIER_PORTAL_ID = po.SUPPLIER_ID AND x.SUPPLIER_PART_NO = po.SUPPLIER_PART_NO
  LEFT JOIN SC.RAW_SUPPLIER.SUPPLIER_INVOICES i      ON i.ASN_ID = g.ASN_ID
  LEFT JOIN SC.CONFORMED.DT_INBOUND_FREIGHT_ALLOC fa ON fa.ASN_NO = g.ASN_ID
  LEFT JOIN SC.RAW_SUPPLIER.CUSTOMS_ENTRIES ce       ON ce.ASN_ID = g.ASN_ID
  LEFT JOIN SC.RAW_SUPPLIER.SUPPLIERS s              ON s.SUPPLIER_ID = po.SUPPLIER_ID
  LEFT JOIN SC.RAW_ERP.PLANTS p                      ON p.PLANT_ID = g.SHIP_TO_PLANT_ID
  LEFT JOIN SC.CONFORMED.DT_INBOUND_ARRIVAL ia       ON ia.ASN_NO = g.ASN_ID
),
c AS (
  SELECT b.*,
    b.INVOICE_ID IS NULL                                                    AS NO_INV,
    b.INCOTERM IN ('CIF', 'DAP', 'DDP')                                     AS SUP_PAYS_FREIGHT,
    b.SUP_COUNTRY IS DISTINCT FROM b.PLANT_COUNTRY                         AS IS_IMP,
    COALESCE(b.INV_CURRENCY, b.PO_CURRENCY) = 'USD'
      AND COALESCE(b.FI_USD, TRUE) AND COALESCE(b.CE_CURRENCY, 'USD') = 'USD' AS IS_USD
  FROM b
),
d AS (
  SELECT c.*,
    CASE WHEN SUP_PAYS_FREIGHT AND NOT NO_INV       THEN FREIGHT_AMOUNT
         WHEN NOT SUP_PAYS_FREIGHT                  THEN CAR_FRT END        AS FRT,
    CASE WHEN SUP_PAYS_FREIGHT AND NOT NO_INV       THEN 'SUPPLIER_INVOICE'
         WHEN NOT SUP_PAYS_FREIGHT AND CAR_FRT IS NOT NULL THEN 'CARRIER_INVOICE' END AS FRT_SRC,
    CASE WHEN INCOTERM = 'DDP' AND NOT NO_INV       THEN DUTY_AMOUNT
         WHEN INCOTERM <> 'DDP' AND ENTRY_ID IS NOT NULL THEN CE_DUTY
         WHEN NOT IS_IMP                            THEN 0 END              AS DUTY,
    CASE WHEN INCOTERM = 'DDP' AND NOT NO_INV       THEN 'SUPPLIER_INVOICE'
         WHEN INCOTERM <> 'DDP' AND ENTRY_ID IS NOT NULL THEN 'CUSTOMS_ENTRY'
         WHEN NOT IS_IMP                            THEN 'DOMESTIC' END     AS DUTY_SRC,
    IFF(NO_INV AND CAR_ACC IS NULL, NULL, COALESCE(IFF(NO_INV, NULL, OTHER_CHARGES), 0) + COALESCE(CAR_ACC, 0)) AS ACC
  FROM c
)
SELECT
  GR_ID, PO_ID, PO_LINE_NO, ASN_ID, SUPPLIER_NO, SHIP_TO_PLANT_ID, PART_NO, INCOTERM, IS_IMP,
  ARRIVAL_LOCAL_DATE, POSTING_DATE, COALESCE(ARR_DATE, POSTING_DATE), COALESCE(ARR_SRC, 'GR_POSTING'),
  QTY_RECEIVED::NUMBER(18,3), QTY_REJECTED::NUMBER(18,3), QTY_ACCEPTED::NUMBER(18,3),
  INVOICE_ID, FREIGHT_INVOICE_NO, ENTRY_ID,
  IFF(IS_USD, COALESCE(INV_PRICE, PO_PRICE), NULL)::NUMBER(18,4),
  IFF(NO_INV, 'PO_PRICE', 'SUPPLIER_INVOICE'),
  IFF(IS_USD, FRT, NULL)::NUMBER(18,2),
  FRT_SRC,
  CASE FRT_SRC WHEN 'SUPPLIER_INVOICE' THEN 'SINGLE_LINE' WHEN 'CARRIER_INVOICE' THEN ALLOC_BASIS END,
  CASE FRT_SRC WHEN 'SUPPLIER_INVOICE' THEN 1 WHEN 'CARRIER_INVOICE' THEN ALLOC_SHARE END::NUMBER(12,8),
  IFF(IS_USD, ACC, NULL)::NUMBER(18,2),
  NULLIF(ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(IFF(NO_INV, NULL, OTHER_CHARGES_TYPE), CAR_ACC_TYPE)), ','), ''),
  IFF(IS_USD, DUTY, NULL)::NUMBER(18,2),
  DUTY_SRC,
  IFF(IS_USD, CUSTOMS_VALUE, NULL)::NUMBER(18,2),
  NULL::NUMBER(18,2),
  NO_INV OR FRT IS NULL OR DUTY IS NULL,
  ARRAY_CAT(COALESCE(X_FLAGS, ARRAY_CONSTRUCT()), ARRAY_COMPACT(ARRAY_CONSTRUCT(
    IFF(NO_INV OR FRT IS NULL OR DUTY IS NULL, 'PROVISIONAL', NULL),
    IFF(NO_INV, 'NO_SUPPLIER_INVOICE', NULL),
    IFF(FRT IS NULL, 'NO_FREIGHT_SOURCE', NULL),
    IFF(DUTY IS NULL, 'NO_CUSTOMS_ENTRY', NULL),
    IFF(FRT_SRC = 'CARRIER_INVOICE' AND ALLOC_BASIS = 'ALLOC_BY_VALUE', 'ALLOC_BY_VALUE', NULL),
    IFF(COALESCE(ARR_SRC, 'GR_POSTING') = 'GR_POSTING', 'GR_FALLBACK', NULL),
    IFF(NOT IS_USD, 'NO_FX_RATE', NULL))))
FROM d;

-- -----------------------------------------------------------------------------
-- DT_INVENTORY_DEMAND_WINDOW: DOI demand inputs per plant x part x snapshot date
--   Forecast: latest consensus run on or before the snapshot date, buckets for the
--   28 days after the snapshot. Shipments: ERP goods-issue qty of the part from the
--   plant over the 28 days ending on the snapshot date. Sums only; the semantic
--   view chooses forecast vs fallback and divides.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SC.CONFORMED.DT_INVENTORY_DEMAND_WINDOW (
  PLANT_CODE                COMMENT 'Plant.',
  PART_NO                   COMMENT 'Part.',
  SNAPSHOT_DATE             COMMENT 'Plant-local snapshot date.',
  FORECAST_RUN_DATE         COMMENT 'Consensus forecast run used (latest run on or before SNAPSHOT_DATE); NULL if the pair has no forecast.',
  FORECAST_DAYS_COVERED     COMMENT 'Days of the 28-day forward window covered by buckets of that run (runs are weekly with a 28-day horizon, so usually < 28).',
  FORECAST_QTY_NEXT_28D     COMMENT 'Consensus forecast qty for the covered days of SNAPSHOT_DATE+1 .. SNAPSHOT_DATE+28, base UoM.',
  SHIPPED_QTY_TRAILING_28D  COMMENT 'Actual shipped qty (ERP goods issue) for SNAPSHOT_DATE-27 .. SNAPSHOT_DATE, base UoM.'
)
  TARGET_LAG = DOWNSTREAM WAREHOUSE = SC_WH REFRESH_MODE = AUTO
  COMMENT = 'Intermediate: forward forecast and trailing shipment sums feeding Days of Inventory. One row per plant x part x snapshot date.'
AS
WITH snap AS (
  SELECT DISTINCT i.PLANT_ID, i.PART_ID, CONVERT_TIMEZONE('UTC', p.TIMEZONE, i.SNAPSHOT_TS_UTC)::DATE AS SNAP_DATE
  FROM SC.RAW_IOT.INVENTORY_SNAPSHOTS i JOIN SC.RAW_ERP.PLANTS p ON p.PLANT_ID = i.PLANT_ID
),
runs AS (
  SELECT DISTINCT PLANT_ID, PART_ID, FORECAST_RUN_DATE FROM SC.RAW_IOT.DEMAND_FORECAST
),
pick AS (
  SELECT s.PLANT_ID, s.PART_ID, s.SNAP_DATE, MAX(r.FORECAST_RUN_DATE) AS RUN_DATE
  FROM snap s
  LEFT JOIN runs r ON r.PLANT_ID = s.PLANT_ID AND r.PART_ID = s.PART_ID AND r.FORECAST_RUN_DATE <= s.SNAP_DATE
  GROUP BY s.PLANT_ID, s.PART_ID, s.SNAP_DATE
),
fc AS (
  SELECT k.PLANT_ID, k.PART_ID, k.SNAP_DATE, COUNT(f.FORECAST_DATE) AS DAYS, SUM(f.FORECAST_QTY) AS QTY
  FROM pick k
  JOIN SC.RAW_IOT.DEMAND_FORECAST f
    ON f.PLANT_ID = k.PLANT_ID AND f.PART_ID = k.PART_ID AND f.FORECAST_RUN_DATE = k.RUN_DATE
   AND f.FORECAST_DATE BETWEEN DATEADD(day, 1, k.SNAP_DATE) AND DATEADD(day, 28, k.SNAP_DATE)
  GROUP BY k.PLANT_ID, k.PART_ID, k.SNAP_DATE
),
shipd AS (
  SELECT PLANT_ID, PART_ID_SHIPPED AS PART_ID, SHIP_DATE, SUM(QTY_SHIPPED) AS QTY
  FROM SC.RAW_ERP.ERP_SHIPMENTS GROUP BY PLANT_ID, PART_ID_SHIPPED, SHIP_DATE
),
tr AS (
  SELECT s.PLANT_ID, s.PART_ID, s.SNAP_DATE, SUM(d.QTY) AS QTY
  FROM snap s
  JOIN shipd d ON d.PLANT_ID = s.PLANT_ID AND d.PART_ID = s.PART_ID
              AND d.SHIP_DATE BETWEEN DATEADD(day, -27, s.SNAP_DATE) AND s.SNAP_DATE
  GROUP BY s.PLANT_ID, s.PART_ID, s.SNAP_DATE
)
SELECT k.PLANT_ID, k.PART_ID, k.SNAP_DATE, k.RUN_DATE,
       COALESCE(fc.DAYS, 0),
       IFF(k.RUN_DATE IS NULL, NULL, COALESCE(fc.QTY, 0))::NUMBER(18,3),
       COALESCE(tr.QTY, 0)::NUMBER(18,3)
FROM pick k
LEFT JOIN fc ON fc.PLANT_ID = k.PLANT_ID AND fc.PART_ID = k.PART_ID AND fc.SNAP_DATE = k.SNAP_DATE
LEFT JOIN tr ON tr.PLANT_ID = k.PLANT_ID AND tr.PART_ID = k.PART_ID AND tr.SNAP_DATE = k.SNAP_DATE;

-- -----------------------------------------------------------------------------
-- FACT_INVENTORY_SNAPSHOT (grain: part x plant x plant-local snapshot date)
--   Stock statuses are columns (UNRESTRICTED / BLOCKED / IN_TRANSIT) so demand
--   inputs sit on the same row without fan-out.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SC.CONFORMED.FACT_INVENTORY_SNAPSHOT (
  PART_NO                   COMMENT 'Key part 1: part counted (R15).',
  PLANT_CODE                COMMENT 'Key part 2: plant holding the stock (warehouses summed to plant; RAW is plant-grain).',
  SNAPSHOT_DATE             COMMENT 'Key part 3: plant-local business date of the end-of-day stock position (Time role: snapshot date).',
  SNAPSHOT_TS               COMMENT 'End-of-day snapshot timestamp, UTC (falls on the next UTC day for plants west of UTC).',
  SOURCE_DEVICE_ID          COMMENT 'RFID reader that produced the count.',
  ON_HAND_QTY               COMMENT 'All physical stock incl. blocked, base UoM, floored at 0.',
  UNRESTRICTED_QTY          COMMENT 'Stock with status UNRESTRICTED = on-hand minus blocked, base UoM, floored at 0.',
  BLOCKED_QTY               COMMENT 'Stock with status BLOCKED (quality hold / quarantine), base UoM.',
  IN_TRANSIT_QTY            COMMENT 'Replenishment stock in transit to the plant, base UoM.',
  IS_IN_TRANSIT_OWNED       COMMENT 'TRUE when title to the in-transit stock has passed to us. Assumed TRUE (replenishment / inter-plant transfer); flagged TITLE_ASSUMED.',
  BASE_UOM                  COMMENT 'Unit of all *_QTY columns.',
  FORECAST_RUN_DATE         COMMENT 'Consensus forecast run used for the forward demand window.',
  FORECAST_DAYS_COVERED     COMMENT 'Days of the 28-day forward window covered by that run.',
  FORECAST_QTY_NEXT_28D     COMMENT 'Consensus forecast qty for the covered days after the snapshot, base UoM; NULL when the pair has no forecast.',
  SHIPPED_QTY_TRAILING_28D  COMMENT 'Actual shipped qty over the 28 days ending on the snapshot date (DEMAND_FALLBACK input).',
  DQ_FLAGS                  COMMENT 'NO_FORECAST, PARTIAL_FORECAST_WINDOW, NEGATIVE_STOCK, TITLE_ASSUMED.'
)
  TARGET_LAG = '1 hour' WAREHOUSE = SC_WH REFRESH_MODE = AUTO
  COMMENT = 'InventorySnapshot: stock of a Part at a Plant at end of the plant-local day, by stock status, with Days-of-Inventory demand inputs. One row per PART_NO x PLANT_CODE x SNAPSHOT_DATE.'
AS
SELECT
  i.PART_ID, i.PLANT_ID, d.SNAPSHOT_DATE,
  TIMESTAMP_TZ_FROM_PARTS(YEAR(i.SNAPSHOT_TS_UTC), MONTH(i.SNAPSHOT_TS_UTC), DAY(i.SNAPSHOT_TS_UTC), HOUR(i.SNAPSHOT_TS_UTC), MINUTE(i.SNAPSHOT_TS_UTC), SECOND(i.SNAPSHOT_TS_UTC), 0, 'UTC'),
  i.DEVICE_ID,
  GREATEST(i.ON_HAND_QTY, 0)::NUMBER(18,3),
  GREATEST(i.ON_HAND_QTY - i.BLOCKED_QTY, 0)::NUMBER(18,3),
  GREATEST(i.BLOCKED_QTY, 0)::NUMBER(18,3),
  GREATEST(i.IN_TRANSIT_QTY, 0)::NUMBER(18,3),
  TRUE,
  i.UOM,
  d.FORECAST_RUN_DATE, d.FORECAST_DAYS_COVERED, d.FORECAST_QTY_NEXT_28D, d.SHIPPED_QTY_TRAILING_28D,
  ARRAY_COMPACT(ARRAY_CONSTRUCT(
    IFF(d.FORECAST_RUN_DATE IS NULL, 'NO_FORECAST', NULL),
    IFF(d.FORECAST_RUN_DATE IS NOT NULL AND d.FORECAST_DAYS_COVERED < 28, 'PARTIAL_FORECAST_WINDOW', NULL),
    IFF(i.ON_HAND_QTY < 0 OR i.ON_HAND_QTY - i.BLOCKED_QTY < 0, 'NEGATIVE_STOCK', NULL),
    IFF(i.IN_TRANSIT_QTY > 0, 'TITLE_ASSUMED', NULL)))
FROM SC.RAW_IOT.INVENTORY_SNAPSHOTS i
JOIN SC.RAW_ERP.PLANTS p ON p.PLANT_ID = i.PLANT_ID
JOIN SC.CONFORMED.DT_INVENTORY_DEMAND_WINDOW d
  ON d.PLANT_CODE = i.PLANT_ID AND d.PART_NO = i.PART_ID
 AND d.SNAPSHOT_DATE = CONVERT_TIMEZONE('UTC', p.TIMEZONE, i.SNAPSHOT_TS_UTC)::DATE;

-- -----------------------------------------------------------------------------
-- Status + row counts
-- -----------------------------------------------------------------------------
SHOW DYNAMIC TABLES IN SCHEMA SC.CONFORMED;
SELECT "name" AS DT_NAME, "target_lag", "refresh_mode", "scheduling_state", "data_timestamp", "rows"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) ORDER BY 1;
