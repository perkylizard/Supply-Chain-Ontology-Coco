-- =============================================================================
-- 50_governance.sql
-- SC.GOVERNANCE: who sees which plants, which fields are masked, which metrics are
-- certified, and the persona demo users for Snowflake Intelligence.
--   1. Row access   GOV_ROLE_PLANT_ACCESS (role -> region / plant) + RAP_PLANT_ACCESS on
--                   DIM_PLANT and the plant-level facts (FACT_ORDER_LINE, FACT_SHIPMENT,
--                   FACT_PO_LINE, FACT_GOODS_RECEIPT, FACT_INVENTORY_SNAPSHOT).
--   2. Masking      MASK_SUPPLIER_PRICE (DIM_SUPPLIER_PART / FACT_PO_LINE.UNIT_PRICE_AMT) and
--                   MASK_PENALTY_CLAUSE (DIM_CONTRACT.PENALTY_CLAUSE_TEXT) for SC_LOGISTICS.
--   3. Tags         METRIC_OWNER / CERTIFIED (created in sql/00, assigned in sql/30).
--   4. Grants       defensive revokes; personas get nothing on GOVERNANCE.
--   5. Demo users   SC_DEMO_PLANNER / _PROCUREMENT / _LOGISTICS (no passwords here).
--
-- Policies are evaluated with IS_ROLE_IN_SESSION, so the role hierarchy counts
-- (ACCOUNTADMIN inherits SC_ADMIN) and so do secondary roles: test a persona with
-- USE SECONDARY ROLES NONE. Inside the semantic view and Cortex Analyst the policy
-- sees the caller's roles, so personas get the same filtered rows through
-- SV_SUPPLY_CHAIN and AGT_SUPPLY_CHAIN as through the tables. Dynamic-table refreshes
-- run as the owner SC_ADMIN, which the mapping lets through (no downstream DT reads a
-- protected column, so refresh modes are unchanged).
--
-- RE-RUN AFTER sql/20 (and sql/30, sql/40): CREATE OR REPLACE DYNAMIC TABLE drops the
-- attached policies. The consistency tests (section H) FAIL when one is missing.
-- Run as SC_ADMIN (owner of SC); ACCOUNTADMIN only for the users (section 5).
-- Depends on: sql/00_setup.sql (schema SC.GOVERNANCE), sql/20_conformed.sql.
-- Idempotent: CREATE ... IF NOT EXISTS, ALTER ... SET BODY, attach-if-missing.
-- =============================================================================

USE ROLE SC_ADMIN;
USE WAREHOUSE SC_WH;
USE SCHEMA SC.GOVERNANCE;

-- -----------------------------------------------------------------------------
-- 1. Row access: role -> plants
--    SC_ADMIN, SC_PLANNER, SC_PROCUREMENT: all plants ('*').
--    SC_LOGISTICS: the plants of its logistics region = APAC + EMEA (Pune IN01,
--    Suzhou CN01, Singapore SG01, Stuttgart DE01, Rotterdam NL01, Wroclaw PL01);
--    the NA plants (Memphis US01, Monterrey MX01) are hidden.
--    Region scopes are expanded to plant rows from DIM_PLANT on every run, so the
--    policy is a plain key lookup; re-run this file when a plant is added.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS SC.GOVERNANCE.GOV_ROLE_PLANT_ACCESS (
  ROLE_NAME    VARCHAR NOT NULL COMMENT 'Account role the row grants plant visibility to (matched with IS_ROLE_IN_SESSION, so inherited and secondary roles count).',
  PLANT_CODE   VARCHAR NOT NULL COMMENT 'Visible plant (DIM_PLANT.PLANT_CODE); * = all plants.',
  REGION       VARCHAR NOT NULL COMMENT 'Region scope that granted the plant (DIM_PLANT.REGION); * = all regions.',
  GRANT_BASIS  VARCHAR NOT NULL COMMENT 'ALL_PLANTS or REGION.',
  UPDATED_TS   TIMESTAMP_TZ     COMMENT 'When this file last rebuilt the row (UTC).'
)
COMMENT = 'Row-access mapping for RAP_PLANT_ACCESS: one row per role x visible plant. Rebuilt by sql/50_governance.sql from the region scopes; never granted to personas.';

INSERT OVERWRITE INTO SC.GOVERNANCE.GOV_ROLE_PLANT_ACCESS
WITH scope (ROLE_NAME, REGION) AS (
  SELECT * FROM VALUES ('SC_ADMIN', '*'), ('SC_PLANNER', '*'), ('SC_PROCUREMENT', '*'),
                       ('SC_LOGISTICS', 'APAC'), ('SC_LOGISTICS', 'EMEA')
)
SELECT ROLE_NAME, '*', '*', 'ALL_PLANTS', CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP()) FROM scope WHERE REGION = '*'
UNION ALL
SELECT s.ROLE_NAME, p.PLANT_CODE, p.REGION, 'REGION', CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())
FROM scope s JOIN SC.CONFORMED.DIM_PLANT p ON p.REGION = s.REGION;

CREATE ROW ACCESS POLICY IF NOT EXISTS SC.GOVERNANCE.RAP_PLANT_ACCESS
  AS (PLANT_CODE_ARG VARCHAR) RETURNS BOOLEAN -> FALSE
  COMMENT = 'Plant-level row access: a row is visible when a role in the session is mapped to its plant (or to *) in GOV_ROLE_PLANT_ACCESS.';
ALTER ROW ACCESS POLICY SC.GOVERNANCE.RAP_PLANT_ACCESS SET BODY ->
  EXISTS (SELECT 1 FROM SC.GOVERNANCE.GOV_ROLE_PLANT_ACCESS m
          WHERE (m.PLANT_CODE = '*' OR m.PLANT_CODE = PLANT_CODE_ARG)
            AND IS_ROLE_IN_SESSION(m.ROLE_NAME));

-- attach where missing (ADD fails if the table already carries a row access policy)
EXECUTE IMMEDIATE $$
DECLARE
  c CURSOR FOR SELECT COLUMN1 AS T, COLUMN2 AS C FROM VALUES
    ('DIM_PLANT', 'PLANT_CODE'), ('FACT_ORDER_LINE', 'PLANT_CODE'), ('FACT_SHIPMENT', 'ORIGIN_PLANT_CODE'),
    ('FACT_PO_LINE', 'PLANT_CODE'), ('FACT_GOODS_RECEIPT', 'PLANT_CODE'), ('FACT_INVENTORY_SNAPSHOT', 'PLANT_CODE');
  n_added NUMBER := 0;
  n_has   NUMBER;
  tname   VARCHAR;
  stmt    VARCHAR;
BEGIN
  FOR r IN c DO
    tname := 'SC.CONFORMED.' || r.T;
    SELECT COUNT(*) INTO :n_has
    FROM TABLE(SC.INFORMATION_SCHEMA.POLICY_REFERENCES(REF_ENTITY_NAME => :tname, REF_ENTITY_DOMAIN => 'TABLE'))
    WHERE POLICY_KIND = 'ROW_ACCESS_POLICY' AND POLICY_NAME = 'RAP_PLANT_ACCESS';
    IF (n_has = 0) THEN
      stmt := 'ALTER TABLE ' || tname || ' ADD ROW ACCESS POLICY SC.GOVERNANCE.RAP_PLANT_ACCESS ON (' || r.C || ')';
      EXECUTE IMMEDIATE :stmt;
      n_added := n_added + 1;
    END IF;
  END FOR;
  RETURN 'RAP_PLANT_ACCESS attached to ' || n_added || ' new table(s)';
END;
$$;

-- -----------------------------------------------------------------------------
-- 2. Masking (SC_LOGISTICS): supplier unit price and contract penalty clause text
--    Allow-list: SC_ADMIN, SC_PLANNER, SC_PROCUREMENT see the value; any other role
--    (SC_LOGISTICS) gets NULL / '***MASKED***'.
--    * Supplier unit price: DIM_SUPPLIER_PART.UNIT_PRICE_AMT (catalogue / contract
--      price) and FACT_PO_LINE.UNIT_PRICE_AMT (PO price). Neither is a dimension of
--      SV_SUPPLY_CHAIN today, so this guards the column if one is ever added.
--      NOT masked: FACT_GOODS_RECEIPT.UNIT_PRICE_AMT (invoiced price). It is a
--      landed-cost component inside the metric population and facts; masking it would
--      change Landed Cost per Unit / Uplift % for logistics only (AGENTS.md: same
--      number for the same question). It is not exposed as a dimension.
--    * Penalty clause: DIM_CONTRACT.PENALTY_CLAUSE_TEXT (SV dimension
--      contracts.contract_penalty_clause). Penalty rate, cap and grace days stay visible.
--      Cortex Search CSS_CONTRACTS serves with owner's rights and cannot mask per
--      caller, so DT_CONTRACT_CHUNK no longer indexes penalty sections (sql/20).
--    SET MASKING POLICY ... FORCE replaces an existing assignment (idempotent).
-- -----------------------------------------------------------------------------
CREATE MASKING POLICY IF NOT EXISTS SC.GOVERNANCE.MASK_SUPPLIER_PRICE
  AS (VAL FLOAT) RETURNS FLOAT -> NULL
  COMMENT = 'Supplier / PO unit price: visible to SC_ADMIN, SC_PLANNER, SC_PROCUREMENT; NULL for every other role (SC_LOGISTICS).';
ALTER MASKING POLICY SC.GOVERNANCE.MASK_SUPPLIER_PRICE SET BODY ->
  CASE WHEN IS_ROLE_IN_SESSION('SC_ADMIN') OR IS_ROLE_IN_SESSION('SC_PLANNER') OR IS_ROLE_IN_SESSION('SC_PROCUREMENT')
       THEN VAL ELSE NULL END;

CREATE MASKING POLICY IF NOT EXISTS SC.GOVERNANCE.MASK_PENALTY_CLAUSE
  AS (VAL VARCHAR) RETURNS VARCHAR -> '***MASKED***'
  COMMENT = 'Contract penalty clause text: visible to SC_ADMIN, SC_PLANNER, SC_PROCUREMENT; ***MASKED*** for every other role (SC_LOGISTICS).';
ALTER MASKING POLICY SC.GOVERNANCE.MASK_PENALTY_CLAUSE SET BODY ->
  CASE WHEN IS_ROLE_IN_SESSION('SC_ADMIN') OR IS_ROLE_IN_SESSION('SC_PLANNER') OR IS_ROLE_IN_SESSION('SC_PROCUREMENT')
       THEN VAL ELSE '***MASKED***' END;

ALTER TABLE SC.CONFORMED.DIM_SUPPLIER_PART MODIFY COLUMN UNIT_PRICE_AMT      SET MASKING POLICY SC.GOVERNANCE.MASK_SUPPLIER_PRICE FORCE;
ALTER TABLE SC.CONFORMED.FACT_PO_LINE      MODIFY COLUMN UNIT_PRICE_AMT      SET MASKING POLICY SC.GOVERNANCE.MASK_SUPPLIER_PRICE FORCE;
ALTER TABLE SC.CONFORMED.DIM_CONTRACT      MODIFY COLUMN PENALTY_CLAUSE_TEXT SET MASKING POLICY SC.GOVERNANCE.MASK_PENALTY_CLAUSE FORCE;

-- -----------------------------------------------------------------------------
-- 3. Certification tags SC.GOVERNANCE.METRIC_OWNER / CERTIFIED
--    Created in sql/00_setup.sql and assigned in the SV_SUPPLY_CHAIN DDL (sql/30):
--    tags on semantic-view metrics can only be set by CREATE SEMANTIC VIEW, so they
--    must exist before sql/30 and live in its DDL to survive CREATE OR REPLACE.
--      SV_SUPPLY_CHAIN                               CERTIFIED TRUE           owner SC_ADMIN
--      CUSTOMER_OTD_PCT, FILL_RATE_PCT, DAYS_OF_INVENTORY            TRUE     owner SC_PLANNER
--      SUPPLIER_OTD_PCT, LANDED_COST_PER_UNIT, LANDED_COST_UPLIFT_PCT TRUE    owner SC_PROCUREMENT
--      SUPPLIER_CONTRACTUAL_OTD_PCT / _GAP                 NAMED_VARIANT      owner SC_PROCUREMENT
--    Read them with TAG_REFERENCES('SC.SEMANTIC.SV_SUPPLY_CHAIN!<table>.<metric>', 'SEMANTIC METRIC').
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 4. Grants: personas hold SELECT on SEMANTIC and USAGE on AGENTS objects only
--    (sql/00, sql/40). Policies run with their owner's rights, so personas need
--    nothing on GOVERNANCE; revoke defensively (idempotent, no-op when clean).
--    Tests H4_* assert the persona allow-list, PUBLIC and functional denials.
-- -----------------------------------------------------------------------------
REVOKE ALL PRIVILEGES ON SCHEMA SC.GOVERNANCE FROM ROLE SC_PLANNER;
REVOKE ALL PRIVILEGES ON SCHEMA SC.GOVERNANCE FROM ROLE SC_PROCUREMENT;
REVOKE ALL PRIVILEGES ON SCHEMA SC.GOVERNANCE FROM ROLE SC_LOGISTICS;
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA SC.GOVERNANCE FROM ROLE SC_PLANNER;
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA SC.GOVERNANCE FROM ROLE SC_PROCUREMENT;
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA SC.GOVERNANCE FROM ROLE SC_LOGISTICS;

-- -----------------------------------------------------------------------------
-- 5. Persona demo users for Snowflake Intelligence (SI uses the user's DEFAULT_ROLE).
--    TYPE = PERSON, one persona role each, default warehouse SC_WH, no secondary
--    roles (so the row access / masking result is exactly the persona's).
--    NO PASSWORD in this file: set it by hand (ALTER USER ... SET PASSWORD = '...').
--    The account's built-in authentication policy requires MFA for password sign-in
--    to Snowsight: each demo user enrolls a passkey / authenticator app at first login.
--    Account-level objects -> ACCOUNTADMIN (AGENTS.md). Re-runs re-assert the
--    properties below and never touch passwords or MFA enrolment.
-- -----------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;
CREATE USER IF NOT EXISTS SC_DEMO_PLANNER     TYPE = PERSON;
CREATE USER IF NOT EXISTS SC_DEMO_PROCUREMENT TYPE = PERSON;
CREATE USER IF NOT EXISTS SC_DEMO_LOGISTICS   TYPE = PERSON;
ALTER USER SC_DEMO_PLANNER     SET TYPE = PERSON DEFAULT_ROLE = SC_PLANNER     DEFAULT_WAREHOUSE = SC_WH DEFAULT_SECONDARY_ROLES = ()
  DISPLAY_NAME = 'SC demo - Planner'     COMMENT = 'Persona demo user for Snowflake Intelligence (sql/50_governance.sql). Role SC_PLANNER only.';
ALTER USER SC_DEMO_PROCUREMENT SET TYPE = PERSON DEFAULT_ROLE = SC_PROCUREMENT DEFAULT_WAREHOUSE = SC_WH DEFAULT_SECONDARY_ROLES = ()
  DISPLAY_NAME = 'SC demo - Procurement' COMMENT = 'Persona demo user for Snowflake Intelligence (sql/50_governance.sql). Role SC_PROCUREMENT only.';
ALTER USER SC_DEMO_LOGISTICS   SET TYPE = PERSON DEFAULT_ROLE = SC_LOGISTICS   DEFAULT_WAREHOUSE = SC_WH DEFAULT_SECONDARY_ROLES = ()
  DISPLAY_NAME = 'SC demo - Logistics'   COMMENT = 'Persona demo user for Snowflake Intelligence (sql/50_governance.sql). Role SC_LOGISTICS only.';
GRANT ROLE SC_PLANNER     TO USER SC_DEMO_PLANNER;
GRANT ROLE SC_PROCUREMENT TO USER SC_DEMO_PROCUREMENT;
GRANT ROLE SC_LOGISTICS   TO USER SC_DEMO_LOGISTICS;
USE ROLE SC_ADMIN;

-- -----------------------------------------------------------------------------
-- Verification
-- -----------------------------------------------------------------------------
SELECT ROLE_NAME, LISTAGG(PLANT_CODE, ', ') WITHIN GROUP (ORDER BY PLANT_CODE) AS PLANTS
FROM SC.GOVERNANCE.GOV_ROLE_PLANT_ACCESS GROUP BY 1 ORDER BY 1;
SELECT REF_ENTITY_NAME, REF_COLUMN_NAME, POLICY_NAME, POLICY_KIND, POLICY_STATUS
FROM TABLE(SC.INFORMATION_SCHEMA.POLICY_REFERENCES(POLICY_NAME => 'SC.GOVERNANCE.RAP_PLANT_ACCESS'))
ORDER BY REF_ENTITY_NAME;
SELECT REF_ENTITY_NAME, REF_COLUMN_NAME, POLICY_NAME, POLICY_STATUS
FROM TABLE(SC.INFORMATION_SCHEMA.POLICY_REFERENCES(POLICY_NAME => 'SC.GOVERNANCE.MASK_SUPPLIER_PRICE'))
UNION ALL
SELECT REF_ENTITY_NAME, REF_COLUMN_NAME, POLICY_NAME, POLICY_STATUS
FROM TABLE(SC.INFORMATION_SCHEMA.POLICY_REFERENCES(POLICY_NAME => 'SC.GOVERNANCE.MASK_PENALTY_CLAUSE'));
SELECT OBJECT_NAME, TAG_NAME, TAG_VALUE FROM TABLE(SC.INFORMATION_SCHEMA.TAG_REFERENCES('SC.SEMANTIC.SV_SUPPLY_CHAIN', 'TABLE'))
UNION ALL
SELECT OBJECT_NAME, TAG_NAME, TAG_VALUE FROM TABLE(SC.INFORMATION_SCHEMA.TAG_REFERENCES('SC.SEMANTIC.SV_SUPPLY_CHAIN!PURCHASE_ORDER_LINES.SUPPLIER_CONTRACTUAL_OTD_PCT', 'SEMANTIC METRIC'));
