-- =============================================================================
-- 01g_raw_docs_contracts.sql
-- Lands the contract PDFs on @SC.RAW_DOCS.CONTRACTS (uploaded by contract_gen.ipynb)
-- as parsed text: one row per file x page, via AI_PARSE_DOCUMENT (LAYOUT mode,
-- page_split, Markdown output).
-- Depends on: sql/00_setup.sql (stage). Touches no other RAW table.
-- Idempotent and incremental: only files that are new or whose MD5 changed are
-- parsed; rows of files removed from the stage or replaced are deleted first.
-- The signed PDF is the legal source of the Contract entity (ontology.md §1).
-- =============================================================================

USE ROLE SC_ADMIN;
USE WAREHOUSE SC_WH;
USE SCHEMA SC.RAW_DOCS;
ALTER SESSION SET TIMEZONE = 'UTC';

ALTER STAGE SC.RAW_DOCS.CONTRACTS REFRESH;

CREATE TABLE IF NOT EXISTS SC.RAW_DOCS.CONTRACT_PAGES (
  RELATIVE_PATH       VARCHAR        COMMENT 'Path of the PDF on @SC.RAW_DOCS.CONTRACTS (file key).',
  FILE_NAME           VARCHAR        COMMENT 'File name without folders.',
  FILE_MD5            VARCHAR        COMMENT 'MD5 of the staged file when parsed; a changed MD5 triggers a re-parse.',
  FILE_SIZE           NUMBER         COMMENT 'File size in bytes.',
  FILE_LAST_MODIFIED  TIMESTAMP_TZ   COMMENT 'Last-modified timestamp of the staged file.',
  PAGE_COUNT          NUMBER         COMMENT 'Pages in the document (AI_PARSE_DOCUMENT metadata.pageCount).',
  PAGE_INDEX          NUMBER         COMMENT 'Page index, 0-based (AI_PARSE_DOCUMENT pages[].index). NULL when parsing failed.',
  PAGE_TEXT           VARCHAR        COMMENT 'Parsed page content, Markdown (LAYOUT mode).',
  PARSE_MODE          VARCHAR        COMMENT 'AI_PARSE_DOCUMENT mode used.',
  PARSE_ERROR         VARCHAR        COMMENT 'AI_PARSE_DOCUMENT error message; NULL on success.',
  _SOURCE_FILE        VARCHAR        COMMENT 'Full stage path of the source file (load metadata).',
  _LOADED_TS          TIMESTAMP_TZ   COMMENT 'When the row was loaded (load metadata).'
)
COMMENT = 'Contract PDFs parsed with AI_PARSE_DOCUMENT (LAYOUT, page_split). One row per RELATIVE_PATH x PAGE_INDEX. Legal source of the Contract entity.';

-- files removed from the stage, or replaced by a new version
DELETE FROM SC.RAW_DOCS.CONTRACT_PAGES p
WHERE NOT EXISTS (SELECT 1 FROM DIRECTORY(@SC.RAW_DOCS.CONTRACTS) d
                  WHERE d.RELATIVE_PATH = p.RELATIVE_PATH AND d.MD5 = p.FILE_MD5);

-- new or changed files
INSERT INTO SC.RAW_DOCS.CONTRACT_PAGES
WITH todo AS (
  SELECT d.RELATIVE_PATH, d.MD5, d.SIZE, d.LAST_MODIFIED
  FROM DIRECTORY(@SC.RAW_DOCS.CONTRACTS) d
  WHERE REGEXP_LIKE(d.RELATIVE_PATH, '.*\\.pdf$', 'i')
    AND NOT EXISTS (SELECT 1 FROM SC.RAW_DOCS.CONTRACT_PAGES p
                    WHERE p.RELATIVE_PATH = d.RELATIVE_PATH AND p.FILE_MD5 = d.MD5)
),
parsed AS (
  SELECT t.*,
         AI_PARSE_DOCUMENT(TO_FILE('@SC.RAW_DOCS.CONTRACTS', t.RELATIVE_PATH),
                           {'mode': 'LAYOUT', 'page_split': TRUE}, TRUE) AS R
  FROM todo t
)
SELECT p.RELATIVE_PATH,
       REGEXP_SUBSTR(p.RELATIVE_PATH, '[^/]+$'),
       p.MD5,
       p.SIZE,
       p.LAST_MODIFIED,
       p.R:metadata:pageCount::NUMBER,
       pg.VALUE:index::NUMBER,
       pg.VALUE:content::VARCHAR,
       'LAYOUT',
       p.R:error::VARCHAR,
       '@SC.RAW_DOCS.CONTRACTS/' || p.RELATIVE_PATH,
       CURRENT_TIMESTAMP()
FROM parsed p,
     LATERAL FLATTEN(INPUT => p.R:value:pages, OUTER => TRUE) pg;

SELECT RELATIVE_PATH, PAGE_COUNT, PAGE_INDEX, LENGTH(PAGE_TEXT) AS CHARS, PARSE_ERROR
FROM SC.RAW_DOCS.CONTRACT_PAGES ORDER BY RELATIVE_PATH, PAGE_INDEX;
