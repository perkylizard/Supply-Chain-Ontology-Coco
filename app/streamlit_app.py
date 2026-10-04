# app/streamlit_app.py
# Supply Chain: one answer. Streamlit in Snowflake (container runtime), deployed as
# SC.AGENTS.APP_SUPPLY_CHAIN by sql/45_app.sql.
#
# Where numbers come from (AGENTS.md hard rule 1):
#   * every metric value comes from SEMANTIC_VIEW(SC.SEMANTIC.SV_SUPPLY_CHAIN ...) or from the
#     agent SC.AGENTS.AGT_SUPPLY_CHAIN (SNOWFLAKE.CORTEX.DATA_AGENT_RUN). Python only formats.
#   * both run on the restricted caller's rights connection, so row access and masking of the
#     viewer's (default) role apply, exactly as in Snowflake Intelligence.
#   * owner's rights (SC_ADMIN) are used only for the approved exceptions recorded in AGENTS.md:
#     the LEGACY "before" numbers on "The Problem", and OPS (suite results, Step 8 harness results,
#     agent audit log, contract-terms recon), data metric function results and metric tags on
#     "Trust" / "Ontology & contracts".
# This file must not reference the layers below SEMANTIC (enforced by tests/consistency_tests.sql, section E).
import json
import os
import re

import pandas as pd
import streamlit as st

st.set_page_config(page_title="Supply Chain - one answer", page_icon=":material/hub:", layout="wide")

SV = "SC.SEMANTIC.SV_SUPPLY_CHAIN"
AGENT = "SC.AGENTS.AGT_SUPPLY_CHAIN"
CONTRACT_VERSION = "v1.4"

# Connections. The caller's-rights token is only valid for a short time after the session
# starts, so both connections are created at the top of the script (Snowflake docs).
owner = st.connection("snowflake", ttl=os.getenv("SNOWFLAKE_CONNECTION_TTL"))
try:
    caller = st.connection("snowflake-callers-rights")
    CALLER_ERROR = None
except Exception as e:  # warehouse runtime or local run: no restricted caller's rights
    caller = None
    CALLER_ERROR = str(e)
metrics_conn = caller if caller is not None else owner
RIGHTS = "restricted caller's rights (your role)" if caller is not None else "owner's rights (SC_ADMIN) - caller's rights unavailable"

st.markdown(
    """
    <style>
      .block-container {padding-top: 2rem; max-width: 1250px;}
      .sc-sub {color: #52606D; font-size: 1.02rem; margin-top: -0.6rem; margin-bottom: 1.2rem;}
      .sc-kicker {text-transform: uppercase; letter-spacing: .06em; font-size: .75rem; color: #829AB1; font-weight: 600;}
      .sc-big {font-size: 2.3rem; font-weight: 700; line-height: 1.1; color: #1F2A37;}
      .sc-big.canon {color: #11567F;}
      .sc-basis {color: #52606D; font-size: .88rem; margin-top: .35rem;}
      .sc-src {color: #829AB1; font-size: .78rem; margin-top: .5rem;}
    </style>
    """,
    unsafe_allow_html=True,
)


# -----------------------------------------------------------------------------
# Query helpers
# -----------------------------------------------------------------------------
def _execute(conn, sql, params=None):
    cur = conn.cursor()
    try:
        # bound parameters are written as qmark (?); switch if the connector uses pyformat
        if params is not None and getattr(cur.connection, "_paramstyle", "qmark") in ("pyformat", "format"):
            sql = sql.replace("?", "%s")
        cur.execute(sql, params)
        cols = [c[0] for c in cur.description] if cur.description else []
        return pd.DataFrame(cur.fetchall(), columns=cols)
    finally:
        cur.close()


def q_metrics(sql, params=None):
    """Semantic-view / agent-side queries as the viewer. Memoised per browser session only,
    never in a global cache, because results differ by caller (row access, masking)."""
    memo = st.session_state.setdefault("_memo", {})
    key = (sql, json.dumps(params, default=str))
    if key not in memo:
        memo[key] = _execute(metrics_conn, sql, params)
    return memo[key]


@st.cache_data(ttl=300, show_spinner=False)
def q_owner(sql, params=None):
    """Owner's-rights queries (approved exceptions only; same result for every viewer)."""
    return _execute(owner, sql, params)


def clear_caches():
    st.session_state.pop("_memo", None)
    q_owner.clear()


def safe(fn, *args):
    try:
        return fn(*args), None
    except Exception as e:
        return None, str(e)


def pct(v, digits=1):
    try:
        return "n/a" if v is None or pd.isna(v) else f"{float(v) * 100:.{digits}f}%"
    except (TypeError, ValueError):
        return "n/a"


def days(v):
    try:
        return "n/a" if v is None or pd.isna(v) else f"{float(v):.1f} days"
    except (TypeError, ValueError):
        return "n/a"


def num(v):
    try:
        return "n/a" if v is None or pd.isna(v) else f"{int(float(v)):,}"
    except (TypeError, ValueError):
        return "n/a"


def dt(v):
    return "n/a" if v is None or (not isinstance(v, str) and pd.isna(v)) else str(v)[:10]


def header(title, sub):
    st.title(title)
    st.markdown(f"<div class='sc-sub'>{sub}</div>", unsafe_allow_html=True)


def card(kicker, value, basis, source, canonical=False):
    with st.container(border=True):
        st.markdown(
            f"<div class='sc-kicker'>{kicker}</div>"
            f"<div class='sc-big{' canon' if canonical else ''}'>{value}</div>"
            f"<div class='sc-basis'>{basis}</div>"
            f"<div class='sc-src'>{source}</div>",
            unsafe_allow_html=True,
        )


# -----------------------------------------------------------------------------
# Viewer context (through the semantic view, so it reflects the viewer's policies)
# -----------------------------------------------------------------------------
Q_WHO = "SELECT CURRENT_USER() AS USER_NAME, CURRENT_ROLE() AS ROLE_NAME"
Q_PLANTS = f"SELECT plant_code AS PLANT_CODE FROM SEMANTIC_VIEW({SV} DIMENSIONS plants.plant_code) ORDER BY 1"
Q_KRONOS_CLAUSE = (f"SELECT MAX(contract_penalty_clause) AS CLAUSE FROM SEMANTIC_VIEW({SV} DIMENSIONS contracts.contract_no, "
                   "contracts.contract_penalty_clause, suppliers.supplier_no WHERE suppliers.supplier_no = '1000011')")


def viewer_context():
    if "_viewer" in st.session_state:
        return st.session_state["_viewer"]
    who, err = safe(q_metrics, Q_WHO)
    mine, err2 = safe(q_metrics, Q_PLANTS)
    allp, _ = safe(q_owner, Q_PLANTS)
    clause, _ = safe(q_metrics, Q_KRONOS_CLAUSE)
    ctx = {
        "user": who.iloc[0]["USER_NAME"] if who is not None else "?",
        "role": who.iloc[0]["ROLE_NAME"] if who is not None else "?",
        "plants": list(mine["PLANT_CODE"]) if mine is not None else [],
        "all_plants": len(allp) if allp is not None else None,
        "masked": clause is not None and clause.iloc[0]["CLAUSE"] == "***MASKED***",
        "error": err or err2,
    }
    # restricted = the viewer's policies hide something; then OPS free text is not shown
    ctx["restricted"] = ctx["masked"] or (ctx["all_plants"] is not None and len(ctx["plants"]) < ctx["all_plants"])
    st.session_state["_viewer"] = ctx
    return ctx


# -----------------------------------------------------------------------------
# Page 1: The Problem
# -----------------------------------------------------------------------------
Q_LEGACY_PUNE = """
SELECT p.PERIOD_MONTH,
       p.OTD_PCT AS PLANNING_OTD, p.OTD_ON_TIME_LINES AS PLANNING_NUM, p.OTD_SHIPPED_LINES AS PLANNING_DEN,
       r.OTD_PCT AS PROCUREMENT_OTD, r.OTD_ON_TIME_LINES AS PROCUREMENT_NUM, r.OTD_RECEIVED_LINES AS PROCUREMENT_DEN,
       l.OTD_PCT AS LOGISTICS_OTD, l.OTD_ON_TIME_STOPS AS LOGISTICS_NUM, l.OTD_DELIVERED_STOPS AS LOGISTICS_DEN
FROM SC.LEGACY.V_PLANNING_OTD_FILL p
JOIN SC.LEGACY.V_PROCUREMENT_OTD_FILL r ON r.PERIOD_MONTH = p.PERIOD_MONTH AND r.PLANT_CODE = p.PLANT_CODE
JOIN SC.LEGACY.V_LOGISTICS_OTD_FILL l   ON l.PERIOD_MONTH = p.PERIOD_MONTH AND l.PLANT_CODE = p.PLANT_CODE
WHERE p.PLANT_CODE = 'IN01' AND p.PERIOD_MONTH = DATE_TRUNC(month, DATEADD(month, -1, CURRENT_DATE()))
"""
Q_CANON_PUNE_CAL = f"""
SELECT * FROM SEMANTIC_VIEW({SV}
  DIMENSIONS plants.plant_code, plants.plant_name, dates.calendar_month_label,
             dates.calendar_month_start_date, dates.calendar_month_end_date
  METRICS order_lines.customer_otd_pct, order_lines.on_time_lines, order_lines.due_lines,
          order_lines.outbound_arrival_evidence_coverage_pct
  WHERE plants.plant_code = 'IN01' AND dates.calendar_month_offset = -1)
"""


def page_problem():
    header("The Problem", "Pune (IN01), last calendar month. Three teams, three systems, three numbers all called "
           "\"on-time delivery\" - and none of them is the customer's experience.")
    leg, e1 = safe(q_owner, Q_LEGACY_PUNE)
    can, e2 = safe(q_metrics, Q_CANON_PUNE_CAL)
    if e1 or e2:
        st.error(f"Could not load: {e1 or e2}")
        return
    if can.empty:
        st.warning("The semantic view returned no row for Pune last calendar month (plant not visible to your role?).")
        return
    c = can.iloc[0]
    label = f"{c['CALENDAR_MONTH_LABEL']} (calendar month, {dt(c['CALENDAR_MONTH_START_DATE'])} - {dt(c['CALENDAR_MONTH_END_DATE'])})"
    st.markdown(f"**Period:** {label} · **Plant:** {c['PLANT_NAME']} (IN01)")

    cols = st.columns(4)
    if leg.empty:
        for col in cols[:3]:
            with col:
                card("Legacy", "n/a", "No legacy row for this month.", "SC.LEGACY")
    else:
        l = leg.iloc[0]
        with cols[0]:
            card("Planning says (legacy)", pct(l["PLANNING_OTD"]),
                 f"{num(l['PLANNING_NUM'])} / {num(l['PLANNING_DEN'])} SO lines fully shipped (goods issue) by the "
                 "customer's <i>requested</i> date; open late lines never counted.",
                 "SC.LEGACY.V_PLANNING_OTD_FILL · ERP only")
        with cols[1]:
            card("Procurement says (legacy)", pct(l["PROCUREMENT_OTD"]),
                 f"{num(l['PROCUREMENT_NUM'])} / {num(l['PROCUREMENT_DEN'])} <i>inbound PO lines</i> received -3/+0 days "
                 "around the supplier's <i>latest</i> confirmation; open overdue lines drop out.",
                 "SC.LEGACY.V_PROCUREMENT_OTD_FILL · GR posting")
        with cols[2]:
            card("Logistics says (legacy)", pct(l["LOGISTICS_OTD"]),
                 f"{num(l['LOGISTICS_NUM'])} / {num(l['LOGISTICS_DEN'])} <i>stops</i> arrived by the booked appointment "
                 "+30 min; a rebooked slot resets the target.",
                 "SC.LEGACY.V_LOGISTICS_OTD_FILL · carrier / IoT")
    with cols[3]:
        card("Canonical: Customer OTD %", pct(c["CUSTOMER_OTD_PCT"]),
             f"{num(c['ON_TIME_LINES'])} / {num(c['DUE_LINES'])} due order lines arrived <b>complete</b> within "
             f"[first commit - 1 day, first commit]. Evidence coverage {pct(c['OUTBOUND_ARRIVAL_EVIDENCE_COVERAGE_PCT'])}.",
             f"SEMANTIC_VIEW({SV}) · certified · contracts {CONTRACT_VERSION}", canonical=True)

    st.info(
        "**Why they differ** (docs/conflict_matrix.md §2-3): each team measures a different *event* against a different "
        "*date* - planning compares goods issue (not arrival) with the customer's requested date, procurement compares "
        "goods receipts with the supplier's latest re-confirmation (inbound, not customer), and logistics compares stop "
        "arrival with a booked slot that resets on rebooking - and two of them silently drop open late lines from the "
        "denominator. The canonical contract measures one thing: did the customer receive the whole line by the date we "
        "first committed?",
        icon=":material/lightbulb:",
    )
    st.markdown("##### What changes between the definitions")
    st.table(pd.DataFrame({
        "": ["Reference date", "\"Actual\" event", "Grain", "Open late lines", "Tolerance"],
        "Planning (legacy)": ["Customer requested date", "ERP goods issue (ship)", "SO line", "Excluded", "0 days"],
        "Procurement (legacy)": ["Latest supplier confirmation", "ERP goods receipt", "Inbound PO line", "Excluded", "-3 / +0 days"],
        "Logistics (legacy)": ["Booked appointment (rebook resets)", "IoT gate / POD", "Shipment stop", "Excluded", "+30 min"],
        "Canonical Customer OTD %": ["First commit date", "Physical arrival (IoT > POD > carrier)", "Order line, complete qty",
                                     "Counted as late", "[-1, 0] days"],
    }).set_index(""))
    with st.expander("How these numbers were produced"):
        st.markdown(
            "- **Legacy** cards: `SC.LEGACY` views, read with the app owner's rights. LEGACY reproduces each team's current "
            "logic from the source systems as the *before* state of the demo (AGENTS.md hard rule 1, approved exception; "
            "app display on this page only is the hard-rule-2 exception recorded on 2026-10-04). Never canonical.\n"
            f"- **Canonical** card: `SEMANTIC_VIEW({SV})`, run with {RIGHTS}.")
        st.code(Q_CANON_PUNE_CAL.strip(), language="sql")
        st.code(Q_LEGACY_PUNE.strip(), language="sql")


# -----------------------------------------------------------------------------
# Page 2: Ask (Cortex Agent)
# -----------------------------------------------------------------------------
SAMPLES = [
    ("Pune last month", "What was on-time delivery for Pune last month?"),
    ("Vendor OTD by supplier", "What is vendor OTD by supplier?"),
    ("Truck fill rate", "What's our truck fill rate?"),
    ("DOI DE01", "Days of supply for plant DE01"),
    ("Below contract + Kronos penalty", "Which suppliers are below their contracted OTD target, and what penalty applies to Kronos?"),
]
METRIC_LABELS = {
    "CUSTOMER_OTD_PCT": ("Customer OTD %", "certified"),
    "SUPPLIER_OTD_PCT": ("Supplier OTD %", "certified"),
    "FILL_RATE_PCT": ("Fill Rate %", "certified"),
    "DAYS_OF_INVENTORY": ("Days of Inventory", "certified"),
    "LANDED_COST_PER_UNIT": ("Landed Cost per Unit", "certified"),
    "LANDED_COST_UPLIFT_PCT": ("Landed Cost Uplift %", "certified"),
    "SUPPLIER_CONTRACTUAL_OTD_PCT": ("Supplier Contractual OTD %", "named variant, not canonical"),
    "SUPPLIER_CONTRACTUAL_OTD_GAP": ("Supplier Contractual OTD Gap", "named variant, not canonical"),
}
PERIOD_COLS = [("FISCAL_MONTH_LABEL", "FISCAL_MONTH_START_DATE", "FISCAL_MONTH_END_DATE"),
               ("FISCAL_QUARTER_LABEL", "FISCAL_QUARTER_START_DATE", "FISCAL_QUARTER_END_DATE"),
               ("FISCAL_YEAR_LABEL", "FISCAL_YEAR_START_DATE", "FISCAL_YEAR_END_DATE"),
               ("FISCAL_WEEK_LABEL", "FISCAL_WEEK_START_DATE", "FISCAL_WEEK_END_DATE"),
               ("CALENDAR_MONTH_LABEL", "CALENDAR_MONTH_START_DATE", "CALENDAR_MONTH_END_DATE")]
CONFIRM_RE = re.compile(r"shall i write this request|\(\s*yes\s*/\s*no\s*\)", re.I)
AGENT_SQL = f"SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN('{AGENT}', ?) AS RESPONSE"


def call_agent(history):
    """One Cortex Agents run (DATA_AGENT_RUN = the Agents Run API, non-streaming) with the whole
    conversation; the request body is a bound parameter, never spliced into the SQL."""
    msgs = [{"role": m["role"], "content": [{"type": "text", "text": m["text"]}]} for m in history]
    df = _execute(metrics_conn, AGENT_SQL, [json.dumps({"messages": msgs})])
    return json.loads(df.iloc[0]["RESPONSE"])


def result_frame(rs):
    cols = [c["name"] for c in rs.get("resultSetMetaData", {}).get("rowType", [])]
    return pd.DataFrame(rs.get("data", []), columns=cols)


def parse_response(resp):
    blocks = resp.get("content", [])
    out = {"text": "", "sql": [], "tools": [], "results": [], "charts": [], "actions": []}
    uses = {}
    texts = []
    for b in blocks:
        t = b.get("type")
        if t == "text":
            texts.append(b.get("text", ""))
        elif t == "tool_use":
            u = b.get("tool_use", {})
            uses[u.get("tool_use_id")] = u
            out["tools"].append(u.get("name"))
            if u.get("input", {}).get("sql"):
                out["sql"].append(u["input"]["sql"])
        elif t == "tool_result":
            r = b.get("tool_result", {})
            u = uses.get(r.get("tool_use_id"), {})
            for c in r.get("content", []):
                j = c.get("json") or {}
                if "result_set" in j:
                    out["results"].append(result_frame(j["result_set"]))
                if u.get("name") in ("expedite_po", "flag_supplier"):
                    out["actions"].append({"tool": u.get("name"), "result": j or c.get("text")})
        elif t == "chart":
            spec = b.get("chart", {}).get("chart_spec")
            if spec:
                out["charts"].append(spec)
    out["text"] = "\n\n".join(x.strip() for x in texts if x.strip())
    return out


def answer_facts(results):
    """Metric, period and coverage exactly as returned by the semantic view (no arithmetic)."""
    facts = []
    for df in results:
        cols = set(df.columns)
        metrics = [m for m in METRIC_LABELS if m in cols]
        if not metrics or df.empty:
            continue
        row = df.iloc[0]
        period = "all history (no period named)"
        for lab, s, e in PERIOD_COLS:
            if lab in cols:
                period = f"{row[lab]} ({dt(row[s]) if s in cols else '?'} - {dt(row[e]) if e in cols else '?'})"
                if lab.startswith("CALENDAR"):
                    period += ", calendar month"
                break
        else:
            first = [c for c in df.columns if "FIRST" in c and c.endswith("DATE")]
            last = [c for c in df.columns if "LAST" in c and c.endswith("DATE")]
            if first and last:
                period = f"all history, {dt(row[first[0]])} - {dt(row[last[0]])}"
        if "DOI_SNAPSHOT_DATE" in cols:
            period += f" · snapshot {dt(row['DOI_SNAPSHOT_DATE'])}"
        cov = [c for c in df.columns if "COVERAGE" in c]
        facts.append({
            "metric": ", ".join(f"{METRIC_LABELS[m][0]} ({METRIC_LABELS[m][1]})" for m in metrics),
            "period": period,
            "coverage": " · ".join(pct(row[c]) for c in cov) if cov and len(df) == 1 else
                        ("per row, see the result table" if cov else "not returned"),
            "rows": len(df),
        })
    return facts


def render_answer(msg):
    st.markdown(msg["text"] or "_(no text in the agent response)_")
    p = msg.get("parsed")
    if not p:
        return
    for spec in p["charts"]:
        try:
            st.vega_lite_chart(json.loads(spec), width="stretch")
        except Exception:
            pass
    facts = answer_facts(p["results"])
    if facts:
        for f in facts:
            with st.container(border=True):
                a, b, c = st.columns([3, 3, 2])
                a.markdown(f"<div class='sc-kicker'>Metric</div>{f['metric']}", unsafe_allow_html=True)
                b.markdown(f"<div class='sc-kicker'>Period</div>{f['period']}", unsafe_allow_html=True)
                c.markdown(f"<div class='sc-kicker'>Evidence coverage</div>{f['coverage']}", unsafe_allow_html=True)
    elif "supply_chain_metrics" not in p["tools"] and "system_execute_sql" not in p["tools"]:
        st.caption("No semantic-view query was run for this answer (e.g. a non-canonical metric was refused).")
    for a in p["actions"]:
        res = a["result"] if isinstance(a["result"], dict) else {"result": a["result"]}
        status = str(res.get("status", "?"))
        (st.success if status == "CONFIRMED" else st.warning)(
            f"{a['tool']}: **{status}** {res.get('confirmation_id', '')} {res.get('error', '')}".strip())
    with st.expander(f"Generated SQL and results ({len(p['sql'])} quer{'y' if len(p['sql']) == 1 else 'ies'}) · tools: "
                     f"{', '.join(dict.fromkeys(t for t in p['tools'] if t)) or 'none'}"):
        for s in p["sql"]:
            st.code(s, language="sql")
        for df in p["results"]:
            st.dataframe(df, hide_index=True, width="stretch")


def ask(text):
    st.session_state.chat.append({"role": "user", "text": text})
    st.session_state.pending = True


def page_ask():
    header("Ask", f"Chat with <code>{AGENT}</code>: one agent, one set of contracts. Numbers come only from "
           f"<code>{SV}</code>; the agent runs with {RIGHTS}.")
    st.session_state.setdefault("chat", [])
    st.session_state.setdefault("pending", False)

    st.markdown("<div class='sc-kicker'>Try a sample question</div>", unsafe_allow_html=True)
    cols = st.columns(len(SAMPLES))
    for col, (label, q) in zip(cols, SAMPLES):
        col.button(label, key=f"s_{label}", on_click=ask, args=(q,), width="stretch",
                   disabled=st.session_state.pending)
    _, clr = st.columns([6, 1])
    clr.button("New chat", on_click=lambda: st.session_state.update(chat=[], pending=False),
               icon=":material/restart_alt:", width="stretch")

    for m in st.session_state.chat:
        with st.chat_message(m["role"], avatar=":material/person:" if m["role"] == "user" else ":material/hub:"):
            if m["role"] == "assistant":
                render_answer(m)
            else:
                st.markdown(m["text"])

    if st.session_state.pending:
        with st.chat_message("assistant", avatar=":material/hub:"):
            with st.spinner("The agent is querying the semantic view..."):
                try:
                    resp = call_agent(st.session_state.chat)
                    p = parse_response(resp)
                    st.session_state.chat.append({"role": "assistant", "text": p["text"], "parsed": p})
                except Exception as e:
                    st.session_state.chat.append({"role": "assistant", "text": f"**Agent error:** {e}", "parsed": None})
        st.session_state.pending = False
        st.rerun()

    # confirm-first: an action (expedite / flag) is written only after an explicit click on "Yes"
    last = st.session_state.chat[-1] if st.session_state.chat else None
    if last and last["role"] == "assistant" and CONFIRM_RE.search(last["text"] or ""):
        with st.container(border=True):
            st.markdown("**The agent proposes an audited action.** Nothing has been written. Confirming writes one row "
                        "to `SC.OPS.ALERT_AGENT_ACTIONS` with your user name and a UTC timestamp; no external system is called.")
            y, n, _ = st.columns([1, 1, 4])
            y.button("Yes, write it", type="primary", on_click=ask, args=("yes",), icon=":material/check:")
            n.button("No", on_click=ask, args=("no",), icon=":material/close:")

    if prompt := st.chat_input("Ask about OTD, fill rate, days of inventory, landed cost, contracts...",
                               disabled=st.session_state.pending):
        ask(prompt)
        st.rerun()


# -----------------------------------------------------------------------------
# Page 3: One answer, every persona
# -----------------------------------------------------------------------------
Q_LIVE_OTD = (f"SELECT fiscal_month_label AS LABEL, fiscal_month_start_date AS S, fiscal_month_end_date AS E, customer_otd_pct AS V "
              f"FROM SEMANTIC_VIEW({SV} DIMENSIONS plants.plant_code, dates.fiscal_month_label, dates.fiscal_month_start_date, "
              "dates.fiscal_month_end_date METRICS order_lines.customer_otd_pct WHERE plants.plant_code = 'IN01' AND dates.fiscal_month_offset = -1)")
Q_LIVE_DOI = (f"SELECT doi_snapshot_date AS D, days_of_inventory AS V FROM SEMANTIC_VIEW({SV} DIMENSIONS plants.plant_code "
              "METRICS inventory.doi_snapshot_date, inventory.days_of_inventory WHERE plants.plant_code = 'DE01')")
Q_LIVE_HIDDEN = (f"SELECT COUNT(*) AS N FROM SEMANTIC_VIEW({SV} DIMENSIONS plants.plant_code METRICS order_lines.customer_otd_pct "
                 "WHERE plants.plant_code = 'US01' AND dates.fiscal_month_offset = -1)")
Q_PERSONA = """
WITH last_run AS (SELECT RUN_ID FROM SC.OPS.TEST_PERSONA_RESULTS WHERE RUN_ID NOT LIKE 'STEP8-%' ORDER BY RUN_TS DESC LIMIT 1)
SELECT r.RUN_ID, r.RUN_TS, r.ROLE_NAME, r.SURFACE, r.CHECK_NAME, r.DISPLAY_VALUE, r.VISIBLE_PLANTS, r.IS_EQUAL_TO_ADMIN
FROM SC.OPS.TEST_PERSONA_RESULTS r JOIN last_run USING (RUN_ID)
ORDER BY r.SURFACE, r.CHECK_NAME, r.ROLE_NAME
"""
Q_PERSONA_TESTS = """
SELECT TEST_NAME, STATUS FROM SC.OPS.TEST_RESULTS
WHERE RUN_ID = (SELECT RUN_ID FROM SC.OPS.TEST_PERSONA_RESULTS WHERE RUN_ID NOT LIKE 'STEP8-%' ORDER BY RUN_TS DESC LIMIT 1)
  AND TEST_NAME IN ('H1_GOV_PERSONA_ROWS_THROUGH_SEMANTIC_VIEW', 'E_AGENT_Q1_OTD_PUNE_SAME_FOR_ALL_PERSONAS',
                    'H1_GOV_HIDDEN_PLANT_THROUGH_AGENT', 'H2_GOV_PENALTY_CLAUSE_MASKED_THROUGH_SEMANTIC_VIEW')
ORDER BY TEST_NAME
"""
PERSONAS = ["SC_ADMIN", "SC_PLANNER", "SC_PROCUREMENT", "SC_LOGISTICS"]
CHECK_LABELS = {
    "CUSTOMER_OTD_IN01_LAST_FISCAL_MONTH": "Customer OTD %, Pune (IN01), last fiscal month",
    "DOI_DE01_LATEST_SNAPSHOT": "Days of Inventory, Stuttgart (DE01), latest snapshot",
    "HIDDEN_PLANT_US01_ROWS": "Rows returned for Memphis (US01)",
}


def page_personas():
    header("One answer, every persona", "Same question, same semantic view, same number - for planning, procurement and "
           "logistics. Only what a role may <i>see</i> differs (row access and masking), never how a metric is computed.")
    v = viewer_context()

    st.subheader("1 · Live, as you")
    if caller is not None:
        st.caption(f"Run now through the restricted caller's rights connection: Snowflake executes these "
                   f"`SEMANTIC_VIEW()` queries as **{v['user']}** with role **{v['role']}** (your default role), so your "
                   "row access and masking policies apply.")
    else:
        st.warning(f"Caller's rights are not available in this runtime ({CALLER_ERROR}). The live values below run with "
                   "the app owner's role SC_ADMIN, not yours.")
    otd, e1 = safe(q_metrics, Q_LIVE_OTD)
    doi, e2 = safe(q_metrics, Q_LIVE_DOI)
    hid, e3 = safe(q_metrics, Q_LIVE_HIDDEN)
    if e1 or e2 or e3:
        st.error(e1 or e2 or e3)
    else:
        a, b, c, d = st.columns(4)
        with a:
            card("Your role", v["role"], f"{len(v['plants'])} plant(s) visible", "through the semantic view")
        with b:
            o = otd.iloc[0] if not otd.empty else None
            card("Customer OTD %, Pune, last month", pct(o["V"]) if o is not None else "n/a",
                 f"{o['LABEL']} ({dt(o['S'])} - {dt(o['E'])})" if o is not None else "IN01 not visible", "SEMANTIC_VIEW", canonical=True)
        with c:
            x = doi.iloc[0] if not doi.empty else None
            card("Days of Inventory, DE01", days(x["V"]) if x is not None else "n/a",
                 f"as of {dt(x['D'])} (latest snapshot)" if x is not None else "DE01 not visible", "SEMANTIC_VIEW", canonical=True)
        with d:
            n = int(hid.iloc[0]["N"])
            card("Memphis (US01) rows", str(n), "hidden plant: no rows, no error" if n == 0 else "plant visible to your role",
                 "row access policy RAP_PLANT_ACCESS")

    st.subheader("2 · Recorded, as each persona")
    pr, err = safe(q_owner, Q_PERSONA)
    if err or pr is None or pr.empty:
        st.warning("No recorded persona results yet: run `tests/consistency_tests.sql` (it writes SC.OPS.TEST_PERSONA_RESULTS). "
                   + (f"({err})" if err else ""))
        return
    run_id, run_ts = pr.iloc[0]["RUN_ID"], pr.iloc[0]["RUN_TS"]
    st.caption(f"Not computed here. The consistency suite (run `{run_id}` at {str(run_ts)[:19]} UTC) switched to each persona "
               "role with `USE ROLE <persona>` and `USE SECONDARY ROLES NONE`, ran the same `SEMANTIC_VIEW()` queries and the "
               "same agent question, and stored what each role got. Values are shown exactly as recorded.")
    for surface, title in [("SEMANTIC_VIEW", "Through the semantic view"), ("AGENT", "Through the agent (\"What was on-time delivery for Pune last month?\")")]:
        sub = pr[pr["SURFACE"] == surface]
        if sub.empty:
            continue
        st.markdown(f"**{title}**")
        for chk in dict.fromkeys(sub["CHECK_NAME"]):
            rows = sub[sub["CHECK_NAME"] == chk].set_index("ROLE_NAME")
            cols = st.columns([2.2] + [1] * len(PERSONAS))
            cols[0].markdown(f"<div class='sc-basis'>{CHECK_LABELS.get(chk, chk)}</div>", unsafe_allow_html=True)
            for col, role in zip(cols[1:], PERSONAS):
                if role not in rows.index:
                    col.markdown(f"<div class='sc-kicker'>{role}</div>-", unsafe_allow_html=True)
                    continue
                r = rows.loc[role]
                ok = r["IS_EQUAL_TO_ADMIN"]
                mark = "" if ok is None or pd.isna(ok) else (" :green[✓]" if bool(ok) else " :red[✗]")
                col.markdown(f"<div class='sc-kicker'>{role}</div>", unsafe_allow_html=True)
                col.markdown(f"**{r['DISPLAY_VALUE']}**{mark}")
    plants = pr[(pr["SURFACE"] == "SEMANTIC_VIEW")].drop_duplicates("ROLE_NAME").set_index("ROLE_NAME")["VISIBLE_PLANTS"]
    st.caption("✓ = equal to SC_ADMIN's value for the same plant. Visible plants per role: "
               + ", ".join(f"{r} {num(plants[r])}" for r in PERSONAS if r in plants.index)
               + " (SC_LOGISTICS: APAC + EMEA only).")
    t, _ = safe(q_owner, Q_PERSONA_TESTS)
    if t is not None and not t.empty:
        st.markdown(" ".join(f":{'green' if s == 'PASS' else 'red'}-badge[{n}: {s}]" for n, s in zip(t["TEST_NAME"], t["STATUS"])))


# -----------------------------------------------------------------------------
# Page 4: Ontology & contracts
# -----------------------------------------------------------------------------
Q_DESCRIBE = f"DESCRIBE SEMANTIC VIEW {SV}"
CANONICAL = ["CUSTOMER_OTD_PCT", "SUPPLIER_OTD_PCT", "FILL_RATE_PCT", "DAYS_OF_INVENTORY", "LANDED_COST_PER_UNIT",
             "LANDED_COST_UPLIFT_PCT", "SUPPLIER_CONTRACTUAL_OTD_PCT", "SUPPLIER_CONTRACTUAL_OTD_GAP"]
METRIC_TABLE = {"CUSTOMER_OTD_PCT": "ORDER_LINES", "FILL_RATE_PCT": "ORDER_LINES", "SUPPLIER_OTD_PCT": "PURCHASE_ORDER_LINES",
                "DAYS_OF_INVENTORY": "INVENTORY", "LANDED_COST_PER_UNIT": "GOODS_RECEIPTS", "LANDED_COST_UPLIFT_PCT": "GOODS_RECEIPTS",
                "SUPPLIER_CONTRACTUAL_OTD_PCT": "PURCHASE_ORDER_LINES", "SUPPLIER_CONTRACTUAL_OTD_GAP": "PURCHASE_ORDER_LINES"}
Q_TAGS = " UNION ALL ".join(
    f"SELECT '{m}' AS METRIC, TAG_NAME, TAG_VALUE FROM TABLE(SC.INFORMATION_SCHEMA.TAG_REFERENCES('{SV}!{t}.{m}', 'SEMANTIC METRIC'))"
    for m, t in METRIC_TABLE.items())
Q_CONTRACTS = f"""
SELECT * FROM SEMANTIC_VIEW({SV}
  DIMENSIONS contracts.contract_no, contracts.contract_supplier_name, contracts.contract_valid_from, contracts.contract_valid_to,
             contracts.contract_delivery_target, contracts.contract_late_grace_days, contracts.contract_late_penalty_per_day,
             contracts.contract_late_penalty_cap, contracts.contract_lead_time_days, contracts.contract_incoterm,
             contracts.contract_payment_terms, contracts.contract_penalty_clause)
ORDER BY contract_no
"""


def describe_props(desc, kind):
    d = desc[desc["object_kind"] == kind].fillna({"parent_entity": ""})
    return d.pivot_table(index=["object_name", "parent_entity"], columns="property", values="property_value", aggfunc="first").reset_index()


def page_ontology():
    header("Ontology & contracts", "The entities, relationships and metric contracts behind every answer - read live from "
           f"<code>{SV}</code>, the only place metric logic lives.")
    desc, err = safe(q_metrics, Q_DESCRIBE)
    if err:
        st.error(err)
        return
    desc.columns = [c.lower() for c in desc.columns]
    tab_m, tab_e, tab_c = st.tabs([":material/verified: Canonical metrics", ":material/account_tree: Entities & relationships",
                                   ":material/contract: Contract terms"])

    with tab_m:
        mets = describe_props(desc, "METRIC").set_index("object_name")
        tags, terr = safe(q_owner, Q_TAGS)
        tagmap = {} if tags is None else {(r.METRIC, r.TAG_NAME): r.TAG_VALUE for r in tags.itertuples()}
        if terr:
            st.caption(f"Tags unavailable: {terr}")
        for m in CANONICAL:
            if m not in mets.index:
                continue
            row = mets.loc[m]
            row = row.iloc[0] if isinstance(row, pd.DataFrame) else row
            label = METRIC_LABELS[m][0]
            cert = tagmap.get((m, "CERTIFIED"), "?")
            owner_role = tagmap.get((m, "METRIC_OWNER"), "?")
            with st.container(border=True):
                a, b = st.columns([5, 2])
                a.markdown(f"#### {label}  \n`{m}`")
                with b:
                    if cert == "TRUE":
                        st.badge("CERTIFIED", icon=":material/verified:", color="green")
                    elif cert == "NAMED_VARIANT":
                        st.badge("NAMED VARIANT - not canonical", icon=":material/info:", color="orange")
                    else:
                        st.badge(f"CERTIFIED = {cert}", color="gray")
                    st.markdown(f"<div class='sc-basis'>Owner: <b>{owner_role}</b></div>", unsafe_allow_html=True)
                st.markdown(str(row.get("COMMENT", "")))
                syn = row.get("SYNONYMS")
                if isinstance(syn, str) and syn.strip():
                    st.caption("Synonyms: " + ", ".join(json.loads(syn)))
        st.caption(f"Definitions: docs/metric_contracts.md {CONTRACT_VERSION} (binding). Unqualified \"on-time delivery\" / "
                   "\"OTD\" always means Customer OTD %. Certification tags CERTIFIED / METRIC_OWNER (set in sql/30).")

    with tab_e:
        tbl = describe_props(desc, "TABLE")
        rel = describe_props(desc, "RELATIONSHIP")
        dot = ["digraph G {", 'rankdir=LR; bgcolor="transparent";',
               'node [shape=box, style="rounded,filled", fillcolor="#EAF2F8", color="#11567F", fontname="Helvetica", fontsize=11];',
               'edge [color="#829AB1", fontname="Helvetica", fontsize=8];']
        for r in rel.itertuples():
            dot.append(f'"{r.TABLE}" -> "{r.REF_TABLE}" [label="{", ".join(json.loads(r.FOREIGN_KEY))}"];')
        dot.append("}")
        st.graphviz_chart("\n".join(dot))
        st.caption("Arrows: many-to-one, labelled with the natural key (docs/ontology.md §2). Logical tables of the semantic view.")
        show = pd.DataFrame({
            "Entity": tbl["object_name"].str.lower(),
            "Definition": tbl.get("COMMENT"),
            "Key": tbl.get("PRIMARY_KEY").map(lambda s: ", ".join(json.loads(s)) if isinstance(s, str) else ""),
            "Synonyms": tbl.get("SYNONYMS").map(lambda s: ", ".join(json.loads(s)) if isinstance(s, str) else ""),
        })
        st.dataframe(show, hide_index=True, width="stretch")

    with tab_c:
        ct, cerr = safe(q_metrics, Q_CONTRACTS)
        if cerr:
            st.error(cerr)
        else:
            view = pd.DataFrame({
                "Contract": ct["CONTRACT_NO"], "Supplier": ct["CONTRACT_SUPPLIER_NAME"],
                "Valid": ct["CONTRACT_VALID_FROM"].map(dt) + " - " + ct["CONTRACT_VALID_TO"].map(dt),
                "Delivery target": ct["CONTRACT_DELIVERY_TARGET"].map(pct),
                "Grace days": ct["CONTRACT_LATE_GRACE_DAYS"], "Penalty / day": ct["CONTRACT_LATE_PENALTY_PER_DAY"].map(pct),
                "Penalty cap": ct["CONTRACT_LATE_PENALTY_CAP"].map(lambda x: pct(x, 0)),
                "Lead time (d)": ct["CONTRACT_LEAD_TIME_DAYS"], "Incoterm": ct["CONTRACT_INCOTERM"],
                "Payment terms": ct["CONTRACT_PAYMENT_TERMS"], "Penalty clause": ct["CONTRACT_PENALTY_CLAUSE"],
            })
            st.dataframe(view, hide_index=True, width="stretch",
                         column_config={"Penalty clause": st.column_config.TextColumn(width="large")})
            st.caption("Terms as printed on the signed contract PDFs (legal source), served by the `contracts` table of the "
                       f"semantic view with {RIGHTS}. The penalty clause is masked (`***MASKED***`) for SC_LOGISTICS; rate, cap "
                       "and grace days stay visible.")


# -----------------------------------------------------------------------------
# Page 5: Trust
# -----------------------------------------------------------------------------
Q_RUNS = """
SELECT RUN_ID, MIN(RUN_TS) AS RUN_TS, COUNT_IF(STATUS = 'PASS') AS PASSED, COUNT_IF(STATUS = 'FAIL') AS FAILED,
       COUNT_IF(STATUS = 'SKIP') AS SKIPPED, COUNT(*) AS TESTS
FROM SC.OPS.TEST_RESULTS WHERE RUN_ID NOT LIKE 'STEP8-%' GROUP BY RUN_ID ORDER BY RUN_TS DESC LIMIT 15
"""
Q_RUN_TESTS = "SELECT TEST_NAME, STATUS, DETAIL FROM SC.OPS.TEST_RESULTS WHERE RUN_ID = ? ORDER BY STATUS <> 'FAIL', TEST_NAME"
# Step 8 runner (tests/step8_harness.py): RUN_ID STEP8-<PERSONA|EDGE>-<label>-<utc>; scores are parsed from the
# scorecard rows it writes (test scores, not supply chain metrics)
Q_STEP8_RUNS = """
SELECT RUN_ID, MIN(RUN_TS) AS RUN_TS, SPLIT_PART(RUN_ID, '-', 2) AS PART, LOWER(SPLIT_PART(RUN_ID, '-', 3)) AS LABEL,
       COUNT_IF(STATUS = 'PASS' AND TEST_NAME NOT LIKE '%SCORE%') AS PASSED, COUNT_IF(STATUS = 'FAIL' AND TEST_NAME NOT LIKE '%SCORE%') AS FAILED,
       MAX(IFF(TEST_NAME = 'P_SCORE_PERSONA_CONSISTENCY', REGEXP_SUBSTR(DETAIL, '= ([0-9.]+)%', 1, 1, 'e'), NULL))::FLOAT AS CONSISTENCY_PCT,
       MAX(IFF(TEST_NAME = 'P_SCORE_GOLDEN_MATCH', REGEXP_SUBSTR(DETAIL, '= ([0-9.]+)%', 1, 1, 'e'), NULL))::FLOAT AS GOLDEN_PCT
FROM SC.OPS.TEST_RESULTS WHERE RUN_ID LIKE 'STEP8-%' AND RUN_ID NOT LIKE 'STEP8-%-SMOKE-%'
GROUP BY RUN_ID ORDER BY RUN_TS DESC LIMIT 20
"""
Q_STEP8_ROWS = "SELECT TEST_NAME, STATUS, DETAIL FROM SC.OPS.TEST_RESULTS WHERE RUN_ID = ? AND NOT CONTAINS(TEST_NAME, 'SCORE') ORDER BY TEST_NAME"
Q_STEP8_PERSONA = """
SELECT CHECK_NAME, ROLE_NAME, SURFACE, DISPLAY_VALUE, IS_EQUAL_TO_ADMIN AS MATCHES_GOLDEN
FROM SC.OPS.TEST_PERSONA_RESULTS WHERE RUN_ID = ? ORDER BY CHECK_NAME, SURFACE DESC, ROLE_NAME
"""
# data metric functions of sql/60_ops_dq_dmf.sql: latest scheduled measurement per association + its expectation
Q_DMF = """
SELECT r.TABLE_NAME, r.METRIC_NAME, ARRAY_TO_STRING(r.ARGUMENT_NAMES, ', ') AS ARGUMENTS, r.VALUE::VARCHAR AS VALUE,
       e.EXPECTATION_NAME, e.EXPECTATION_EXPRESSION, e.EXPECTATION_VIOLATED, r.MEASUREMENT_TIME
FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS r
LEFT JOIN SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_EXPECTATION_STATUS e
  ON e.REFERENCE_ID = r.REFERENCE_ID AND e.MEASUREMENT_TIME = r.MEASUREMENT_TIME
WHERE r.TABLE_DATABASE = 'SC'
QUALIFY RANK() OVER (PARTITION BY r.TABLE_NAME, r.METRIC_NAME, ARRAY_TO_STRING(r.ARGUMENT_NAMES, ',') ORDER BY r.MEASUREMENT_TIME DESC) = 1
ORDER BY r.TABLE_NAME, r.METRIC_NAME, ARGUMENTS
"""
Q_AUDIT = """
SELECT REQUESTED_TS, CONFIRMATION_ID, ACTION_TYPE, STATUS, SUPPLIER_NO, SUPPLIER_NAME, PO_NO, PO_LINE_NO, PLANT_CODE,
       REQUESTED_BY_USER, REASON, EVIDENCE, SOURCE
FROM SC.OPS.ALERT_AGENT_ACTIONS ORDER BY REQUESTED_TS DESC LIMIT 200
"""
Q_SUPPLIER_PLANTS = (f"SELECT DISTINCT supplier_no AS SUPPLIER_NO FROM SEMANTIC_VIEW({SV} DIMENSIONS purchase_order_lines.po_no, "
                     "suppliers.supplier_no, plants.plant_code)")
Q_RECON = """
SELECT TERM, COUNT_IF(STATUS = 'MATCH') AS MATCHED, COUNT_IF(STATUS = 'MISMATCH') AS MISMATCHED,
       COUNT_IF(STATUS = 'PDF_ONLY') AS PDF_ONLY, COUNT(*) AS CONTRACTS
FROM SC.OPS.DQ_CONTRACT_TERMS_RECON GROUP BY TERM ORDER BY MISMATCHED DESC, TERM
"""
Q_RECON_MISMATCH = """
SELECT CONTRACT_NO, SUPPLIER_NO, TERM, PDF_VALUE, SUPPLIER_SYSTEM_FIELD
FROM SC.OPS.DQ_CONTRACT_TERMS_RECON WHERE STATUS = 'MISMATCH' ORDER BY CONTRACT_NO, TERM
"""


def trust_step8(v):
    """Playbook Step 8 results as recorded by tests/step8_harness.py (separate runner, not run on every change)."""
    st.subheader("Persona consistency harness and guardrails (Step 8)")
    runs, err = safe(q_owner, Q_STEP8_RUNS)
    if err or runs is None or runs.empty:
        st.caption("No Step 8 runs recorded yet: run `python3 tests/step8_harness.py --part persona` / `--part edge`.")
        return
    persona = runs[runs["PART"] == "PERSONA"]
    edge = runs[runs["PART"] == "EDGE"]
    if not persona.empty:
        st.markdown("**8.1 Same question, three vocabularies, three personas.** 30 base questions (every canonical metric "
                    "and the named variants; last month, this quarter, a calendar month, no period; plants, regions, "
                    "suppliers, categories), each phrased in planning, procurement and logistics words. Cortex Analyst "
                    "writes the SQL on the semantic view; it runs as the persona role whose words were used; the value is "
                    "compared with the golden `SEMANTIC_VIEW()` query (tolerance 0.05 points).")
        latest = {lab: persona[persona["LABEL"] == lab].iloc[0] for lab in ("before", "after") if (persona["LABEL"] == lab).any()}
        cols = st.columns(4)
        for i, (lab, r) in enumerate(latest.items()):
            cols[2 * i].metric(f"Persona consistency ({lab})", f"{r['CONSISTENCY_PCT']:.1f}%", border=True,
                               help="Base questions whose three phrasings returned the same value. Target 100%.")
            cols[2 * i + 1].metric(f"Golden match ({lab})", f"{r['GOLDEN_PCT']:.1f}%", border=True,
                                   help="Phrasings whose value equals the golden SEMANTIC_VIEW() value. Target 95%.")
        last = persona.iloc[0]
        rows, _ = safe(q_owner, Q_STEP8_ROWS, [str(last["RUN_ID"])])
        vals, _ = safe(q_owner, Q_STEP8_PERSONA, [str(last["RUN_ID"])])
        with st.expander(f"Per question, run `{last['RUN_ID']}` ({str(last['RUN_TS'])[:16]} UTC): "
                         f"{num(last['PASSED'])} pass, {num(last['FAILED'])} fail"):
            if vals is not None and not vals.empty and not v["restricted"]:
                vals["COL"] = vals.apply(lambda x: "Golden (SEMANTIC_VIEW)" if x["SURFACE"] != "CORTEX_ANALYST" else x["ROLE_NAME"], axis=1)
                grid = vals.pivot_table(index="CHECK_NAME", columns="COL", values="DISPLAY_VALUE", aggfunc="first")
                grid = grid[[c for c in ["Golden (SEMANTIC_VIEW)", "SC_PLANNER", "SC_PROCUREMENT", "SC_LOGISTICS"] if c in grid.columns]]
                if rows is not None:
                    grid = grid.join(rows.assign(CHECK_NAME=rows["TEST_NAME"].str[2:]).set_index("CHECK_NAME")[["STATUS"]])
                st.dataframe(grid, width="stretch")
            elif rows is not None:
                st.dataframe(rows.drop(columns=["DETAIL"]), hide_index=True, width="stretch")
    if not edge.empty:
        last = edge.iloc[0]
        st.markdown(f"**8.2 Edge cases and guardrails through the agent:** {num(last['PASSED'])} of "
                    f"{num(last['PASSED'] + last['FAILED'])} passed in run `{last['RUN_ID']}` ({str(last['RUN_TS'])[:16]} UTC). "
                    "Zero due lines, future period, unknown supplier, misspelled plant, OTD vs requested date, ambiguous "
                    "question, out of scope, prompt injection, hidden plant, closed PO, expedite at a hidden plant.")
        rows, _ = safe(q_owner, Q_STEP8_ROWS, [str(last["RUN_ID"])])
        if rows is not None:
            if v["restricted"]:
                rows = rows.drop(columns=["DETAIL"])
            st.dataframe(rows, hide_index=True, width="stretch",
                         column_config={"DETAIL": st.column_config.TextColumn(width="large")})


def trust_dmf():
    st.subheader("Data quality monitors (data metric functions)")
    dq, err = safe(q_owner, Q_DMF)
    if err:
        st.error(err)
        return
    if dq is None or dq.empty:
        st.caption("No scheduled data metric function result yet (daily at 12:00 UTC, sql/60_ops_dq_dmf.sql).")
        return
    ok = int((dq["EXPECTATION_VIOLATED"] == False).sum())  # noqa: E712 (pandas boolean column)
    bad = int((dq["EXPECTATION_VIOLATED"] == True).sum())  # noqa: E712
    a, b, c = st.columns(3)
    a.metric("Expectations met", num(ok), border=True)
    b.metric("Expectations violated", num(bad), border=True)
    c.metric("Last measured (UTC)", str(dq["MEASUREMENT_TIME"].max())[:16], border=True)
    st.dataframe(dq, hide_index=True, width="stretch")
    st.caption("NULL_COUNT, DUPLICATE_COUNT and FRESHNESS (seconds since the latest arrival) on the order-line and "
               "shipment facts, plus a custom check for supplier parts that map to no ERP part (planted ~2%, allowed up "
               "to 3%). Scheduled daily at 12:00 UTC as the table owner (sees every plant); expectations mirror the bands "
               "of the consistency suite.")


def page_trust():
    header("Trust", "Why you can rely on the numbers: the consistency suite after every change, an audit trail for every "
           "agent action, and a reconciliation of contract PDFs against the supplier system.")
    v = viewer_context()
    if v["restricted"]:
        st.info("Your role's data policies hide some plants or masked fields, so free-text details below are hidden and the "
                "audit log shows only rows for plants and suppliers you can see.", icon=":material/shield:")

    st.subheader("Consistency suite")
    runs, err = safe(q_owner, Q_RUNS)
    if err or runs is None or runs.empty:
        st.warning(f"No suite results in SC.OPS.TEST_RESULTS yet. {err or ''}")
    else:
        last = runs.iloc[0]
        a, b, c, d = st.columns(4)
        a.metric("Last run (UTC)", str(last["RUN_TS"])[:16], border=True)
        b.metric("Passed", num(last["PASSED"]), border=True)
        c.metric("Failed", num(last["FAILED"]), border=True)
        d.metric("Skipped", num(last["SKIPPED"]), border=True)
        if int(last["FAILED"]) == 0:
            st.success(f"All {num(last['TESTS'])} tests in run `{last['RUN_ID']}` passed or skipped.", icon=":material/task_alt:")
        hist = runs[["RUN_TS", "PASSED", "FAILED", "SKIPPED"]].copy()
        hist["RUN_TS"] = pd.to_datetime(hist["RUN_TS"].astype(str).str[:19])
        st.bar_chart(hist.set_index("RUN_TS")[["PASSED", "FAILED", "SKIPPED"]], color=["#2E7D32", "#C62828", "#B0BEC5"], height=180)
        tests, terr = safe(q_owner, Q_RUN_TESTS, [str(last["RUN_ID"])])
        if tests is not None:
            tests["SECTION"] = tests["TEST_NAME"].str.extract(r"^([A-Z][0-9]?)_", expand=False)
            if v["restricted"]:
                tests = tests.drop(columns=["DETAIL"])
            with st.expander(f"All {len(tests)} tests of the last run"):
                st.dataframe(tests, hide_index=True, width="stretch",
                             column_config={"DETAIL": st.column_config.TextColumn(width="large")})

    trust_step8(v)
    trust_dmf()

    st.subheader("Agent action audit log")
    audit, aerr = safe(q_owner, Q_AUDIT)
    if aerr:
        st.error(aerr)
    elif audit.empty:
        st.caption("No expedite / flag requests have been written yet (SC.OPS.ALERT_AGENT_ACTIONS is empty).")
    else:
        if v["restricted"]:
            sup, _ = safe(q_metrics, Q_SUPPLIER_PLANTS)
            visible_sup = set(sup["SUPPLIER_NO"]) if sup is not None else set()
            keep = audit["PLANT_CODE"].isin(v["plants"]) | (audit["PLANT_CODE"].isna() & audit["SUPPLIER_NO"].isin(visible_sup))
            audit = audit[keep].drop(columns=["REASON", "EVIDENCE"])
        a, b = st.columns(2)
        a.metric("Expedite requests", num((audit["ACTION_TYPE"] == "EXPEDITE_PO").sum()), border=True)
        b.metric("Supplier flags", num((audit["ACTION_TYPE"] == "FLAG_SUPPLIER").sum()), border=True)
        st.dataframe(audit, hide_index=True, width="stretch",
                     column_config={"REQUESTED_TS": st.column_config.DatetimeColumn("Requested (UTC)", format="YYYY-MM-DD HH:mm")})
        st.caption("Written only by the owner's-rights procedures EXPEDITE_PO / FLAG_SUPPLIER after the user confirmed in chat; "
                   "no external system is called.")

    st.subheader("Contract terms: signed PDF vs supplier system")
    rec, rerr = safe(q_owner, Q_RECON)
    if rerr:
        st.error(rerr)
    else:
        a, b, c = st.columns(3)
        a.metric("Terms matching", num(rec["MATCHED"].sum()), border=True)
        b.metric("Terms mismatching", num(rec["MISMATCHED"].sum()), border=True)
        c.metric("PDF only (no system field)", num(rec["PDF_ONLY"].sum()), border=True)
        st.bar_chart(rec.set_index("TERM")[["MATCHED", "MISMATCHED", "PDF_ONLY"]], color=["#2E7D32", "#C62828", "#B0BEC5"],
                     horizontal=True, height=260)
        mm, _ = safe(q_owner, Q_RECON_MISMATCH)
        if mm is not None and not mm.empty:
            with st.expander(f"{len(mm)} mismatching contract terms"):
                st.dataframe(mm, hide_index=True, width="stretch")
        st.caption("SC.OPS.DQ_CONTRACT_TERMS_RECON: the PDF is the legal source; neither side is overwritten.")


# -----------------------------------------------------------------------------
# Navigation
# -----------------------------------------------------------------------------
pages = st.navigation([
    st.Page(page_problem, title="The Problem", icon=":material/report:", url_path="problem", default=True),
    st.Page(page_ask, title="Ask", icon=":material/forum:", url_path="ask"),
    st.Page(page_personas, title="One answer, every persona", icon=":material/groups:", url_path="personas"),
    st.Page(page_ontology, title="Ontology & contracts", icon=":material/account_tree:", url_path="ontology"),
    st.Page(page_trust, title="Trust", icon=":material/verified_user:", url_path="trust"),
], position="sidebar")

with st.sidebar:
    st.markdown("### :material/hub: Supply Chain\n**One ontology · one set of metric contracts**")
    vc = viewer_context()
    st.caption(f"Signed in as **{vc['user']}** · role **{vc['role']}**  \n{len(vc['plants'])} plant(s) visible · {RIGHTS}")
    if vc["error"]:
        st.caption(f":red[{vc['error'][:200]}]")
    st.button("Refresh data", on_click=clear_caches, icon=":material/refresh:", width="stretch")
    st.caption(f"Numbers: `{SV}` (contracts {CONTRACT_VERSION}) or `{AGENT}`. No metric is computed in this app.")

pages.run()
