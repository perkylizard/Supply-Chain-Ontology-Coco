-- =============================================================================
-- 45_app.sql
-- SC.AGENTS.APP_SUPPLY_CHAIN: the Streamlit in Snowflake app (app/streamlit_app.py),
-- architecture.md §4 "Streamlit". Five pages: The Problem, Ask, One answer every
-- persona, Ontology & contracts, Trust.
--
-- Runtime: container runtime (SYSTEM$ST_CONTAINER_RUNTIME_PY3_11) on the account's
-- default Streamlit pool SYSTEM_COMPUTE_POOL_CPU; SQL runs on SC_WH. The container
-- runtime is required for RESTRICTED CALLER'S RIGHTS (st.connection
-- "snowflake-callers-rights"): every semantic-view query and every agent run executes
-- as the viewer's default role, so RAP_PLANT_ACCESS and the masking policies of
-- sql/50 apply exactly as in Snowflake Intelligence (verified 2026-10-04 with an
-- EXECUTE AS RESTRICTED CALLER probe as SC_LOGISTICS: 6 plants, clause ***MASKED***,
-- agent answer 23.4% for Pune last month = SC_ADMIN's).
--
-- Owner's rights (SC_ADMIN) are used only for the AGENTS.md exceptions recorded on
-- 2026-10-04: SC.LEGACY on "The Problem" and SC.OPS (+ metric tags) on "Trust" /
-- "Ontology & contracts". No caller grant is given on RAW_*, CONFORMED, LEGACY, OPS or
-- GOVERNANCE, so viewer-side queries can never reach them.
--
-- Run with:  snow sql -f /workspace/sql/45_app.sql   (PUT needs a client with the
-- workspace files mounted; re-run after every change under app/).
-- Depends on: sql/00, sql/30, sql/40_agents_contracts.sql, sql/40_agents_supply_chain.sql.
-- Idempotent: CREATE ... IF NOT EXISTS / CREATE OR REPLACE / GRANT.
-- =============================================================================

USE ROLE SC_ADMIN;
USE WAREHOUSE SC_WH;
USE SCHEMA SC.AGENTS;

-- -----------------------------------------------------------------------------
-- 1. Source stage + upload of app/ (the files listed in app/snowflake.yml artifacts)
-- -----------------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS SC.AGENTS.APP_STAGE
  DIRECTORY  = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT    = 'Source files of SC.AGENTS.APP_SUPPLY_CHAIN (uploaded from app/ by sql/45_app.sql). Never granted to personas.';

REMOVE @SC.AGENTS.APP_STAGE/app/;
PUT file:///workspace/app/streamlit_app.py      @SC.AGENTS.APP_STAGE/app/           AUTO_COMPRESS = FALSE OVERWRITE = TRUE;
PUT file:///workspace/app/pyproject.toml        @SC.AGENTS.APP_STAGE/app/           AUTO_COMPRESS = FALSE OVERWRITE = TRUE;
PUT file:///workspace/app/.streamlit/config.toml @SC.AGENTS.APP_STAGE/app/.streamlit/ AUTO_COMPRESS = FALSE OVERWRITE = TRUE;
LIST @SC.AGENTS.APP_STAGE/app/;

-- -----------------------------------------------------------------------------
-- 2. Streamlit object (container runtime) + live version
-- -----------------------------------------------------------------------------
CREATE OR REPLACE STREAMLIT SC.AGENTS.APP_SUPPLY_CHAIN
  FROM '@SC.AGENTS.APP_STAGE/app'
  MAIN_FILE       = 'streamlit_app.py'
  QUERY_WAREHOUSE = SC_WH
  RUNTIME_NAME    = 'SYSTEM$ST_CONTAINER_RUNTIME_PY3_11'
  COMPUTE_POOL    = SYSTEM_COMPUTE_POOL_CPU
  TITLE           = 'Supply Chain - one answer'
  COMMENT         = 'Streamlit app over SV_SUPPLY_CHAIN and AGT_SUPPLY_CHAIN (restricted caller''s rights). Source app/streamlit_app.py, deployed by sql/45_app.sql.';

ALTER STREAMLIT SC.AGENTS.APP_SUPPLY_CHAIN ADD LIVE VERSION FROM LAST;

-- -----------------------------------------------------------------------------
-- 3. Persona access: USAGE on the app (CREATE OR REPLACE drops grants: re-granted here).
--    Personas already hold USAGE on SC, SC.AGENTS, SC_WH (sql/00).
-- -----------------------------------------------------------------------------
GRANT USAGE ON STREAMLIT SC.AGENTS.APP_SUPPLY_CHAIN TO ROLE SC_PLANNER;
GRANT USAGE ON STREAMLIT SC.AGENTS.APP_SUPPLY_CHAIN TO ROLE SC_PROCUREMENT;
GRANT USAGE ON STREAMLIT SC.AGENTS.APP_SUPPLY_CHAIN TO ROLE SC_LOGISTICS;

-- -----------------------------------------------------------------------------
-- 4. Caller grants to the app owner SC_ADMIN (restricted caller's rights). A caller
--    grant gives nothing by itself: it only lets SC_ADMIN-owned RCR executables use a
--    privilege the VIEWER already holds. Allow-list = exactly the persona surface
--    (SEMANTIC + AGENTS + SC_WH) plus Cortex functions in the shared SNOWFLAKE database
--    (DATA_AGENT_RUN; object-level caller grants are not allowed on shared objects, so
--    PROGRAM USAGE on the database). Test I_APP_CALLER_GRANTS_ALLOW_LIST.
--    MANAGE CALLER GRANTS -> ACCOUNTADMIN (account-level, AGENTS.md).
-- -----------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;
GRANT CALLER USAGE  ON WAREHOUSE SC_WH                                              TO ROLE SC_ADMIN;
GRANT CALLER USAGE  ON DATABASE SC                                                  TO ROLE SC_ADMIN;
GRANT CALLER USAGE  ON SCHEMA SC.SEMANTIC                                           TO ROLE SC_ADMIN;
GRANT CALLER USAGE  ON SCHEMA SC.AGENTS                                             TO ROLE SC_ADMIN;
GRANT CALLER SELECT ON SEMANTIC VIEW SC.SEMANTIC.SV_SUPPLY_CHAIN                    TO ROLE SC_ADMIN;
GRANT CALLER USAGE  ON AGENT SC.AGENTS.AGT_SUPPLY_CHAIN                             TO ROLE SC_ADMIN;
GRANT CALLER USAGE  ON CORTEX SEARCH SERVICE SC.AGENTS.CSS_CONTRACTS                TO ROLE SC_ADMIN;
GRANT CALLER USAGE  ON PROCEDURE SC.AGENTS.EXPEDITE_PO(VARCHAR, VARCHAR, VARCHAR)   TO ROLE SC_ADMIN;
GRANT CALLER USAGE  ON PROCEDURE SC.AGENTS.FLAG_SUPPLIER(VARCHAR, VARCHAR, VARCHAR) TO ROLE SC_ADMIN;
GRANT CALLER USAGE         ON DATABASE SNOWFLAKE                                    TO ROLE SC_ADMIN;
GRANT CALLER PROGRAM USAGE ON DATABASE SNOWFLAKE                                    TO ROLE SC_ADMIN;
USE ROLE SC_ADMIN;

-- -----------------------------------------------------------------------------
-- Verification
-- -----------------------------------------------------------------------------
SHOW STREAMLITS LIKE 'APP_SUPPLY_CHAIN' IN SCHEMA SC.AGENTS;
DESCRIBE STREAMLIT SC.AGENTS.APP_SUPPLY_CHAIN;
SHOW GRANTS ON STREAMLIT SC.AGENTS.APP_SUPPLY_CHAIN;
SHOW CALLER GRANTS TO ROLE SC_ADMIN;
-- Open: Snowsight > Projects > Streamlit > "Supply Chain - one answer"
--   (https://app.snowflake.com/<org>/<account>/#/streamlit-apps/SC.AGENTS.APP_SUPPLY_CHAIN)
