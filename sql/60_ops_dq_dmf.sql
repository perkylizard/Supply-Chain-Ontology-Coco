-- =============================================================================
-- 60_ops_dq_dmf.sql
-- Data metric functions (playbook Step 8.3) on the conformed order-line and shipment facts plus a custom
-- DMF for orphan supplier parts. Scheduled DAILY (cron 12:00 UTC), not every few minutes, to save credits
-- (serverless DMF compute). TRIGGER_ON_CHANGES is not used: the facts are dynamic tables refreshed hourly,
-- so a change trigger would run the DMFs up to 24x a day.
--
-- Expectations encode the same rules / planted bands the consistency suite enforces (tests B, F, G):
--   FACT_ORDER_LINE   NULL_COUNT(FIRST_COMMIT_DATE) = 0   every standard line has a commit date (B_COMMIT_DATE_PRESENT)
--                     NULL_COUNT(PLANT_CODE) = 0          every line has a fulfilling plant (R10)
--                     DUPLICATE_COUNT(SOURCE_ORDER_LINE_ID) = 0  one row per source order line (natural key SO_NO + LINE_NO)
--                     FRESHNESS(COMPLETE_ARRIVAL_TS) < 14 days   latest arrival evidence (F_DATES: fresh within 14 days)
--   FACT_SHIPMENT     NULL_COUNT(ARRIVAL_TS) <= 1100      planted NO_ARRIVAL_EVIDENCE ~0.5% of ~110k rows; alert above 1%
--                     NULL_COUNT(SO_NO) = 0               every shipment row links to an order line (R11)
--                     DUPLICATE_COUNT(SHIPMENT_NO) = 0    deduplicated (G_FACT_SHIPMENT_DEDUPED_AND_RECONCILED)
--                     FRESHNESS(ARRIVAL_TS) < 14 days
--   DIM_SUPPLIER_PART SC.OPS.DQ_ORPHAN_SUPPLIER_PART_SHARE <= 3   % of supplier parts mapping to no ERP part
--                     (planted ~2%, same 1-3% band as B2_SUPPLIER_PART_ORPHAN_RATE_1_TO_3_PCT)
-- These are data-quality checks, not metrics: no metric logic here (AGENTS.md hard rule 1).
--
-- DMFs run with the table owner's role (SC_ADMIN), which sees all plants through RAP_PLANT_ACCESS (verified on the
-- first scheduled run, 2026-10-04 12:00 UTC: FACT_SHIPMENT NULL_COUNT(ARRIVAL_TS) = 561, the planted rows).
-- Do NOT judge these facts with SYSTEM$EVALUATE_DATA_QUALITY_EXPECTATIONS: its on-demand evaluation has no role
-- that RAP_PLANT_ACCESS maps (IS_ROLE_IN_SESSION), so it sees 0 fact rows and reports 0 nulls / NULL freshness.
-- Results: SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS / _EXPECTATION_STATUS (SC_ADMIN gets the
-- DATA_QUALITY_MONITORING_VIEWER application role below); shown on the app page Trust and by
-- `python3 tests/step8_harness.py --part dmf`.
--
-- RE-RUN THIS FILE AFTER sql/20_conformed.sql: CREATE OR REPLACE DYNAMIC TABLE drops the DMF associations
-- (like the policies of sql/50).
-- Depends on: sql/00_setup.sql, sql/20_conformed.sql. Idempotent (associations are dropped if present,
-- then added).
-- =============================================================================

-- account-level privileges (AGENTS.md: ACCOUNTADMIN only for account-level grants)
USE ROLE ACCOUNTADMIN;
GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT TO ROLE SC_ADMIN;
GRANT DATABASE ROLE SNOWFLAKE.DATA_METRIC_USER TO ROLE SC_ADMIN;
GRANT APPLICATION ROLE SNOWFLAKE.DATA_QUALITY_MONITORING_VIEWER TO ROLE SC_ADMIN;

USE ROLE SC_ADMIN;
USE WAREHOUSE SC_WH;
USE SCHEMA SC.OPS;

-- -----------------------------------------------------------------------------
-- 1. Custom DMF: share (%) of supplier parts whose PART_NO maps to no ERP part
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DATA METRIC FUNCTION SC.OPS.DQ_ORPHAN_SUPPLIER_PART_SHARE(
    SUPPLIER_PARTS TABLE (PART_NO VARCHAR),
    PARTS          TABLE (PART_NO VARCHAR))
  RETURNS NUMBER(9,2)
  COMMENT = 'Data quality (playbook 8.3): % of supplier-part rows whose PART_NO is NULL or not in the part master (orphan SupplierPart -> Part, ontology R2). Planted ~2% (UNMAPPED_PART); expectation <= 3.'
AS
$$
  SELECT ROUND(100 * COUNT_IF(p.PART_NO IS NULL) / NULLIF(COUNT(*), 0), 2)
  FROM SUPPLIER_PARTS sp
  LEFT JOIN (SELECT DISTINCT PART_NO FROM PARTS) p ON p.PART_NO = sp.PART_NO
$$;

-- -----------------------------------------------------------------------------
-- 2. Daily schedule (before the associations, so new ones follow it immediately)
-- -----------------------------------------------------------------------------
ALTER DYNAMIC TABLE SC.CONFORMED.FACT_ORDER_LINE   SET DATA_METRIC_SCHEDULE = 'USING CRON 0 12 * * * UTC';
ALTER DYNAMIC TABLE SC.CONFORMED.FACT_SHIPMENT     SET DATA_METRIC_SCHEDULE = 'USING CRON 0 12 * * * UTC';
ALTER DYNAMIC TABLE SC.CONFORMED.DIM_SUPPLIER_PART SET DATA_METRIC_SCHEDULE = 'USING CRON 0 12 * * * UTC';

-- -----------------------------------------------------------------------------
-- 3. Associations with expectations (drop if present, then add: idempotent)
-- -----------------------------------------------------------------------------
EXECUTE IMMEDIATE $$
DECLARE
  bindings ARRAY := ARRAY_CONSTRUCT(
    ARRAY_CONSTRUCT('SC.CONFORMED.FACT_ORDER_LINE',   'SNOWFLAKE.CORE.NULL_COUNT',      '(FIRST_COMMIT_DATE)',    'no_missing_commit_date (VALUE = 0)'),
    ARRAY_CONSTRUCT('SC.CONFORMED.FACT_ORDER_LINE',   'SNOWFLAKE.CORE.NULL_COUNT',      '(PLANT_CODE)',           'no_missing_plant (VALUE = 0)'),
    ARRAY_CONSTRUCT('SC.CONFORMED.FACT_ORDER_LINE',   'SNOWFLAKE.CORE.DUPLICATE_COUNT', '(SOURCE_ORDER_LINE_ID)', 'no_duplicate_order_lines (VALUE = 0)'),
    ARRAY_CONSTRUCT('SC.CONFORMED.FACT_ORDER_LINE',   'SNOWFLAKE.CORE.FRESHNESS',       '(COMPLETE_ARRIVAL_TS)',  'arrivals_fresh_14_days (VALUE < 1209600)'),
    ARRAY_CONSTRUCT('SC.CONFORMED.FACT_SHIPMENT',     'SNOWFLAKE.CORE.NULL_COUNT',      '(ARRIVAL_TS)',           'arrival_evidence_gap_under_1_pct (VALUE <= 1100)'),
    ARRAY_CONSTRUCT('SC.CONFORMED.FACT_SHIPMENT',     'SNOWFLAKE.CORE.NULL_COUNT',      '(SO_NO)',                'no_shipment_without_order_line (VALUE = 0)'),
    ARRAY_CONSTRUCT('SC.CONFORMED.FACT_SHIPMENT',     'SNOWFLAKE.CORE.DUPLICATE_COUNT', '(SHIPMENT_NO)',          'no_duplicate_shipments (VALUE = 0)'),
    ARRAY_CONSTRUCT('SC.CONFORMED.FACT_SHIPMENT',     'SNOWFLAKE.CORE.FRESHNESS',       '(ARRIVAL_TS)',           'arrivals_fresh_14_days (VALUE < 1209600)'),
    ARRAY_CONSTRUCT('SC.CONFORMED.DIM_SUPPLIER_PART', 'SC.OPS.DQ_ORPHAN_SUPPLIER_PART_SHARE',
                    '(PART_NO, TABLE(SC.CONFORMED.DIM_PART(PART_NO)))',                                   'orphan_share_max_3_pct (VALUE <= 3)'));
  b ARRAY;
  stmt VARCHAR;
  added NUMBER := 0;
BEGIN
  FOR i IN 0 TO ARRAY_SIZE(bindings) - 1 DO
    b := bindings[i];
    BEGIN
      stmt := 'ALTER DYNAMIC TABLE ' || b[0] || ' DROP DATA METRIC FUNCTION ' || b[1] || ' ON ' || b[2];
      EXECUTE IMMEDIATE :stmt;
    EXCEPTION WHEN OTHER THEN NULL;   -- not associated yet
    END;
    stmt := 'ALTER DYNAMIC TABLE ' || b[0] || ' ADD DATA METRIC FUNCTION ' || b[1] || ' ON ' || b[2] || ' EXPECTATION ' || b[3];
    EXECUTE IMMEDIATE :stmt;
    added := added + 1;
  END FOR;
  RETURN added || ' DMF associations with expectations';
END;
$$;

-- -----------------------------------------------------------------------------
-- 4. Verify: associations (schedule STARTED) and the latest scheduled results
-- -----------------------------------------------------------------------------
SELECT REF_ENTITY_NAME, METRIC_NAME, REF_ARGUMENTS, SCHEDULE, SCHEDULE_STATUS
FROM TABLE(SC.INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(REF_ENTITY_NAME => 'SC.CONFORMED.FACT_ORDER_LINE', REF_ENTITY_DOMAIN => 'TABLE'))
UNION ALL
SELECT REF_ENTITY_NAME, METRIC_NAME, REF_ARGUMENTS, SCHEDULE, SCHEDULE_STATUS
FROM TABLE(SC.INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(REF_ENTITY_NAME => 'SC.CONFORMED.FACT_SHIPMENT', REF_ENTITY_DOMAIN => 'TABLE'))
UNION ALL
SELECT REF_ENTITY_NAME, METRIC_NAME, REF_ARGUMENTS, SCHEDULE, SCHEDULE_STATUS
FROM TABLE(SC.INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(REF_ENTITY_NAME => 'SC.CONFORMED.DIM_SUPPLIER_PART', REF_ENTITY_DOMAIN => 'TABLE'));

-- Latest SCHEDULED measurement per association. Manual calls (SNOWFLAKE.CORE.NULL_COUNT(SELECT ...)) and
-- SYSTEM$EVALUATE_DATA_QUALITY_EXPECTATIONS evaluate the row-access-protected facts with no mapped role and see 0
-- rows (verified 2026-10-04: 0 nulls / NULL freshness vs 561 / 126060 s scheduled), so only scheduled results count.
SELECT r.TABLE_NAME, r.METRIC_NAME, ARRAY_TO_STRING(r.ARGUMENT_NAMES, ', ') AS ARGUMENTS, r.VALUE::VARCHAR AS VALUE,
       e.EXPECTATION_NAME, e.EXPECTATION_EXPRESSION, e.EXPECTATION_VIOLATED, r.MEASUREMENT_TIME
FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS r
LEFT JOIN SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_EXPECTATION_STATUS e
  ON e.REFERENCE_ID = r.REFERENCE_ID AND e.MEASUREMENT_TIME = r.MEASUREMENT_TIME
WHERE r.TABLE_DATABASE = 'SC'
QUALIFY RANK() OVER (PARTITION BY r.TABLE_NAME, r.METRIC_NAME, ARRAY_TO_STRING(r.ARGUMENT_NAMES, ',') ORDER BY r.MEASUREMENT_TIME DESC) = 1
ORDER BY r.TABLE_NAME, r.METRIC_NAME, ARGUMENTS;

-- DIM_SUPPLIER_PART has no row access policy, so an on-demand evaluation of its custom DMF is valid:
SELECT METRIC_NAME, EXPECTATION_NAME, VALUE, EXPECTATION_VIOLATED
FROM TABLE(SYSTEM$EVALUATE_DATA_QUALITY_EXPECTATIONS(REF_ENTITY_NAME => 'SC.CONFORMED.DIM_SUPPLIER_PART'));
