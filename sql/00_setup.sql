-- =============================================================================
-- 00_setup.sql
-- Supply chain (SC) platform bootstrap: roles, warehouse, database, schemas,
-- document stage, and persona grants. Idempotent: safe to re-run.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- -----------------------------------------------------------------------------
-- 1. Roles
--    SC_PLANNER / SC_PROCUREMENT / SC_LOGISTICS -> SC_ADMIN -> ACCOUNTADMIN
-- -----------------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS SC_ADMIN       COMMENT = 'Supply chain platform admin; owns SC database and SC_WH';
CREATE ROLE IF NOT EXISTS SC_PLANNER     COMMENT = 'Supply chain persona: demand / supply planner';
CREATE ROLE IF NOT EXISTS SC_PROCUREMENT COMMENT = 'Supply chain persona: procurement / sourcing';
CREATE ROLE IF NOT EXISTS SC_LOGISTICS   COMMENT = 'Supply chain persona: logistics / transportation';

GRANT ROLE SC_PLANNER     TO ROLE SC_ADMIN;
GRANT ROLE SC_PROCUREMENT TO ROLE SC_ADMIN;
GRANT ROLE SC_LOGISTICS   TO ROLE SC_ADMIN;
GRANT ROLE SC_ADMIN       TO ROLE ACCOUNTADMIN;

-- -----------------------------------------------------------------------------
-- 2. Warehouse
-- -----------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS SC_WH
  WAREHOUSE_SIZE      = 'XSMALL'
  AUTO_SUSPEND        = 60
  AUTO_RESUME         = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT             = 'Supply chain platform warehouse';

GRANT OWNERSHIP ON WAREHOUSE SC_WH TO ROLE SC_ADMIN COPY CURRENT GRANTS;

-- -----------------------------------------------------------------------------
-- 3. Database (ownership handed to SC_ADMIN so it owns everything beneath)
-- -----------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS SC COMMENT = 'Supply chain platform';

GRANT OWNERSHIP ON DATABASE SC        TO ROLE SC_ADMIN COPY CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA   SC.PUBLIC TO ROLE SC_ADMIN COPY CURRENT GRANTS;

-- -----------------------------------------------------------------------------
-- 4. Schemas + stage (created as SC_ADMIN so SC_ADMIN is the owner)
-- -----------------------------------------------------------------------------
USE ROLE SC_ADMIN;
USE WAREHOUSE SC_WH;
USE DATABASE SC;

CREATE SCHEMA IF NOT EXISTS SC.RAW_ERP       COMMENT = 'Raw ERP extracts (orders, inventory, BOM)';
CREATE SCHEMA IF NOT EXISTS SC.RAW_LOGISTICS COMMENT = 'Raw logistics / TMS / carrier data';
CREATE SCHEMA IF NOT EXISTS SC.RAW_SUPPLIER  COMMENT = 'Raw supplier master and performance data';
CREATE SCHEMA IF NOT EXISTS SC.RAW_IOT       COMMENT = 'Raw IoT / sensor telemetry';
CREATE SCHEMA IF NOT EXISTS SC.RAW_DOCS      COMMENT = 'Raw unstructured documents (contracts, etc.)';
CREATE SCHEMA IF NOT EXISTS SC.CONFORMED     COMMENT = 'Cleansed, conformed model';
CREATE SCHEMA IF NOT EXISTS SC.LEGACY        COMMENT = 'Legacy / migrated objects';
CREATE SCHEMA IF NOT EXISTS SC.SEMANTIC      COMMENT = 'Semantic views and consumption layer';
CREATE SCHEMA IF NOT EXISTS SC.AGENTS        COMMENT = 'Cortex agents and supporting objects';
CREATE SCHEMA IF NOT EXISTS SC.OPS           COMMENT = 'Operational / monitoring objects';

-- Server-side encryption is required for Cortex document functions
-- (AI_PARSE_DOCUMENT / AI_EXTRACT) to read staged files.
CREATE STAGE IF NOT EXISTS SC.RAW_DOCS.CONTRACTS
  DIRECTORY  = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT    = 'Supplier / carrier contract documents';

-- -----------------------------------------------------------------------------
-- 5. Persona grants (MANAGE GRANTS needed for future grants -> ACCOUNTADMIN)
--    Personas get: USAGE on SC_WH and SC, and read-only access to SEMANTIC
--    and AGENTS only. No access to RAW_*, CONFORMED, LEGACY, OPS.
-- -----------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;

GRANT USAGE ON WAREHOUSE SC_WH TO ROLE SC_PLANNER;
GRANT USAGE ON WAREHOUSE SC_WH TO ROLE SC_PROCUREMENT;
GRANT USAGE ON WAREHOUSE SC_WH TO ROLE SC_LOGISTICS;

GRANT USAGE ON DATABASE SC TO ROLE SC_PLANNER;
GRANT USAGE ON DATABASE SC TO ROLE SC_PROCUREMENT;
GRANT USAGE ON DATABASE SC TO ROLE SC_LOGISTICS;

-- SC.SEMANTIC (schema USAGE is required to reach the objects)
GRANT USAGE  ON SCHEMA SC.SEMANTIC                           TO ROLE SC_PLANNER;
GRANT USAGE  ON SCHEMA SC.SEMANTIC                           TO ROLE SC_PROCUREMENT;
GRANT USAGE  ON SCHEMA SC.SEMANTIC                           TO ROLE SC_LOGISTICS;
GRANT SELECT ON ALL TABLES            IN SCHEMA SC.SEMANTIC  TO ROLE SC_PLANNER;
GRANT SELECT ON ALL TABLES            IN SCHEMA SC.SEMANTIC  TO ROLE SC_PROCUREMENT;
GRANT SELECT ON ALL TABLES            IN SCHEMA SC.SEMANTIC  TO ROLE SC_LOGISTICS;
GRANT SELECT ON ALL VIEWS             IN SCHEMA SC.SEMANTIC  TO ROLE SC_PLANNER;
GRANT SELECT ON ALL VIEWS             IN SCHEMA SC.SEMANTIC  TO ROLE SC_PROCUREMENT;
GRANT SELECT ON ALL VIEWS             IN SCHEMA SC.SEMANTIC  TO ROLE SC_LOGISTICS;
GRANT SELECT ON ALL SEMANTIC VIEWS    IN SCHEMA SC.SEMANTIC  TO ROLE SC_PLANNER;
GRANT SELECT ON ALL SEMANTIC VIEWS    IN SCHEMA SC.SEMANTIC  TO ROLE SC_PROCUREMENT;
GRANT SELECT ON ALL SEMANTIC VIEWS    IN SCHEMA SC.SEMANTIC  TO ROLE SC_LOGISTICS;
GRANT SELECT ON FUTURE TABLES         IN SCHEMA SC.SEMANTIC  TO ROLE SC_PLANNER;
GRANT SELECT ON FUTURE TABLES         IN SCHEMA SC.SEMANTIC  TO ROLE SC_PROCUREMENT;
GRANT SELECT ON FUTURE TABLES         IN SCHEMA SC.SEMANTIC  TO ROLE SC_LOGISTICS;
GRANT SELECT ON FUTURE VIEWS          IN SCHEMA SC.SEMANTIC  TO ROLE SC_PLANNER;
GRANT SELECT ON FUTURE VIEWS          IN SCHEMA SC.SEMANTIC  TO ROLE SC_PROCUREMENT;
GRANT SELECT ON FUTURE VIEWS          IN SCHEMA SC.SEMANTIC  TO ROLE SC_LOGISTICS;
GRANT SELECT ON FUTURE SEMANTIC VIEWS IN SCHEMA SC.SEMANTIC  TO ROLE SC_PLANNER;
GRANT SELECT ON FUTURE SEMANTIC VIEWS IN SCHEMA SC.SEMANTIC  TO ROLE SC_PROCUREMENT;
GRANT SELECT ON FUTURE SEMANTIC VIEWS IN SCHEMA SC.SEMANTIC  TO ROLE SC_LOGISTICS;

-- SC.AGENTS
GRANT USAGE  ON SCHEMA SC.AGENTS                             TO ROLE SC_PLANNER;
GRANT USAGE  ON SCHEMA SC.AGENTS                             TO ROLE SC_PROCUREMENT;
GRANT USAGE  ON SCHEMA SC.AGENTS                             TO ROLE SC_LOGISTICS;
GRANT SELECT ON ALL TABLES            IN SCHEMA SC.AGENTS    TO ROLE SC_PLANNER;
GRANT SELECT ON ALL TABLES            IN SCHEMA SC.AGENTS    TO ROLE SC_PROCUREMENT;
GRANT SELECT ON ALL TABLES            IN SCHEMA SC.AGENTS    TO ROLE SC_LOGISTICS;
GRANT SELECT ON ALL VIEWS             IN SCHEMA SC.AGENTS    TO ROLE SC_PLANNER;
GRANT SELECT ON ALL VIEWS             IN SCHEMA SC.AGENTS    TO ROLE SC_PROCUREMENT;
GRANT SELECT ON ALL VIEWS             IN SCHEMA SC.AGENTS    TO ROLE SC_LOGISTICS;
GRANT SELECT ON FUTURE TABLES         IN SCHEMA SC.AGENTS    TO ROLE SC_PLANNER;
GRANT SELECT ON FUTURE TABLES         IN SCHEMA SC.AGENTS    TO ROLE SC_PROCUREMENT;
GRANT SELECT ON FUTURE TABLES         IN SCHEMA SC.AGENTS    TO ROLE SC_LOGISTICS;
GRANT SELECT ON FUTURE VIEWS          IN SCHEMA SC.AGENTS    TO ROLE SC_PLANNER;
GRANT SELECT ON FUTURE VIEWS          IN SCHEMA SC.AGENTS    TO ROLE SC_PROCUREMENT;
GRANT SELECT ON FUTURE VIEWS          IN SCHEMA SC.AGENTS    TO ROLE SC_LOGISTICS;

-- Cortex AI functions
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE SC_PLANNER;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE SC_PROCUREMENT;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE SC_LOGISTICS;

-- -----------------------------------------------------------------------------
-- 6. Verification
-- -----------------------------------------------------------------------------
SHOW ROLES LIKE 'SC_%';
SHOW WAREHOUSES LIKE 'SC_WH';
SHOW SCHEMAS IN DATABASE SC;
SHOW STAGES IN SCHEMA SC.RAW_DOCS;
SHOW GRANTS TO ROLE SC_PLANNER;
