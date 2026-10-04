-- =============================================================================
-- 40_agents_contracts.sql
-- SC.AGENTS.CSS_CONTRACTS: Cortex Search over the signed contract PDFs, the
-- "what does the contract say" tool of AGT_SUPPLY_CHAIN (architecture.md §4).
-- Source: SC.CONFORMED.DT_CONTRACT_CHUNK (sql/20_conformed.sql), the parsed PDF
-- text (RAW_DOCS.CONTRACT_PAGES, sql/01g) split by Markdown section, one chunk per
-- section, each with its file path, page, CONTRACT_NO and SUPPLIER_NO. Layers flow
-- forward: AGENTS reads CONFORMED only.
-- Filter attributes: SUPPLIER_NO (ERP vendor number), CONTRACT_NO.
-- Contract text only: numbers (OTD, fill rate, landed cost ...) always come from
-- SC.SEMANTIC.SV_SUPPLY_CHAIN, never from this service.
-- Depends on: sql/20_conformed.sql. Idempotent (CREATE OR REPLACE).
-- =============================================================================

USE ROLE SC_ADMIN;
USE WAREHOUSE SC_WH;
USE SCHEMA SC.AGENTS;

CREATE OR REPLACE CORTEX SEARCH SERVICE SC.AGENTS.CSS_CONTRACTS
  ON CHUNK_TEXT
  PRIMARY KEY (CHUNK_ID)
  ATTRIBUTES SUPPLIER_NO, CONTRACT_NO
  WAREHOUSE = SC_WH
  TARGET_LAG = '1 day'
  COMMENT = 'Cortex Search over signed supplier contract PDFs, one chunk per contract section. Filter by SUPPLIER_NO (ERP vendor number) or CONTRACT_NO. Text only; metrics come from SV_SUPPLY_CHAIN.'
AS
SELECT CHUNK_ID, CHUNK_TEXT, SUPPLIER_NO, CONTRACT_NO,
       SUPPLIER_NAME, SECTION_TITLE, DOC_FILE_PATH, FILE_NAME, PAGE_INDEX::VARCHAR AS PAGE_INDEX
FROM SC.CONFORMED.DT_CONTRACT_CHUNK;

-- Personas query the service (architecture.md §5: SELECT alone does not allow it).
-- The service serves its own index, so this grants nothing on CONFORMED or RAW_*.
GRANT USAGE ON CORTEX SEARCH SERVICE SC.AGENTS.CSS_CONTRACTS TO ROLE SC_PLANNER;
GRANT USAGE ON CORTEX SEARCH SERVICE SC.AGENTS.CSS_CONTRACTS TO ROLE SC_PROCUREMENT;
GRANT USAGE ON CORTEX SEARCH SERVICE SC.AGENTS.CSS_CONTRACTS TO ROLE SC_LOGISTICS;

-- Smoke test: top 3 chunks for a clause, then the same restricted to one supplier
SELECT f.VALUE:SUPPLIER_NAME::VARCHAR AS SUPPLIER_NAME, f.VALUE:SECTION_TITLE::VARCHAR AS SECTION_TITLE,
       f.VALUE:DOC_FILE_PATH::VARCHAR AS DOC_FILE_PATH, f.VALUE:CHUNK_TEXT::VARCHAR AS CHUNK_TEXT
FROM TABLE(FLATTEN(PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW('SC.AGENTS.CSS_CONTRACTS',
  '{"query": "penalty for late delivery", "columns": ["SUPPLIER_NO", "CONTRACT_NO", "SUPPLIER_NAME", "SECTION_TITLE", "DOC_FILE_PATH", "CHUNK_TEXT"], "limit": 3}')):results)) f;
