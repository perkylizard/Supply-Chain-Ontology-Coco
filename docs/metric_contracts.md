# Metric Contracts

**Version:** 1.4 (draft) · **Effective:** 2026-10-03 · **Applies to:** `SC.CONFORMED`, `SC.SEMANTIC`, `SC.AGENTS`

> **v1.4 (2026-10-03):** New named, non-canonical variant **Supplier Contractual OTD %** and its **Supplier Contractual OTD Gap** to the contracted target (§3.1), measured per the signed supplier contract: latest confirmed date + the contract's grace days, early arrivals on time, calendar months, pro-forma for PO lines outside contract validity. §1.1 adds the *Contract terms per PO line* input; §7 / §7.1 add its routing and its period rule. Canonical metric definitions are unchanged; plain "OTD" and "supplier OTD" keep resolving to Customer OTD % and Supplier OTD %.
>
> **v1.3.1 (2026-10-03):** §7.1 adds the no-period default: a question that names no period is answered over **all available history**, and the answer always states the data range (first and last date covered, on the metric's time anchor). Days of Inventory keeps its own default (latest snapshot). Metric definitions are unchanged.
>
> **v1.3 (2026-10-03):** §7.1 adds the relative-period rule: "this / last week, month, quarter, year" resolve to **fiscal** periods through the `SC.CONFORMED.DIM_DATE` offsets; calendar month names and explicit dates use calendar dates and the answer says so; every answer states the period label and its first and last day (Days of Inventory also states its snapshot date). Metric definitions are unchanged.
>
> **v1.2 (2026-10-03):** (1) Days of Inventory: forecast demand is divided by the days the forecast run actually covers, not by 28; fallback to shipped history only when coverage < 14 days (§1.1, §5). (2) Evidence coverage % is defined (§1.3); GR fallback counts as evidence and Supplier OTD % also publishes its GR-fallback share (§3). (3) New named metric **Landed Cost Uplift %** (§6.1); landed-cost known limitations listed (§6). Customer OTD %, Fill Rate % and Supplier OTD % definitions are unchanged.
>
> **v1.1 (2026-10-03):** §1.1 adds two precomputed inputs that `SC.CONFORMED` may build: *Landed-cost components* and *DOI demand inputs*. Metric definitions are unchanged. v1.0 = same text without those two rows.

These contracts are the binding definitions of the canonical supply chain metrics. Entity and attribute names come from [`ontology.md`](ontology.md). The persona variants they replace, and why they differ, are in [`conflict_matrix.md`](conflict_matrix.md). Any dashboard, semantic view or agent that uses a metric name below must produce the number defined here, or use a different name.

> **Default rule:** "on-time delivery", "OTD" or "on-time" with **no qualifier always means Customer OTD %.**
> Inbound performance must be asked for explicitly ("supplier OTD", "vendor on-time", "inbound OTD") and resolves to **Supplier OTD %**. Carrier performance ("carrier on-time") is *Carrier On-Time Arrival*, which is a logistics operational metric and **not** a canonical metric.

| Metric | Grain | Time anchor | Unit | Owner |
|---|---|---|---|---|
| [Customer OTD %](#2-customer-otd-) | OrderLine | Customer commit date | % | Planning (`SC_PLANNER`) |
| [Supplier OTD %](#3-supplier-otd-) | PurchaseOrderLine | Supplier commit date | % | Procurement (`SC_PROCUREMENT`) |
| [Fill Rate %](#4-fill-rate-) | OrderLine | Customer commit date | % | Planning (`SC_PLANNER`) |
| [Days of Inventory](#5-days-of-inventory) | Part × Plant × snapshot date | Snapshot date | days | Planning (`SC_PLANNER`) |
| [Landed Cost per Unit](#6-landed-cost-per-unit) | PurchaseOrderLine × goods receipt | GR posting date | reporting currency per base UoM | Procurement (`SC_PROCUREMENT`) |
| [Landed Cost Uplift %](#61-landed-cost-uplift-) *(v1.2)* | PurchaseOrderLine × goods receipt | GR posting date | % | Procurement (`SC_PROCUREMENT`) |
| [Supplier Contractual OTD %](#31-supplier-contractual-otd--) *(v1.4, variant, not canonical)* | PurchaseOrderLine | Latest supplier-confirmed date, calendar month | % | Procurement (`SC_PROCUREMENT`) |
| [Supplier Contractual OTD Gap](#31-supplier-contractual-otd--) *(v1.4, variant, not canonical)* | Contract (one supplier) | Latest supplier-confirmed date, calendar month | percentage points (fraction) | Procurement (`SC_PROCUREMENT`) |

---

## 1. Rules that apply to every metric

### 1.1 Shared definitions

| Term | Definition |
|---|---|
| **Commit date** | The date *first* confirmed for the line: by us for outbound (`ORDER_LINE.FIRST_COMMIT_DATE`), by the supplier for inbound (first EDI 855 / portal confirmation, `PO_LINE.FIRST_CONFIRMED_DATE`). Later reschedules by the confirming party do **not** move it. Only a change requested by the *receiving* party (the customer for outbound, our buyer for inbound), recorded with a reason code, resets it to the first confirmation issued after that change. |
| **Required qty** | `ORDER_QTY − qty cancelled by the receiving party`, in the Part's base UoM. |
| **Arrival timestamp** | The first available source, in this order: (1) IoT `GEOFENCE_EVENT` arrival at the destination geofence, (2) carrier proof-of-delivery timestamp, (3) carrier "arrived at delivery location" event, (4) *inbound only:* ERP goods-receipt posting date, flagged `GR_FALLBACK`. The chosen source is stored as `ARRIVAL_SOURCE`. |
| **Complete-arrival date** | Local date of the arrival that brings cumulative arrived qty for the line to ≥ required qty. Null while the line is incomplete. |
| **On-time window** | `[commit date − 1 day, commit date]`, inclusive, in local dates. Arriving more than 1 day early is **not** on time. |
| **Due line** | A line whose commit date falls in the reporting period **and** is ≤ the as-of date. Open lines past their commit date stay in the denominator and count as late. |
| **Landed-cost components** *(v1.1)* | Per goods receipt, in reporting currency: unit price (supplier invoice; PO price if the invoice is missing, flagged `PROVISIONAL`), freight allocated from shipment to PO line by max(actual weight, dimensional weight) (by line value if weight is missing, flagged `ALLOC_BY_VALUE`), accessorials, non-recoverable duties and taxes, insurance, received and rejected qty, each with its `PROVISIONAL` flags. `SC.CONFORMED` stores the components only. Totals and the per-unit ratio are computed in the semantic view. |
| **DOI demand inputs** *(v1.1, v1.2)* | Per Part × Plant × snapshot date, in base UoM: consensus forecast qty for snapshot+1 .. snapshot+28 from the latest run on or before the snapshot date (with the number of days that run covers), and actual shipped qty for snapshot−27 .. snapshot. Sums only. Choosing between forecast and fallback, and dividing (forecast by the days covered, fallback by 28), happen in the semantic view. |
| **Contract terms per PO line** *(v1.4)* | Per PO line: the governing `CONTRACT_NO` (SupplierPart → Contract, R6) and that contract's terms as printed on the signed PDF: late-delivery grace days, contracted delivery target (0–1 fraction), valid-from and valid-to dates. Key resolution and lookup only (`NULL` = no contract). The contractual window, the validity test, the population, the ratio and the gap to target are computed in the semantic view. |

### 1.2 Timezone rule

1. Source timestamps land as `TIMESTAMP_TZ` and are normalized to UTC in `SC.CONFORMED`.
2. Before taking a *date* from a timestamp, convert it to the local time of the **receiving location**:
   - inbound → receiving Plant (`PLANT.TIMEZONE`);
   - outbound → customer ship-to time zone; if that is unknown, fall back to the shipping Plant's time zone and flag `TZ_FALLBACK`.
3. Date-only business fields (commit date, GR posting date, snapshot date) are already local business dates and are **never** converted.
4. Period boundaries (week, month, quarter, year) come from `SC.CONFORMED.DIM_DATE` (4-4-5 fiscal calendar, see `ontology.md` §4).

### 1.3 Calculation and display rules

- **Ratio of sums.** Every roll-up (by plant, customer, month and so on) recomputes numerator and denominator at the target level. Never average pre-computed percentages or unit costs.
- **Zero denominator → NULL**, displayed as "n/a". Never show 0% or 100% for an empty population.
- **Storage / display.** Percentages are stored as a decimal fraction 0–1 (`NUMBER(9,6)`) and displayed as % with one decimal. Days are displayed with one decimal; currency with two.
- **Restatement.** A closed period may restate for **30 days** as late arrival or invoice evidence lands, then it is frozen. Frozen values are what get reported externally.
- **Data-quality flags.** Every contributing row carries its flags (`NO_ARRIVAL_EVIDENCE`, `GR_FALLBACK`, `TZ_FALLBACK`, …). Each metric publishes an *evidence coverage %* alongside the value.
- **Evidence coverage %** *(v1.2)*. For the arrival-based metrics (Customer OTD %, Fill Rate %, Supplier OTD %): the share of the metric's population (its denominator rows) **without** `NO_ARRIVAL_EVIDENCE`. `GR_FALLBACK` counts as evidence; Supplier OTD % additionally publishes its *GR-fallback share* (due PO lines whose arrival is the GR posting date ÷ due PO lines). Days of Inventory and Landed Cost per Unit / Uplift % have no arrival evidence; their coverage is defined in §5 and §6.
- **Change control.** Definitions change only with the owner's approval, by a new version of this file. Old versions stay queryable for restated history.

---

## 2. Customer OTD %

| Field | Contract |
|---|---|
| **Name** | Customer OTD % |
| **Business definition** | Share of customer order lines that arrived **complete** at the customer within the on-time window around the date we first committed. This is the default meaning of "on-time delivery". |
| **Formula** | `CUSTOMER_OTD_PCT = on_time_lines ÷ due_lines` |
| **Grain** | OrderLine (`SO_NO` + `LINE_NO`) |
| **Numerator** | `on_time_lines` = count of due lines where `complete_arrival_date BETWEEN commit_date − 1 AND commit_date` |
| **Denominator** | `due_lines` = count of due lines (commit date in period and ≤ as-of date), including lines still open |
| **Filters** | Include: outbound customer sales order lines. Exclude: fully cancelled lines (required qty = 0), return / credit lines (`ORDER_QTY ≤ 0`), free-of-charge samples, intercompany sales (customer flagged intercompany). |
| **Time anchor** | Commit date (`ORDER_LINE.FIRST_COMMIT_DATE`), not order date, ship date or arrival date |
| **Timezone rule** | Complete-arrival date in the customer ship-to time zone (fallback: shipping Plant, flagged `TZ_FALLBACK`). Commit date used as stored. |
| **Null / zero handling** | Partial delivery by commit date → late. No arrival evidence → stays in the denominator, not in the numerator, flagged `NO_ARRIVAL_EVIDENCE`; arrival evidence coverage % is published with the metric. Missing commit date → line excluded and flagged `NO_COMMIT` (reported in the DQ summary). `due_lines = 0` → NULL. |
| **Owner** | Planning / S&OP lead (`SC_PLANNER`). Data steward for arrival evidence: Logistics (`SC_LOGISTICS`). |
| **Synonyms** | **on-time delivery** (unqualified), OTD, OTD %, on-time, customer on-time delivery, outbound OTD, on-time to commit, delivery reliability, line-level OTIF |
| **Commonly confused with** | **On-Time to Request:** measured against `REQUESTED_DATE`; shows how often we meet the customer's ask, not our promise. · **Ship-On-Time:** goods issue vs planned ship date; ERP only, ignores transit. · **Carrier On-Time Arrival:** stop vs booked appointment; rebooked appointments reset the target. · **Supplier OTD %:** inbound, not customer. · **Fill Rate %:** gives partial credit for quantity; Customer OTD is all-or-nothing per line. · **Customer-run OTIF scorecards** (retailer compliance programs): the customer's own windows and case-level rules; reconcile to them, don't substitute them. |

Because partial deliveries count as late, Customer OTD % *is* line-level OTIF. No separate internal "OTIF" metric is published.

---

## 3. Supplier OTD %

| Field | Contract |
|---|---|
| **Name** | Supplier OTD % |
| **Business definition** | Share of purchase order lines that arrived **complete** at our receiving Plant within the on-time window around the date the supplier first confirmed. |
| **Formula** | `SUPPLIER_OTD_PCT = on_time_po_lines ÷ due_po_lines` |
| **Grain** | PurchaseOrderLine (`PO_NO` + `PO_LINE_NO`). This requires the PurchaseOrderLine extension (`ontology.md` §6). Until it exists, compute at PurchaseOrder header grain using `PURCHASE_ORDER.FIRST_CONFIRMED_DATE`, treat a PO as complete when every line is received, and label results `INTERIM`. |
| **Numerator** | `on_time_po_lines` = count of due PO lines where `complete_arrival_date BETWEEN commit_date − 1 AND commit_date` |
| **Denominator** | `due_po_lines` = count of PO lines with commit date in period and ≤ as-of date, including lines still open |
| **Filters** | Include: PO lines for stocked parts from external suppliers. Exclude: service and non-stock lines, stock-transfer / intercompany POs, fully cancelled lines, returns to vendor. |
| **Time anchor** | Supplier commit date (first supplier confirmation). If the supplier never confirmed, use the PO requested delivery date and flag `UNCONFIRMED`. |
| **Timezone rule** | Complete-arrival date in the receiving Plant's time zone (`PLANT.TIMEZONE`). Commit date used as stored. |
| **Null / zero handling** | Arrival from GR posting date is allowed but flagged `GR_FALLBACK` (GR typically lags arrival by 1–2 days, so this can understate OTD). No arrival evidence → late, flagged `NO_ARRIVAL_EVIDENCE`. Under-delivery → incomplete → late; over-delivery does not make a line late. `due_po_lines = 0` → NULL. |
| **Evidence** *(v1.2)* | Published with the metric: evidence coverage % (§1.3: due PO lines without `NO_ARRIVAL_EVIDENCE`; GR fallback counts as evidence) **and** GR-fallback share = due PO lines flagged `GR_FALLBACK` ÷ due PO lines. |
| **Owner** | Procurement / supplier performance lead (`SC_PROCUREMENT`). Stewards: Logistics (arrival evidence), ERP team (goods receipts). |
| **Synonyms** | supplier OTD, vendor OTD, vendor on-time delivery, inbound OTD, supplier on-time, supplier delivery performance, supplier line-level OTIF |
| **Commonly confused with** | **Customer OTD %:** the default for unqualified "OTD". · **Supplier Contractual OTD %** (§3.1): measured against the *latest* confirmed date plus the contract's grace days; this is the basis for penalties and rebates. The canonical metric uses the first commit date and a fixed window so suppliers are comparable. · **Supplier Fill Rate:** gives partial credit for quantity. · **Lead-time adherence:** actual vs quoted lead time (`SUPPLIER_PART.LEAD_TIME_DAYS`); tests the quote, not the confirmation. |

### 3.1 Supplier Contractual OTD % *(v1.4, named variant, not canonical)*

| Field | Contract |
|---|---|
| **Name** | Supplier Contractual OTD % · and its companion **Supplier Contractual OTD Gap** |
| **Business definition** | Share of a contracted supplier's PO lines that arrived **complete** by the deadline its signed contract sets: the latest supplier-confirmed date plus the contract's late-delivery grace days. Answers "is the supplier meeting its contract?" and is the basis for penalties. It is **not** Supplier OTD % and never replaces it. |
| **Formula** | `SUPPLIER_CONTRACTUAL_OTD_PCT = contractual_on_time_po_lines ÷ contractual_due_po_lines` · `SUPPLIER_CONTRACTUAL_OTD_GAP = SUPPLIER_CONTRACTUAL_OTD_PCT − contracted_delivery_target` (negative = below target) |
| **Grain** | PurchaseOrderLine (`PO_NO` + `PO_LINE_NO`). The gap is defined within one contract (one supplier); above that the targets differ, so the target and the gap are NULL. |
| **Numerator** | `contractual_on_time_po_lines` = due lines whose complete-arrival date (§1.1, plant-local) ≤ latest confirmed date + `LATE_GRACE_DAYS`. Early arrivals are on time (the PDF has no early bound: "on or before"). The full required qty must have arrived; partial = late. |
| **Denominator** | `contractual_due_po_lines` = population lines whose latest confirmed date falls in the period and is ≤ the as-of date, including lines still open (open lines past the deadline count as late). |
| **Filters** | The Supplier OTD % population (§3), restricted to PO lines with a governing contract (Contract terms per PO line, §1.1). |
| **Validity (pro-forma)** | The contract terms are applied to **all** PO lines of a contracted supplier, including lines ordered before the contract's valid-from date (pro-forma). A line is *in validity* when its PO date is within [valid-from, valid-to]; that flag is published so the strict, in-validity view stays available. Every answer that includes out-of-validity lines says: *"pro-forma: contract terms (effective <valid-from>) applied to earlier PO lines"*. |
| **Time anchor** | Latest supplier-confirmed date (`PO_LINE.LATEST_CONFIRMED_DATE`; the PO due date if the supplier never confirmed). **Calendar** months, not the fiscal 4-4-5 calendar (the supplier's contract does not know our fiscal calendar); the answer says "calendar month". |
| **Default period** | No period named → the **last complete calendar month** (named in the answer), not all history. |
| **Timezone rule** | Complete-arrival date in the receiving Plant's time zone (§3). Latest confirmed date used as stored. |
| **Null / zero handling** | No arrival evidence → late, flagged `NO_ARRIVAL_EVIDENCE`; evidence coverage % is published (§1.3). `contractual_due_po_lines = 0` → NULL. Target and gap NULL when the population spans more than one contract. |
| **Owner** | Procurement / supplier performance lead (`SC_PROCUREMENT`). Legal source of the terms: the signed contract PDF. |
| **Synonyms** | Supplier Contractual OTD %: contractual OTD, OTD vs contract, supplier contractual OTD, contractual on-time delivery, on-time vs contract. Gap: below contracted target, gap to contracted target, contractual OTD gap, OTD gap vs contract target. **Never** "OTD", "on-time", "on-time delivery", "supplier OTD", "vendor OTD" or "inbound OTD": those stay with Customer OTD % and Supplier OTD %. |
| **Commonly confused with** | **Supplier OTD %** (§3): first commit date, [−1, 0] window, comparable across suppliers; the canonical inbound measure. · **Lead-time adherence.** |

---

## 4. Fill Rate %

| Field | Contract |
|---|---|
| **Name** | Fill Rate % |
| **Business definition** | Share of the quantity customers needed that reached them by the commit date. |
| **Formula** | `FILL_RATE_PCT = Σ filled_qty ÷ Σ required_qty`, where per line `filled_qty = MIN(Σ arrived qty with local arrival date ≤ commit_date, required_qty)` |
| **Grain** | OrderLine (computed per line, then summed) |
| **Numerator** | `Σ filled_qty` in base UoM over due lines |
| **Denominator** | `Σ required_qty` in base UoM over due lines |
| **Filters** | Exactly the same population as Customer OTD %, so the two metrics always reconcile. Outbound only. A substituted part does **not** count as filling the ordered part. |
| **Time anchor** | Commit date (`ORDER_LINE.FIRST_COMMIT_DATE`) |
| **Timezone rule** | Arrival dates in the customer ship-to time zone (fallback: shipping Plant, flagged `TZ_FALLBACK`) |
| **Null / zero handling** | Early arrivals **do** count as filled; Fill Rate measures availability, not timing precision. No arrival evidence → filled qty 0, flagged `NO_ARRIVAL_EVIDENCE`. Over-delivery is capped per line and cannot offset another line. Missing UoM conversion → line excluded, flagged `NO_UOM_CONVERSION`. `Σ required_qty = 0` → NULL. |
| **Owner** | Planning / inventory planning lead (`SC_PLANNER`) |
| **Synonyms** | fill rate, unit fill rate, customer fill rate, demand fill rate, quantity fill rate |
| **Commonly confused with** | **Line fill rate:** % of lines filled completely (close to Customer OTD % without the early bound). · **Order fill rate:** % of orders with every line complete. · **First-pass / from-stock fill rate** (planning variant): first delivery only, later deliveries never count. · **Supplier Fill Rate:** inbound. · **Trailer Utilization:** the logistics "fill rate" (weight or cube ÷ capacity); not a fill rate at all. · **Cycle service level:** the inventory-policy target probability of no stockout; an input to planning, not this outcome. |

---

## 5. Days of Inventory

| Field | Contract |
|---|---|
| **Name** | Days of Inventory (DOI) |
| **Business definition** | How many days the usable stock we own for a part at a plant will cover expected demand. |
| **Formula** | `DOI = usable_inventory_qty ÷ avg_daily_demand_qty` |
| **Grain** | Part × Plant × snapshot date (warehouses summed to their Plant via R14) |
| **Numerator** | `usable_inventory_qty` = Σ `INVENTORY_SNAPSHOT.QTY_BASE_UOM` with `STOCK_STATUS = 'UNRESTRICTED'` across the Plant's warehouses, **plus** owned in-transit qty to the Plant (title passed per Incoterm, including inter-plant transfers in transit) |
| **Denominator** *(v1.2)* | `avg_daily_demand_qty` = consensus forecast qty for the days of snapshot+1 .. snapshot+28 covered by the latest run on or before the snapshot ÷ **the number of days that run covers**. Fallback, when the run covers **fewer than 14 days** (or there is no run): actual shipped qty for the 28 days ending on the snapshot date ÷ 28, flagged `DEMAND_FALLBACK`. *(v1.1 divided the forecast by 28, which understated demand when weekly runs covered only part of the window.)* |
| **Filters** | Include: stocked parts. Exclude: non-stock / expense parts; quarantine, blocked and QA stock; supplier-owned consignment stock; customer-owned stock. Safety stock **is** included. |
| **Time anchor** | Snapshot date. A period's value is the snapshot on the **last day of the period**, not the average over the period. |
| **Timezone rule** | Snapshot = end-of-day stock position in the Plant's local time (`PLANT.TIMEZONE`). Forecast and shipment days are Plant-local dates. |
| **Null / zero handling** | Demand = 0 → NULL, flagged `NO_DEMAND` (shown as "no demand", never infinite or 0). Inventory = 0 with demand > 0 → 0. Negative on-hand (posting backlog) → floored to 0 per warehouse, flagged `NEGATIVE_STOCK`. No forecast and no shipment history → NULL. |
| **Aggregation** | Within one Part: `Σ usable_qty ÷ Σ daily_demand_qty`. Above Part level (family, category, plant), quantities in different UoMs can't be added, so weight both sides by standard cost: `Σ(usable_qty × std_cost) ÷ Σ(daily_demand_qty × std_cost)`. |
| **Evidence** *(v1.2)* | Evidence coverage % = share of the population's Part × Plant snapshots (last snapshot of the period) not flagged `DEMAND_FALLBACK`, `NO_DEMAND` or `NEGATIVE_STOCK`. |
| **Owner** | Planning / supply planning lead (`SC_PLANNER`) |
| **Synonyms** | days of inventory, DOI, days of supply, DOS, days of cover, days of coverage, inventory coverage, days on hand (unqualified). *Weeks of supply* = DOI ÷ 7. |
| **Commonly confused with** | **DIO (Days Inventory Outstanding):** financial, average inventory value ÷ COGS × 365, backward-looking, Finance-owned. · **DC Days on Hand:** physical WMS stock in every status ÷ trailing outbound volume. · **Inventory turns:** COGS ÷ average inventory; ≈ 365 ÷ DIO, *not* 365 ÷ DOI. · **Target / safety-stock days:** planned policy values, not a measured position. |

---

## 6. Landed Cost per Unit

| Field | Contract |
|---|---|
| **Name** | Landed Cost per Unit |
| **Business definition** | The actual all-in cost of getting one unit of a purchased part into our receiving Plant. |
| **Formula** | `LANDED_COST_PER_UNIT = total_landed_cost ÷ received_qty`, where `total_landed_cost = invoiced_price × received_qty + allocated_freight + accessorials + non_recoverable_duties_and_taxes + insurance` |
| **Grain** | PurchaseOrderLine × goods receipt (each receipt has its own landed cost). Requires the PurchaseOrderLine extension and an inbound Shipment link (`ontology.md` §6). |
| **Numerator** | `total_landed_cost` in reporting currency, built from the components above |
| **Denominator** | `received_qty` in base UoM: GR qty net of return-to-vendor reversals against that receipt |
| **Filters** | Include: external purchases of stocked parts. Exclude: services, intercompany / stock-transfer receipts (transfer pricing is a separate topic), no-charge sample receipts that aren't on a priced PO line. |
| **Time anchor** | GR posting date |
| **Timezone rule** | GR posting date is a Plant-local business date (no conversion). FX: Finance's daily closing rate for the GR posting date, converted to reporting currency. |
| **Null / zero handling** | Supplier invoice not yet received → PO price, flagged `PROVISIONAL`. Freight invoice not yet received → accrue from the contract / rate card, flagged `PROVISIONAL`. Customs entry missing → contract duty rate × customs value, flagged `PROVISIONAL`. Actuals replace estimates as they arrive; anything still `PROVISIONAL` after 90 days is also flagged `STALE_ACCRUAL`. Recoverable taxes (input VAT / GST) are excluded. `received_qty = 0` → NULL. |
| **Allocation** | Shipment-level freight and accessorials are allocated to PO lines by max(actual weight, dimensional weight). Missing weight → allocate by line value, flagged `ALLOC_BY_VALUE`. |
| **Aggregation** | Within one Part: `Σ total_landed_cost ÷ Σ received_qty` (quantity-weighted). Never across different Parts; above Part level report total landed cost or Landed Cost Uplift % (§6.1) instead. |
| **Evidence** *(v1.2)* | Evidence coverage % = receipts in the population neither `PROVISIONAL` nor `ALLOC_BY_VALUE` ÷ (receipts in the population + receipts of stock PO lines whose supplier part number maps to no Part, `UNMAPPED_PART`). Unmapped receipts can't carry a per-Part cost, so they are excluded from the metric but count as *not covered*. |
| **Known limitations** *(v1.2, accepted)* | (1) No contract / rate-card freight accrual and no contract-duty estimate exist yet: a missing freight or duty component counts as **0** (receipt flagged `PROVISIONAL`), so `PROVISIONAL` receipts understate landed cost. (2) No return-to-vendor documents exist: `received_qty` is the GR qty, not netted. (3) `STALE_ACCRUAL` (PROVISIONAL > 90 days) is not flagged yet. (4) Insurance has no source system and counts as 0. |
| **Owner** | Procurement / sourcing lead (`SC_PROCUREMENT`). Finance approves FX and duty treatment. |
| **Synonyms** | landed cost, landed cost per unit, actual landed cost, unit landed cost, total landed cost per unit, LCU, delivered cost per unit |
| **Commonly confused with** | **Standard Landed Cost:** planning's frozen standard cost + freight uplift %. · **Quoted Landed Cost:** sourcing's expected cost at contract award. · **Freight Cost per Unit:** one component only (logistics). · **Standard cost / PO price:** product price only. · **PPV (purchase price variance):** invoice price vs standard; a variance, not a cost. · **TCO (total cost of ownership):** adds quality, carrying and admin costs; broader than landed cost. |

### 6.1 Landed Cost Uplift % *(v1.2)*

| Field | Contract |
|---|---|
| **Name** | Landed Cost Uplift % |
| **Business definition** | How much the cost of getting purchased goods into our plants adds on top of what we paid the supplier for them. The above-Part companion of Landed Cost per Unit. |
| **Formula** | `LANDED_COST_UPLIFT_PCT = total_landed_cost ÷ invoiced_product_cost − 1` |
| **Grain** | PurchaseOrderLine × goods receipt, same as Landed Cost per Unit |
| **Numerator** | `total_landed_cost` as in §6 |
| **Denominator** | `invoiced_product_cost` = invoiced unit price × received qty (PO price when the invoice is missing, `PROVISIONAL`), reporting currency |
| **Filters** | Exactly the population of Landed Cost per Unit, so the two reconcile. |
| **Time anchor** | GR posting date |
| **Null / zero handling** | `invoiced_product_cost = 0` → NULL. The §6 known limitations apply (missing freight / duty count as 0, so `PROVISIONAL` receipts understate the uplift). |
| **Aggregation** | Ratio of sums of currency amounts, valid at any level, including across Parts (category, supplier, plant, period). |
| **Evidence** | Same evidence coverage % as Landed Cost per Unit. |
| **Owner** | Procurement / sourcing lead (`SC_PROCUREMENT`) |
| **Synonyms** | landed cost uplift, landed-cost uplift %, landed cost uplift percent, uplift over invoiced price, landed cost markup |
| **Commonly confused with** | **Standard freight uplift %:** planning's fixed percentage in Standard Landed Cost, not a measured value. · **PPV:** invoice price vs standard cost. · **Freight Cost per Unit:** one component, per unit. |

---

## 7. Question resolution

How the semantic layer and agents in `SC.SEMANTIC` / `SC.AGENTS` must map user phrasing:

| User says | Resolves to | Note |
|---|---|---|
| "on-time delivery", "OTD", "on-time %", "are we delivering on time?" | **Customer OTD %** | The default rule; no qualifier needed |
| "supplier / vendor / inbound on-time", "supplier OTD" | **Supplier OTD %** | |
| "contractual OTD", "OTD vs contract", "supplier contractual OTD" | Supplier Contractual OTD % | *(v1.4)* Variant, not canonical: say so; calendar month; state pro-forma |
| "below contracted target", "gap to contracted target", "which suppliers are below their contracted OTD target" | Supplier Contractual OTD Gap (with Supplier Contractual OTD % and the target) | *(v1.4)* Per supplier / contract only |
| "carrier on-time", "on-time pickup" | Carrier On-Time Arrival | Not canonical; say so in the answer |
| "on-time to request", "met requested date" | On-Time to Request | Not canonical; say so in the answer |
| "fill rate", "unit fill rate" | **Fill Rate %** | |
| "supplier fill rate" | Supplier Fill Rate | Variant; inbound |
| "trailer fill", "truck fill rate", "load utilization" | Trailer Utilization | Not a fill rate |
| "days of inventory / supply / cover", "days on hand" | **Days of Inventory** | |
| "DIO", "days inventory outstanding" | DIO | Financial; Finance-owned |
| "landed cost", "cost per unit delivered" | **Landed Cost per Unit** | |
| "landed cost uplift", "uplift over invoice", "landed cost by category / supplier" (above Part level) | **Landed Cost Uplift %** | *(v1.2)* Landed Cost per Unit is only defined within one Part |
| "freight cost per unit" | Freight Cost per Unit | Component only |

### 7.1 Relative and named periods *(v1.3)*

Periods are always resolved through `SC.CONFORMED.DIM_DATE` (4-4-5 fiscal calendar, §1.2 rule 4), never by date arithmetic on today's date. The as-of date is today (the session `CURRENT_DATE()`).

| User says | Resolves to | `DIM_DATE` filter |
|---|---|---|
| "this week / month / quarter / year", "week / month / quarter / year to date", "WTD / MTD / QTD / YTD" | The **current fiscal** period, from its first day up to the as-of date (partial) | `FISCAL_WEEK_OFFSET` / `FISCAL_MONTH_OFFSET` / `FISCAL_QUARTER_OFFSET` / `FISCAL_YEAR_OFFSET` `= 0` |
| "last / previous week / month / quarter / year" | The whole **previous fiscal** period | `..._OFFSET = -1` |
| "last N weeks / months / quarters / years" | The N most recent **completed** fiscal periods (the current one is excluded) | `..._OFFSET BETWEEN -N AND -1` |
| Unqualified "week", "month", "quarter", "year" in a trend or breakdown | Fiscal periods | group by the fiscal label |
| A calendar month name ("September", "Sep 2026"), "calendar month / quarter / year", or explicit dates ("1-30 September") | **Calendar** dates. A month name without a year means its most recent occurrence that has started on or before the as-of date. | `YEAR` + `MONTH` (or `QUARTER`), or a `DATE` range |
| **No period named** *(v1.3.1)* ("vendor OTD by supplier", "landed cost by category") | **All available history** up to the as-of date. Exception: Days of Inventory = the latest snapshot (§5). | no date filter |
| Any period for **Supplier Contractual OTD % / Gap** *(v1.4)* | **Calendar** periods only ("month" = calendar month); no period named = the **last complete calendar month** | `CALENDAR_MONTH_OFFSET = -1` (or `YEAR` + `MONTH`) on the latest-confirmed-date role |

**Data range** *(v1.3.1)*: the first and last date of the metric's population on its time anchor, computed by the semantic view (never by the caller):

| Metric | Data range = first / last … |
|---|---|
| Customer OTD %, Fill Rate % | commit date of the due order lines |
| Supplier OTD % | supplier commit date of the due PO lines |
| Supplier Contractual OTD % / Gap *(v1.4)* | latest confirmed date of the contractual due PO lines |
| Landed Cost per Unit, Landed Cost Uplift % | GR posting date of the receipts in the population (plus `UNMAPPED_PART` receipts) |
| Days of Inventory | snapshot date (the value itself is the last snapshot of the period; history range of snapshots on request) |

**Every answer states the period it used**:
1. the period label: fiscal `FY2026-W39` / `FY2026-P09` / `FY2026-Q3` / `FY2026`, or calendar `Sep 2026`; with no period named, "all history" *(v1.3.1)*;
2. its first and last day (for a current, partial period, also "through <as-of date>"); with no period named, the data range (first and last date covered) *(v1.3.1)*;
3. for a calendar period, the words "calendar month" (or quarter / year), "not fiscal";
4. for Days of Inventory, also the snapshot date the value is taken from (§5 time anchor: the last snapshot of the period; "now" / no period = the latest snapshot).

Example shape: *"Customer OTD % for Pune last month (fiscal FY2026-P09, 24 Aug - 27 Sep 2026) was nn.n% (on-time lines / due lines; evidence coverage nn.n%)."*
