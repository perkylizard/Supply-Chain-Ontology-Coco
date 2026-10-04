# AGENTS.md: Supply Chain Ontology (hackathon)

Instructions for every CoCo session in this workspace. Read this before making any change.

## Project goal

ERP, logistics, supplier and IoT systems define the same supply chain metrics differently, so planning, procurement and logistics get different answers. This project builds **one ontology and one set of metric contracts in Snowflake**, implemented once in a semantic view and served through Cortex Agents to Streamlit, Snowflake Intelligence and Slack. That way every surface returns the same number for the same question.

Canonical metrics: **Customer OTD %, Supplier OTD %, Fill Rate %, Days of Inventory, Landed Cost per Unit.**
Unqualified "on-time delivery" / "OTD" **always means Customer OTD %**.

## Source of truth (in priority order)

1. `docs/metric_contracts.md`: binding metric definitions. If code and contract disagree, the code is wrong.
2. `docs/ontology.md`: entities, keys, relationships, hierarchies, synonyms.
3. `docs/architecture.md`: layers, data flow, where logic may live.
4. `docs/conflict_matrix.md`: background on why the persona definitions differ (input to `SC.LEGACY` only).

To change a definition: update the contract first (bump its version), then the semantic view, then the tests.

## File layout

```
AGENTS.md                  this file
docs/
  architecture.md          layers + mermaid data flow
  ontology.md              entities, relationships, hierarchies, synonyms
  metric_contracts.md      canonical metric definitions (binding)
  conflict_matrix.md       persona definitions and why they conflict
sql/
  00_setup.sql             roles, warehouse, database, schemas, stage, grants, tags METRIC_OWNER / CERTIFIED (exists)
  01a_raw_erp.sql          synthetic RAW_ERP data (12 months ending today)      (exists)
  01b_raw_supplier.sql     synthetic RAW_SUPPLIER data (needs 01a)              (exists)
  01c_raw_logistics.sql    synthetic RAW_LOGISTICS data (needs 01a)             (exists)
  01d_raw_iot.sql          synthetic RAW_IOT data (needs 01a, 01c)              (exists)
  01e_raw_inbound_costs.sql inbound freight invoices + customs entries (01a-01c)  (exists)
  01f_raw_inbound_arrivals.sql inbound IoT geofence + carrier POD per ASN (01a-01e) (exists)
  01g_raw_docs_contracts.sql contract PDFs -> RAW_DOCS.CONTRACT_PAGES (AI_PARSE_DOCUMENT) (exists)
  20_conformed.sql         DIM_ / DT_ / FACT_ dynamic tables + DIM_DATE           (exists)
  25_legacy_views.sql      LEGACY persona views (approved rule-1 exception)       (exists)
  30_semantic_view.sql     SV_SUPPLY_CHAIN (DDL; metrics, synonyms, VQRs)        (exists)
  40_agents_contracts.sql  Cortex Search service CSS_CONTRACTS                   (exists)
  40_agents_supply_chain.sql Cortex Agent AGT_SUPPLY_CHAIN + EXPEDITE_PO / FLAG_SUPPLIER tools (exists)
  50_governance.sql        GOVERNANCE: plant row access, masking, certification tags, grants, persona demo users (exists)
  60_ops_dq_contracts.sql  OPS.DQ_CONTRACT_TERMS_RECON (PDF vs supplier system)  (exists)
  60_ops_*.sql             OPS tables, alerts, tasks                            (planned)
tests/
  consistency_tests.sql    consistency test suite                               (exists)
  agent_questions.yaml     benchmark questions + expected semantic-view queries (exists)
app/
  streamlit_app.py         Streamlit UI                                          (planned)
```

SQL files are numbered in run order and must be idempotent (`CREATE ... IF NOT EXISTS` / `CREATE OR REPLACE` / `CREATE OR ALTER`).
**Re-run `sql/50_governance.sql` after re-running `sql/20_conformed.sql`:** `CREATE OR REPLACE DYNAMIC TABLE` drops the row access and masking policies attached in `sql/50` (tests `H1_*` / `H2_*` FAIL until it is re-run). Certification tags live in the `sql/30` DDL and survive its re-runs.

## Snowflake environment

- Database `SC`, warehouse `SC_WH` (XSMALL, auto-suspend 60s). Build as role **`SC_ADMIN`**, the owner of everything in `SC`. Use `ACCOUNTADMIN` only for account-level grants.
- Persona roles `SC_PLANNER`, `SC_PROCUREMENT`, `SC_LOGISTICS` get SELECT on `SEMANTIC` and `AGENTS` only. Never grant them anything on `RAW_*`, `CONFORMED`, `LEGACY`, `OPS` or `GOVERNANCE`.
- Schemas: `RAW_ERP`, `RAW_LOGISTICS`, `RAW_SUPPLIER`, `RAW_IOT`, `RAW_DOCS`, `CONFORMED`, `LEGACY`, `SEMANTIC`, `AGENTS`, `OPS`, `GOVERNANCE` (added 2026-10-04: tags, policies, their mapping tables; SC_ADMIN only).
- Governance (`sql/50_governance.sql`): `RAP_PLANT_ACCESS` on `DIM_PLANT` and the five plant-level facts. SC_ADMIN, SC_PLANNER and SC_PROCUREMENT see all plants; SC_LOGISTICS sees APAC + EMEA (hidden: US01, MX01). SC_LOGISTICS gets supplier / PO unit price as NULL and the contract penalty clause as `***MASKED***`. Penalty sections are not indexed in `CSS_CONTRACTS`, because Cortex Search can't mask per caller. Persona demo users `SC_DEMO_<PERSONA>` (TYPE PERSON, default role = persona) are created without passwords; never write passwords into a file.

## Naming conventions

| Object | Schema | Pattern | Example |
|---|---|---|---|
| Landing table | `RAW_*` | source table name, unprefixed | `RAW_LOGISTICS.CARRIER_EVENT` |
| Intermediate dynamic table | `CONFORMED` | `DT_<ENTITY>_<STEP>` | `DT_SHIPMENT_ARRIVAL` |
| Conformed entity | `CONFORMED` | `DIM_<ENTITY>` | `DIM_SUPPLIER`, `DIM_DATE` |
| Conformed event / grain | `CONFORMED` | `FACT_<PROCESS>` | `FACT_ORDER_LINE`, `FACT_GOODS_RECEIPT` |
| Semantic view | `SEMANTIC` | `SV_<DOMAIN>` | `SV_SUPPLY_CHAIN` |
| Cortex Agent | `AGENTS` | `AGT_<NAME>` | `AGT_SUPPLY_CHAIN` |
| Cortex Search service | `AGENTS` | `CSS_<CORPUS>` | `CSS_CONTRACTS` |
| Legacy persona view | `LEGACY` | `V_<PERSONA>_<METRIC>` | `V_PLANNING_OTD` |
| Governance objects | `GOVERNANCE` | tags by attribute name (`METRIC_OWNER`, `CERTIFIED`); `RAP_*` row access policies, `MASK_*` masking policies, `GOV_*` mapping tables | `GOVERNANCE.RAP_PLANT_ACCESS`, `GOVERNANCE.MASK_PENALTY_CLAUSE`, `GOVERNANCE.GOV_ROLE_PLANT_ACCESS` |
| Ops objects | `OPS` | `TEST_*`, `DQ_*`, `ALERT_*`, `TASK_*`, `GEN_*` (synthetic-data generator state) | `OPS.TEST_RESULTS`, `OPS.GEN_INBOUND_PLAN`, `OPS.ALERT_AGENT_ACTIONS` (audited agent expedite / flag requests) |
| Metric (in the semantic view) | — | contract name, `UPPER_SNAKE` | `CUSTOMER_OTD_PCT`, `SUPPLIER_OTD_PCT`, `FILL_RATE_PCT`, `DAYS_OF_INVENTORY`, `LANDED_COST_PER_UNIT` |

Column conventions:
- **Keys:** natural keys exactly as named in `ontology.md` (`SUPPLIER_NO`, `PART_NO`, `SO_NO`, `LINE_NO`, `SCAC`, …).
- **Suffixes:** `_TS` = `TIMESTAMP_TZ` in UTC; `_LOCAL_DATE` = date in the receiving location's time zone; `_DATE` = business date; `_QTY` = base UoM; `_AMT` = reporting currency.
- **Booleans and flags:** booleans are prefixed `IS_` / `HAS_`; data-quality flags go in a `DQ_FLAGS` array.

## Hard rules

1. **Metric logic lives ONLY in `SC.SEMANTIC.SV_SUPPLY_CHAIN`.** That means on-time windows, in-full tests, population filters, numerators, denominators, ratios, weighting and NULL-on-empty handling.
   - `CONFORMED` may only compute the milestone attributes listed in `metric_contracts.md` §1.1, plus key, UoM, timezone and DQ normalization. No `*_PCT`, `*_RATE`, `*_OTD`, `DAYS_OF_*` or `LANDED_COST*` columns anywhere outside the semantic view.
   - Agents, Streamlit, Slack and notebooks must get numbers from the semantic view (via Cortex Analyst or `SEMANTIC_VIEW()`), never by querying `FACT_*` / `DIM_*` and doing arithmetic themselves.
   - **Approved exception: `SC.LEGACY`** (`sql/25_legacy_views.sql`). Its views deliberately reproduce each team's current, inconsistent OTD and Fill Rate logic from `conflict_matrix.md` §3 as the "before" state of the demo, so metric logic and metric-like columns are allowed there and nowhere else. LEGACY reads `RAW_*` only, its numbers are never canonical, and rule 2 still applies in full.
   - **Approved TEST-ONLY exception (decided 2026-10-03): the golden-record copy in `SC.OPS`.** The golden-record test (`tests/consistency_tests.sql`, section E2) may create the semantic view `SC.OPS.TEST_GOLDEN_SV_SUPPLY_CHAIN` and transient fixtures `SC.OPS.TEST_GOLDEN_*`. The view is cloned at run time from the deployed `SV_SUPPLY_CHAIN` YAML, changing only its base tables (and dropping its verified queries); the fixtures hold the `conflict_matrix.md` §4 RAW rows plus the deployed CONFORMED queries replayed on them. Conditions: created and dropped inside one test run (`E_GOLDEN_FIXTURES_DROPPED` enforces it), never authored or edited by hand, never granted to any role, never used by an agent, app or notebook, and its numbers are never reported. Metric logic still has exactly one source: `sql/30_semantic_view.sql`.
   - Adding any other exception requires an explicit decision recorded here.
2. **`SC.LEGACY` is demo-only.** It must never be a tool or data source for an agent, app, or any object in `CONFORMED`, `SEMANTIC` or `AGENTS`.
3. **Layers flow forward only:** RAW → CONFORMED → SEMANTIC → AGENTS → consumers.
4. **Synonyms:** "on-time delivery" / "OTD" / "on-time" are synonyms of `CUSTOMER_OTD_PCT` only. Never attach them to another metric.
5. **Don't invent definitions.** If a request needs a metric or rule not in `metric_contracts.md`, propose a contract change and ask before implementing it.

## After every change: run the consistency tests

A "change" is any DDL or DML in database `SC`, or any edit under `sql/`, `app/`, `tests/`, or to `docs/metric_contracts.md` / `docs/ontology.md`.

After every change:

```bash
snow sql -f /workspace/tests/consistency_tests.sql
```

- Every test returns one row: `TEST_NAME`, `STATUS` (`PASS` / `FAIL` / `SKIP`), `DETAIL`. Results are also appended to `SC.OPS.TEST_RESULTS`. `SKIP` means the layer under test isn't built yet; replace it with a real test in the change that builds that layer.
- When a new RAW table is added, add its expected row count to section A and its key relationships to section B.
- **Report the results to the user.** Never call a change done while any test is `FAIL`: fix it, or state clearly which test fails and why.
- If you add a metric, entity or surface, add the matching test in the same change.
- **If `tests/consistency_tests.sql` doesn't exist yet**, say so explicitly. Then create it, at minimum covering the objects that exist so far, and run it. Don't skip the step silently.

The suite must cover (see `docs/architecture.md` §6):
1. Every contract metric exists in `SV_SUPPLY_CHAIN` with the contract name and synonyms; "on-time delivery" maps only to `CUSTOMER_OTD_PCT`.
2. Golden records: `conflict_matrix.md` §4 returns Customer OTD = late and Fill Rate = 60%.
3. Logic boundary: no metric-like columns outside `SEMANTIC`, except the approved `LEGACY` exception (`RAW_*` is source data as delivered and is not scanned); LEGACY reads only `RAW_*` and nothing reads LEGACY; no `FACT_` / `DIM_` references in `app/` or agent definitions.
4. Agent answers for `tests/agent_questions.yaml` match the equivalent `SEMANTIC_VIEW()` query.
5. No dynamic table in `FAILED` / `UPSTREAM_FAILED`.
6. Persona roles cannot read `RAW_*`, `CONFORMED`, `LEGACY`, `OPS` or `GOVERNANCE`.
7. RAW integrity summary (section F, recurring data-quality check): orphans per foreign key, duplicate keys, date ranges (fresh and plausible), % split shipments, % of PODs that change date in plant-local time. Planted issues must stay inside their planted band. When a RAW table or foreign key is added, add it to section F.
8. Governance (section H, `sql/50_governance.sql`): row access attached and the role -> plant mapping matches the regions; persona-by-persona values through `SEMANTIC_VIEW()` equal SC_ADMIN's on every visible plant, and a hidden plant gives no rows (not an error), also through the agent; masked fields are masked for SC_LOGISTICS (through the SV, Cortex Search and the agent); certification tags are present; persona grants match the allow-list; the persona demo users are configured.
