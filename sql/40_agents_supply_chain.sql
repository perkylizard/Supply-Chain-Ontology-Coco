-- =============================================================================
-- 40_agents_supply_chain.sql
-- SC.AGENTS.AGT_SUPPLY_CHAIN: the one Cortex Agent for planning, procurement and
-- logistics (architecture.md §4). Same agent, same tools, same instructions for
-- every persona, so the same question returns the same number.
--
-- Tools
--   supply_chain_metrics  Cortex Analyst on SC.SEMANTIC.SV_SUPPLY_CHAIN: the ONLY
--                         source of numbers (AGENTS.md hard rule 1).
--   contract_search       Cortex Search SC.AGENTS.CSS_CONTRACTS (sql/40_agents_contracts.sql):
--                         contract wording only, filterable by SUPPLIER_NO / CONTRACT_NO. No
--                         penalty sections (sql/50 item 2): the penalty clause comes from the
--                         semantic view, where it is masked for SC_LOGISTICS.
--   expedite_po           SC.AGENTS.EXPEDITE_PO(po_no, po_line, reason)
--   flag_supplier         SC.AGENTS.FLAG_SUPPLIER(supplier_no, reason, evidence)
--                         Custom tools: no external calls, only an audited request
--                         row in SC.OPS.ALERT_AGENT_ACTIONS (who / when / why). Inputs
--                         are validated through SEMANTIC_VIEW() dimensions (no FACT_ /
--                         DIM_ reads). EXECUTE AS OWNER (SC_ADMIN), so personas get
--                         USAGE on the procedures and nothing on OPS.
--                         Plant access: inside an owner's-rights procedure the row
--                         access policy sees the owner, so both procedures check the
--                         CALLER's session roles (SYS_CONTEXT SNOWFLAKE$SESSION
--                         IS_ROLE_ACTIVATED; needs READ SESSION, sql/00) against
--                         SC.GOVERNANCE.GOV_ROLE_PLANT_ACCESS, the mapping of
--                         RAP_PLANT_ACCESS (sql/50). Not visible -> REJECTED with
--                         reason_code PLANT_NOT_VISIBLE, nothing written, no plant /
--                         supplier details returned. Fails closed if the role
--                         context is unreadable.
--
-- OPS naming: ALERT_* (AGENTS.md naming table). Each row is a request a buyer or
-- supplier manager must act on, i.e. an alert raised through the agent.
-- Depends on: sql/30_semantic_view.sql, sql/40_agents_contracts.sql.
-- Idempotent: CREATE ... IF NOT EXISTS / CREATE OR REPLACE.
-- =============================================================================

USE ROLE SC_ADMIN;
USE WAREHOUSE SC_WH;
USE SCHEMA SC.AGENTS;

-- -----------------------------------------------------------------------------
-- 1. Audit table for agent actions (append-only; never granted to personas)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS SC.OPS.ALERT_AGENT_ACTIONS (
  CONFIRMATION_ID    VARCHAR       NOT NULL COMMENT 'Id returned to the user, e.g. EXP-20261004-1A2B3C / FLG-20261004-1A2B3C.',
  ACTION_TYPE        VARCHAR       NOT NULL COMMENT 'EXPEDITE_PO or FLAG_SUPPLIER.',
  STATUS             VARCHAR       NOT NULL COMMENT 'REQUESTED (no external system is called; a buyer / supplier manager picks it up).',
  PO_NO              VARCHAR                COMMENT 'EXPEDITE_PO: purchase order number.',
  PO_LINE_NO         NUMBER                 COMMENT 'EXPEDITE_PO: PO line number.',
  SUPPLIER_NO        VARCHAR                COMMENT 'Supplier (ERP vendor number) of the PO line or the flagged supplier.',
  SUPPLIER_NAME      VARCHAR                COMMENT 'Supplier name at request time.',
  PLANT_CODE         VARCHAR                COMMENT 'EXPEDITE_PO: receiving plant of the PO line.',
  REASON             VARCHAR       NOT NULL COMMENT 'Why: reason given by the user.',
  EVIDENCE           VARCHAR                COMMENT 'FLAG_SUPPLIER: evidence quoted by the agent (semantic-view numbers, contract clause).',
  REQUESTED_BY_USER  VARCHAR       NOT NULL COMMENT 'Who: Snowflake user that called the tool (CURRENT_USER).',
  SESSION_ID         NUMBER        NOT NULL COMMENT 'Session of the call. Owner''s-rights procedures cannot see the caller''s role; map SESSION_ID to ROLE_NAME in SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY.',
  REQUESTED_TS       TIMESTAMP_TZ  NOT NULL COMMENT 'When (UTC).',
  SOURCE             VARCHAR       NOT NULL COMMENT 'Calling surface, e.g. AGT_SUPPLY_CHAIN.'
)
COMMENT = 'Audited agent action requests (EXPEDITE_PO, FLAG_SUPPLIER) raised through SC.AGENTS.AGT_SUPPLY_CHAIN. Written only by the owner''s-rights procedures in SC.AGENTS; no external calls.';

-- -----------------------------------------------------------------------------
-- 2. Custom tools
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SC.AGENTS.EXPEDITE_PO(PO_NO VARCHAR, PO_LINE VARCHAR, REASON VARCHAR)
  RETURNS VARIANT
  LANGUAGE SQL
  COMMENT = 'Agent tool: request expediting of one PO line. Validates the PO line exists (via SV_SUPPLY_CHAIN), writes one audited row to SC.OPS.ALERT_AGENT_ACTIONS and returns a confirmation id. No external call.'
  EXECUTE AS OWNER
AS
$$
DECLARE
  v_po        VARCHAR := UPPER(TRIM(COALESCE(PO_NO, '')));
  v_line      NUMBER  := TRY_TO_NUMBER(TRIM(COALESCE(PO_LINE, '')));
  v_reason    VARCHAR := TRIM(COALESCE(REASON, ''));
  v_n         NUMBER;
  v_supp_no   VARCHAR;
  v_supp_name VARCHAR;
  v_plant     VARCHAR;
  v_open      BOOLEAN;
  v_visible   NUMBER := 0;
  v_role      VARCHAR;
  v_act       BOOLEAN;
  v_id        VARCHAR;
BEGIN
  IF (LENGTH(v_reason) < 5) THEN
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'error', 'A reason of at least 5 characters is required. Nothing was written.');
  END IF;
  IF (v_po = '' OR v_line IS NULL) THEN
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'error', 'PO_NO (e.g. PO0000001) and a numeric PO_LINE (e.g. 10) are required. Nothing was written.');
  END IF;

  SELECT COUNT(*), MAX(supplier_no), MAX(supplier_name), MAX(plant_code), MAX(po_line_complete_arrival_date) IS NULL
    INTO :v_n, :v_supp_no, :v_supp_name, :v_plant, :v_open
  FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN
         DIMENSIONS purchase_order_lines.po_no, purchase_order_lines.po_line_no,
                    purchase_order_lines.po_line_complete_arrival_date,
                    suppliers.supplier_no, suppliers.supplier_name, plants.plant_code)
  WHERE po_no = :v_po AND po_line_no = :v_line;

  IF (v_n = 0) THEN
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'error', 'PO line ' || v_po || ' / ' || v_line || ' does not exist. Nothing was written.');
  END IF;

  -- caller's plant access (same mapping as RAP_PLANT_ACCESS), evaluated on the caller's session roles:
  -- the roles mapped to the line's plant, each tested with IS_ROLE_ACTIVATED (role must be a bound constant)
  LET rs RESULTSET := (SELECT DISTINCT ROLE_NAME FROM SC.GOVERNANCE.GOV_ROLE_PLANT_ACCESS
                       WHERE PLANT_CODE = '*' OR PLANT_CODE = :v_plant);
  LET c CURSOR FOR rs;
  FOR r IN c DO
    v_role := r.ROLE_NAME;
    SELECT COALESCE(SYS_CONTEXT('SNOWFLAKE$SESSION', 'IS_ROLE_ACTIVATED', :v_role)::BOOLEAN, FALSE) INTO :v_act;
    IF (v_act) THEN v_visible := v_visible + 1; END IF;
  END FOR;
  IF (v_visible = 0) THEN
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason_code', 'PLANT_NOT_VISIBLE',
                            'error', 'PO line ' || v_po || ' / ' || v_line || ' is at a plant your role is not allowed to see, so it cannot be expedited through this tool. Nothing was written.');
  END IF;

  v_id := 'EXP-' || TO_CHAR(CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP()), 'YYYYMMDD') || '-' || UPPER(LEFT(REPLACE(UUID_STRING(), '-', ''), 6));
  INSERT INTO SC.OPS.ALERT_AGENT_ACTIONS
    (CONFIRMATION_ID, ACTION_TYPE, STATUS, PO_NO, PO_LINE_NO, SUPPLIER_NO, SUPPLIER_NAME, PLANT_CODE,
     REASON, EVIDENCE, REQUESTED_BY_USER, SESSION_ID, REQUESTED_TS, SOURCE)
  SELECT :v_id, 'EXPEDITE_PO', 'REQUESTED', :v_po, :v_line, :v_supp_no, :v_supp_name, :v_plant,
         :v_reason, NULL, CURRENT_USER(), CURRENT_SESSION()::NUMBER, CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP()),
         'AGT_SUPPLY_CHAIN';

  RETURN OBJECT_CONSTRUCT('status', 'CONFIRMED', 'confirmation_id', v_id, 'action', 'EXPEDITE_PO',
                          'po_no', v_po, 'po_line_no', v_line, 'supplier_no', v_supp_no, 'supplier_name', v_supp_name,
                          'plant_code', v_plant, 'line_still_open', v_open, 'reason', v_reason,
                          'written_to', 'SC.OPS.ALERT_AGENT_ACTIONS', 'requested_by', CURRENT_USER(),
                          'note', 'Request logged for the buyer; no external system was called.');
EXCEPTION
  WHEN OTHER THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'error', SQLERRM, 'note', 'Nothing was written.');
END;
$$;

CREATE OR REPLACE PROCEDURE SC.AGENTS.FLAG_SUPPLIER(SUPPLIER_NO VARCHAR, REASON VARCHAR, EVIDENCE VARCHAR)
  RETURNS VARIANT
  LANGUAGE SQL
  COMMENT = 'Agent tool: flag a supplier for supplier-performance review. Validates the supplier exists (ERP vendor number or exact name, via SV_SUPPLY_CHAIN), writes one audited row to SC.OPS.ALERT_AGENT_ACTIONS and returns a confirmation id. No external call.'
  EXECUTE AS OWNER
AS
$$
DECLARE
  v_key       VARCHAR := UPPER(TRIM(COALESCE(SUPPLIER_NO, '')));
  v_reason    VARCHAR := TRIM(COALESCE(REASON, ''));
  v_evidence  VARCHAR := NULLIF(TRIM(COALESCE(EVIDENCE, '')), '');
  v_n         NUMBER;
  v_supp_no   VARCHAR;
  v_supp_name VARCHAR;
  v_visible   NUMBER := 0;
  v_role      VARCHAR;
  v_act       BOOLEAN;
  v_id        VARCHAR;
BEGIN
  IF (LENGTH(v_reason) < 5) THEN
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'error', 'A reason of at least 5 characters is required. Nothing was written.');
  END IF;
  IF (v_key = '') THEN
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'error', 'SUPPLIER_NO (ERP vendor number, e.g. 1000011) is required. Nothing was written.');
  END IF;

  SELECT COUNT(*), MAX(supplier_no), MAX(supplier_name)
    INTO :v_n, :v_supp_no, :v_supp_name
  FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN DIMENSIONS suppliers.supplier_no, suppliers.supplier_name)
  WHERE supplier_no = :v_key OR UPPER(supplier_name) = :v_key;

  IF (v_n = 0) THEN
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'error', 'Supplier ' || v_key || ' does not exist. Nothing was written.');
  END IF;
  IF (v_n > 1) THEN
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'error', 'Supplier ' || v_key || ' is ambiguous (' || v_n || ' matches); pass the ERP vendor number. Nothing was written.');
  END IF;

  -- caller's plant access: the supplier must deliver (PO lines) to at least one plant the caller may see,
  -- same mapping as RAP_PLANT_ACCESS, evaluated on the caller's session roles
  LET rs RESULTSET := (
    SELECT DISTINCT m.ROLE_NAME
    FROM (SELECT DISTINCT plant_code
          FROM SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN
                 DIMENSIONS purchase_order_lines.po_no, suppliers.supplier_no, plants.plant_code)
          WHERE supplier_no = :v_supp_no) sp
    JOIN SC.GOVERNANCE.GOV_ROLE_PLANT_ACCESS m ON m.PLANT_CODE = '*' OR m.PLANT_CODE = sp.plant_code);
  LET c CURSOR FOR rs;
  FOR r IN c DO
    v_role := r.ROLE_NAME;
    SELECT COALESCE(SYS_CONTEXT('SNOWFLAKE$SESSION', 'IS_ROLE_ACTIVATED', :v_role)::BOOLEAN, FALSE) INTO :v_act;
    IF (v_act) THEN v_visible := v_visible + 1; END IF;
  END FOR;
  IF (v_visible = 0) THEN
    RETURN OBJECT_CONSTRUCT('status', 'REJECTED', 'reason_code', 'PLANT_NOT_VISIBLE',
                            'error', 'Supplier ' || v_key || ' delivers only to plants your role is not allowed to see, so it cannot be flagged through this tool. Nothing was written.');
  END IF;

  v_id := 'FLG-' || TO_CHAR(CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP()), 'YYYYMMDD') || '-' || UPPER(LEFT(REPLACE(UUID_STRING(), '-', ''), 6));
  INSERT INTO SC.OPS.ALERT_AGENT_ACTIONS
    (CONFIRMATION_ID, ACTION_TYPE, STATUS, PO_NO, PO_LINE_NO, SUPPLIER_NO, SUPPLIER_NAME, PLANT_CODE,
     REASON, EVIDENCE, REQUESTED_BY_USER, SESSION_ID, REQUESTED_TS, SOURCE)
  SELECT :v_id, 'FLAG_SUPPLIER', 'REQUESTED', NULL, NULL, :v_supp_no, :v_supp_name, NULL,
         :v_reason, :v_evidence, CURRENT_USER(), CURRENT_SESSION()::NUMBER, CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP()),
         'AGT_SUPPLY_CHAIN';

  RETURN OBJECT_CONSTRUCT('status', 'CONFIRMED', 'confirmation_id', v_id, 'action', 'FLAG_SUPPLIER',
                          'supplier_no', v_supp_no, 'supplier_name', v_supp_name, 'reason', v_reason, 'evidence', v_evidence,
                          'written_to', 'SC.OPS.ALERT_AGENT_ACTIONS', 'requested_by', CURRENT_USER(),
                          'note', 'Flag logged for supplier-performance review; no external system was called.');
EXCEPTION
  WHEN OTHER THEN
    RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'error', SQLERRM, 'note', 'Nothing was written.');
END;
$$;

GRANT USAGE ON PROCEDURE SC.AGENTS.EXPEDITE_PO(VARCHAR, VARCHAR, VARCHAR)   TO ROLE SC_PLANNER;
GRANT USAGE ON PROCEDURE SC.AGENTS.EXPEDITE_PO(VARCHAR, VARCHAR, VARCHAR)   TO ROLE SC_PROCUREMENT;
GRANT USAGE ON PROCEDURE SC.AGENTS.EXPEDITE_PO(VARCHAR, VARCHAR, VARCHAR)   TO ROLE SC_LOGISTICS;
GRANT USAGE ON PROCEDURE SC.AGENTS.FLAG_SUPPLIER(VARCHAR, VARCHAR, VARCHAR) TO ROLE SC_PLANNER;
GRANT USAGE ON PROCEDURE SC.AGENTS.FLAG_SUPPLIER(VARCHAR, VARCHAR, VARCHAR) TO ROLE SC_PROCUREMENT;
GRANT USAGE ON PROCEDURE SC.AGENTS.FLAG_SUPPLIER(VARCHAR, VARCHAR, VARCHAR) TO ROLE SC_LOGISTICS;

-- -----------------------------------------------------------------------------
-- 3. Agent
-- -----------------------------------------------------------------------------
CREATE OR REPLACE AGENT SC.AGENTS.AGT_SUPPLY_CHAIN
  COMMENT = 'Supply chain agent for planning, procurement and logistics. Numbers only from SC.SEMANTIC.SV_SUPPLY_CHAIN (metric_contracts.md v1.4); contract text from CSS_CONTRACTS; audited expedite / flag requests.'
  PROFILE = '{"display_name": "Supply Chain Metrics", "color": "blue"}'
  FROM SPECIFICATION
$$
models:
  orchestration: claude-sonnet-4-6

orchestration:
  budget:
    seconds: 300
    tokens: 40000

instructions:
  orchestration: |
    You are the one supply chain agent for planning, procurement and logistics users. Every user gets the same tools,
    the same routing and the same number for the same question: never adapt a definition, filter or period to who asks.

    1. NUMBERS. Every number you state (metric values, numerators, denominators, evidence coverage, contract targets,
    snapshot dates, period and data-range dates) comes from supply_chain_metrics in the current turn. Never compute,
    re-derive, average, weight or estimate a metric yourself, never reuse a number from memory or an earlier turn as a
    fresh answer, and never take a metric value from contract_search. NULL or no row from supply_chain_metrics means
    "n/a" (empty population), never 0%.

    2. ROUTING (metric_contracts.md v1.4 section 7), decided before any tool call:
    - "on-time delivery", "OTD", "on-time", "on-time %" with no qualifier = Customer OTD % (CUSTOMER_OTD_PCT), for every user.
    - "supplier / vendor / inbound OTD or on-time" = Supplier OTD % (SUPPLIER_OTD_PCT).
    - "contractual OTD", "OTD vs contract", "below (their) contracted target", "gap to contracted target" = Supplier
      Contractual OTD % and Supplier Contractual OTD Gap: a named variant, not canonical, on calendar months; no period
      named = the last complete calendar month.
    - "fill rate", "unit fill rate" = Fill Rate %. "days of inventory / supply / cover", "days on hand", "DOI", "DOS" =
      Days of Inventory. "landed cost" = Landed Cost per Unit (per part); above part level = Landed Cost Uplift %.

    3. NON-CANONICAL REQUESTS. Not canonical metrics: truck / trailer fill rate, trailer fill, load utilization (Trailer
    Utilization = loaded weight or cube / trailer capacity, an asset-utilization measure, not a fill rate), carrier
    on-time / on-time pickup (Carrier On-Time Arrival), on-time to request, supplier fill rate, DIO / days inventory
    outstanding, freight cost per unit, Ship-On-Time, line / order / first-pass fill rate, customer OTIF scorecards,
    DC days on hand, inventory turns, standard or quoted landed cost, PPV, TCO. For these: do NOT call
    supply_chain_metrics, give no number, and never relabel a canonical number as the requested metric. Explain in one or
    two sentences what the term means and that it is not a canonical metric in the metric contracts (v1.4), then offer the
    closest canonical metric and ask whether the user wants it (truck / trailer fill rate -> Fill Rate %, the share of the
    quantity customers ordered that reached them by our commit date, an outbound order-fulfilment measure; carrier
    on-time -> Customer OTD %; DIO -> Days of Inventory; supplier
    fill rate -> Supplier OTD %; freight cost per unit -> Landed Cost per Unit). A metric absent from the contracts: say it
    is not defined and that adding it needs a metric-contract change; never invent a definition.

    4. CALLING supply_chain_metrics. One request per metric question, in the user's words with the scope made explicit
    (plant, supplier, period); do not turn it into another metric or add filters the user did not ask for. Plants: Pune =
    IN01, Suzhou = CN01, Singapore = SG01, Rotterdam = NL01, Stuttgart = DE01, Wroclaw = PL01, Memphis = US01, Monterrey =
    MX01. "last / this week, month, quarter, year" are fiscal 4-4-5 periods; a calendar month name or explicit dates are
    calendar; no period named = all history, except Days of Inventory (latest snapshot) and Supplier Contractual OTD (last
    complete calendar month). Ask for, with the metric: the period label with its first and last day, the metric's
    evidence coverage, numerator and denominator; for Days of Inventory also the DOI snapshot date; with no period named
    the data range (first and last date covered); for contractual OTD also the contracted target, gap, pro-forma PO lines
    and contract effective date.

    5. CONTRACTS. Use contract_search for contract wording (grace days, delivery-target wording, lead time, Incoterm,
    payment terms, validity). When a supplier is named, filter SUPPLIER_NO to its 7-digit ERP vendor number (from
    supply_chain_metrics; Kronos Castings = 1000011, Vela Polymers = 1000022). Penalty clauses are NOT in
    contract_search: get the penalty clause, penalty per day, penalty cap and grace days with the contract number from
    supply_chain_metrics. For "below contracted target" questions: first get Supplier Contractual OTD % and Gap per
    supplier from supply_chain_metrics; then for each supplier the user names (if none is named but penalties are
    asked, the worst three below target) get its penalty terms from supply_chain_metrics and quote the clause verbatim
    with its CONTRACT_NO. If the clause text comes back as ***MASKED*** or empty, say the clause wording is restricted,
    never reconstruct or paraphrase it, and give only the penalty per day, cap and grace days.

    6. ACTIONS (expedite_po, flag_supplier). They write an audited request (user, UTC timestamp, reason, evidence) to
    SC.OPS.ALERT_AGENT_ACTIONS; no external system is called. Two steps, no exceptions:
    a. In the turn the user asks, do NOT call expedite_po or flag_supplier. Resolve the inputs (PO number and line; or
       supplier_no via supply_chain_metrics). For flag_supplier gather the evidence from supply_chain_metrics: Supplier
       Contractual OTD % vs contracted target for the last complete calendar month, with on-time / due PO lines. Then show
       exactly what will be written: action, PO and line or supplier number and name, reason, evidence, "written to
       SC.OPS.ALERT_AGENT_ACTIONS with your user name and a UTC timestamp", and ask "Shall I write this request? (yes / no)".
    b. Only when the user's next message clearly confirms (yes, confirm, go ahead, do it) call the tool once, with exactly
       the inputs shown. Anything else: write nothing.
    After the call, report the status and the confirmation_id verbatim. On REJECTED or ERROR say that nothing was written and why.
  response: |
    Lead with the answer, then its basis; be concise.
    - Name the metric exactly as in the contracts: Customer OTD %, Supplier OTD %, Fill Rate %, Days of Inventory, Landed
      Cost per Unit, Landed Cost Uplift %, or the variant Supplier Contractual OTD % / Gap. For unqualified OTD say that
      on-time delivery means Customer OTD %.
    - Always state the period: fiscal label with first and last day, e.g. "last month (fiscal FY2026-P09, 24 Aug - 27 Sep
      2026)"; current period: add "through <as-of date>"; calendar period: "Sep 2026, calendar month (1 - 30 Sep 2026), not
      fiscal"; no period named: "all history, <first date> - <last date>"; Days of Inventory: "as of <snapshot date as
      YYYY-MM-DD> (latest snapshot)" or "(last snapshot of <period label>)".
    - Always state the evidence coverage (for Supplier OTD % also the GR-fallback share) and the numerator / denominator.
    - Supplier Contractual OTD % / Gap: say it is the contract-based variant, not the canonical Supplier OTD %; give the
      contracted target and the gap in percentage points; whenever pro-forma PO lines > 0 add, verbatim, "pro-forma:
      contract terms (effective <contract effective date>) applied to earlier PO lines".
    - Penalty clauses: quote the clause text verbatim in quotation marks with supplier, contract number and section, e.g.
      Kronos Castings, contract CTR-S0011-2026, section "2. Late-Delivery Penalty".
    - Formatting: percentages = fraction x 100 with one decimal (0.123456 -> 12.3%); days one decimal; USD two decimals;
      thousands separators; NULL = n/a. Use a table for more than three rows.
    - End with "Source: SC.SEMANTIC.SV_SUPPLY_CHAIN (metric contracts v1.4)" plus the contract number when one is quoted.
    - Do not mention roles or personas; do not speculate about causes the data does not show.
  sample_questions:
    - question: "What was on-time delivery for Pune last month?"
    - question: "Days of supply for plant DE01"
    - question: "Which suppliers are below their contracted OTD target, and what penalty applies to Kronos?"
    - question: "Which suppliers have the lowest supplier OTD this fiscal year?"
    - question: "What is the fill rate by plant this fiscal year?"

tools:
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: supply_chain_metrics
      description: >-
        The ONLY source of numbers. Cortex Analyst over the semantic view SC.SEMANTIC.SV_SUPPLY_CHAIN, which implements
        the binding metric contracts (metric_contracts.md v1.4): Customer OTD %, Supplier OTD %, Fill Rate %,
        Days of Inventory, Landed Cost per Unit, Landed Cost Uplift %, and the named, non-canonical variant
        Supplier Contractual OTD % / Gap; plus contract terms (delivery target, grace days, penalty rates, penalty clause
        text, validity),
        supplier / plant / part / PO-line lookups, period labels and data ranges. Use for every value, count, date range,
        supplier number lookup or existence check. Pass the user's question in their own words plus the scope
        (plant, supplier, period); never ask it for a metric the contracts do not define.
  - tool_spec:
      type: cortex_search
      name: contract_search
      description: >-
        Searches the signed supplier contract PDFs (one chunk per contract section) for wording: grace days,
        delivery-performance target wording, lead time, Incoterm, payment terms, validity. Late-delivery penalty
        sections are not indexed (penalty terms come from supply_chain_metrics).
        Filter by SUPPLIER_NO (7-digit ERP vendor number, e.g. 1000011 = Kronos Castings) whenever a supplier is named,
        or by CONTRACT_NO (e.g. CTR-S0011-2026). Text only: never take metric values (OTD, fill rate, DOI, cost) from it.
  - tool_spec:
      type: generic
      name: expedite_po
      description: >-
        Writes an audited expedite request for ONE purchase order line to SC.OPS.ALERT_AGENT_ACTIONS (user, timestamp,
        reason) and returns a confirmation_id. No external system is called. Validates that the PO line exists and is at a
        plant the user may see; returns status REJECTED otherwise (reason_code PLANT_NOT_VISIBLE: say the PO line is outside
        the user's plant access and nothing was written). Call ONLY after the user has explicitly confirmed the exact request in their latest message.
      input_schema:
        type: object
        properties:
          po_no:
            type: string
            description: "Purchase order number, e.g. PO0000001"
          po_line:
            type: string
            description: "PO line number, e.g. 10"
          reason:
            type: string
            description: "Why the line must be expedited, in the user's words (at least 5 characters)"
        required: [po_no, po_line, reason]
  - tool_spec:
      type: generic
      name: flag_supplier
      description: >-
        Writes an audited supplier-performance flag to SC.OPS.ALERT_AGENT_ACTIONS (user, timestamp, reason, evidence)
        and returns a confirmation_id. No external system is called. Validates that the supplier exists and delivers to a
        plant the user may see; returns status REJECTED otherwise (reason_code PLANT_NOT_VISIBLE). Call ONLY after the user has explicitly confirmed the exact request in their latest message.
      input_schema:
        type: object
        properties:
          supplier_no:
            type: string
            description: "ERP vendor number (7 digits, e.g. 1000011); look it up with supply_chain_metrics if only the name is known"
          reason:
            type: string
            description: "Why the supplier is flagged, in the user's words (at least 5 characters)"
          evidence:
            type: string
            description: "Evidence shown to the user before confirmation: metric name, period label and dates, value, numerator/denominator, contract clause and CONTRACT_NO"
        required: [supplier_no, reason, evidence]

tool_resources:
  supply_chain_metrics:
    semantic_view: SC.SEMANTIC.SV_SUPPLY_CHAIN
    execution_environment:
      type: warehouse
      warehouse: SC_WH
      query_timeout: 120
  contract_search:
    search_service: SC.AGENTS.CSS_CONTRACTS
    max_results: 5
    id_column: CHUNK_ID
    title_column: SECTION_TITLE
    columns_and_descriptions:
      CHUNK_TEXT:
        description: "Contract section text as printed on the signed PDF"
        type: string
        searchable: true
        filterable: false
      SUPPLIER_NO:
        description: "ERP vendor number of the contract counterparty, 7 digits, e.g. 1000011 (Kronos Castings)"
        type: string
        searchable: false
        filterable: true
      CONTRACT_NO:
        description: "Contract number as printed on the PDF, e.g. CTR-S0011-2026"
        type: string
        searchable: false
        filterable: true
      SUPPLIER_NAME:
        description: "Supplier name on the contract"
        type: string
        searchable: false
        filterable: false
      SECTION_TITLE:
        description: "Contract section heading, e.g. 2. Late-Delivery Penalty"
        type: string
        searchable: false
        filterable: false
  expedite_po:
    type: procedure
    identifier: SC.AGENTS.EXPEDITE_PO
    execution_environment:
      type: warehouse
      warehouse: SC_WH
  flag_supplier:
    type: procedure
    identifier: SC.AGENTS.FLAG_SUPPLIER
    execution_environment:
      type: warehouse
      warehouse: SC_WH
$$;

GRANT USAGE ON AGENT SC.AGENTS.AGT_SUPPLY_CHAIN TO ROLE SC_PLANNER;
GRANT USAGE ON AGENT SC.AGENTS.AGT_SUPPLY_CHAIN TO ROLE SC_PROCUREMENT;
GRANT USAGE ON AGENT SC.AGENTS.AGT_SUPPLY_CHAIN TO ROLE SC_LOGISTICS;

-- -----------------------------------------------------------------------------
-- 4. Snowflake Intelligence (Snowsight: AI & ML > Snowflake CoWork, formerly
--    Snowflake Intelligence; https://ai.snowflake.com). Account-level object, so
--    ACCOUNTADMIN (AGENTS.md: ACCOUNTADMIN only for account-level grants).
--    Membership survives CREATE OR REPLACE AGENT; ADD AGENT is not idempotent.
-- -----------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;
CREATE SNOWFLAKE INTELLIGENCE IF NOT EXISTS SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT;
GRANT USAGE ON SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT TO ROLE SC_PLANNER;
GRANT USAGE ON SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT TO ROLE SC_PROCUREMENT;
GRANT USAGE ON SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT TO ROLE SC_LOGISTICS;
EXECUTE IMMEDIATE $$
BEGIN
  ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT ADD AGENT SC.AGENTS.AGT_SUPPLY_CHAIN;
  RETURN 'added';
EXCEPTION
  WHEN OTHER THEN
    IF (SQLERRM ILIKE '%already present%') THEN RETURN 'already present'; END IF;
    RAISE;
END;
$$;
SHOW AGENTS IN SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT;
USE ROLE SC_ADMIN;
