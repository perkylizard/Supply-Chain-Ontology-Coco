# Supply Chain Metric Conflict Matrix

**Problem:** ERP, logistics, supplier and IoT systems each record a slightly different version of the same business event (an order being *promised*, *shipped*, *arrived*, *received*, *paid for*). Planning, procurement and logistics each build "their" KPI on the system they trust, so the same metric name returns different numbers in different meetings.

**Goal of the ontology:** one canonical definition per metric, bound to explicit source events, plus *renamed* persona variants so nobody has to give up a view they legitimately need.

> Table names below are typical/illustrative for each source system. They land in the `SC.RAW_*` schemas created by `sql/00_setup.sql`.

---

## 1. Source systems and typical tables

| # | Source system | Landing schema | Typical products | Typical tables | Grain | Metric-relevant fields |
|---|---|---|---|---|---|---|
| 1 | **ERP** | `SC.RAW_ERP` | SAP S/4HANA, Oracle EBS / Fusion, Microsoft D365 | `SALES_ORDER_HEADER`, `SALES_ORDER_LINE`, `DELIVERY` (goods issue), `PURCHASE_ORDER_HEADER`, `PURCHASE_ORDER_LINE`, `GOODS_RECEIPT`, `INVENTORY_BALANCE`, `MATERIAL_MASTER`, `STANDARD_COST`, `PLANT`, `CUSTOMER`, `GL_COGS`, `DEMAND_FORECAST` | Order line, PO line, material × plant × day | Requested / confirmed dates, ordered / shipped / received qty, goods-issue and GR posting dates, standard cost, base UoM |
| 2 | **Logistics** (TMS / WMS / carriers) | `SC.RAW_LOGISTICS` | Oracle OTM, Blue Yonder, Manhattan, carrier EDI / APIs | `SHIPMENT`, `SHIPMENT_LINE`, `SHIPMENT_STOP`, `APPOINTMENT`, `CARRIER_EVENT` (EDI 214), `PROOF_OF_DELIVERY`, `FREIGHT_INVOICE` (EDI 210), `FREIGHT_INVOICE_CHARGE`, `CARRIER`, `LANE`, `WMS_INVENTORY`, `WMS_PICK` | Shipment, stop, event | Appointment window, ETA, actual arrival, POD timestamp, weight / cube, linehaul / fuel / accessorial charges |
| 3 | **Supplier** (SRM / portal / EDI) | `SC.RAW_SUPPLIER` | SAP Ariba, Coupa, supplier portals, EDI VAN | `SUPPLIER`, `SUPPLIER_SITE`, `PO_ACKNOWLEDGEMENT` (EDI 855), `ADVANCE_SHIP_NOTICE` (EDI 856), `SUPPLIER_INVOICE` (EDI 810), `CONTRACT_PRICE`, `CONTRACT_TERMS` (Incoterm, lead time, tolerances), `SUPPLIER_SCORECARD` | PO-line acknowledgement, ASN line | Supplier-confirmed date (first and latest), ASN ship date / qty, contract price, Incoterm, quoted lead time |
| 4 | **IoT / telemetry** | `SC.RAW_IOT` | GPS trackers, reefer sensors, RFID and dock-door readers | `DEVICE`, `DEVICE_ASSIGNMENT` (device ↔ shipment / asset), `GPS_PING`, `GEOFENCE_EVENT` (arrive / depart), `DOCK_DOOR_EVENT`, `RFID_READ`, `SENSOR_READING` (temperature, humidity, shock) | Device × timestamp | Physical arrival / departure time, dwell time, condition excursions |

Supporting: `SC.RAW_DOCS.CONTRACTS` holds the contract PDFs that are the legal source of Incoterms, tolerances and price terms referenced in `CONTRACT_TERMS`.

---

## 2. Why the same metric produces different answers

| Conflict dimension | Example |
|---|---|
| **Reference date** | Customer *requested* date vs *first* confirmed date vs *latest* re-confirmed date vs carrier *appointment* |
| **"Actual" event** | ERP goods issue (shipped) vs carrier POD vs IoT geofence arrival vs ERP goods-receipt posting (often 1–2 days after arrival) |
| **Grain** | Order line vs PO line vs shipment vs stop vs item × site |
| **Denominator** | Lines *due* in period (open late lines count) vs lines *completed* in period (open late lines silently disappear) |
| **Tolerance window** | 0 days vs −3/+0 days vs ±30 minutes |
| **Quantity basis** | Units vs cases vs pallets vs weight vs value; base UoM vs order UoM |
| **Valuation / currency** | Standard cost vs PO price vs invoiced price; FX at order date vs receipt date |
| **Scope / exclusions** | Customer-caused delays, quarantine stock, cancelled qty, owned vs non-owned in-transit |
| **Time zone** | Carrier HQ time vs ERP server time vs receiving-site local time |
| **Name collision** | "Fill rate" means order fulfillment to planning but trailer utilization to logistics |

---

## 3. Conflict matrix

| Metric | Planning (`SC_PLANNER`) | Procurement (`SC_PROCUREMENT`) | Logistics (`SC_LOGISTICS`) | Canonical |
|---|---|---|---|---|
| **On-Time Delivery (OTD)** | **Formula:** SO lines fully shipped ≤ customer *requested* date ÷ SO lines shipped<br>**Source:** ERP `SALES_ORDER_LINE.REQUESTED_DATE` vs `DELIVERY.GOODS_ISSUE_DATE`<br>**Grain:** outbound SO line; partial shipment = late<br>**Why:** measures the promise to the customer for S&OP. Goods issue is the last event planning sees in ERP, so *ship* date stands in for *delivery* date. | **Formula:** PO lines received within −3 / +0 days of the *latest* supplier-confirmed date ÷ PO lines received<br>**Source:** ERP `GOODS_RECEIPT.POSTING_DATE` vs `PO_ACKNOWLEDGEMENT.CONFIRMED_DATE` (latest revision)<br>**Grain:** inbound PO line; early within tolerance = on time<br>**Why:** supplier scorecards are judged against what the supplier confirmed, and GR is the event that triggers payment. Re-confirmations quietly reset the clock, and open overdue lines drop out of the denominator. | **Formula:** stops arrived ≤ appointment window end + 30 min ÷ stops delivered<br>**Source:** `CARRIER_EVENT` / IoT `GEOFENCE_EVENT` arrival vs `APPOINTMENT.WINDOW_END`<br>**Grain:** shipment stop; excludes delays coded as shipper- or consignee-caused<br>**Why:** measures carrier performance against the booked slot. A rebooked appointment counts as a new target. | **On-Time Delivery** = order lines whose last unit physically arrived within [commit − 1 day, commit] ÷ order lines with a commit date in the period (open overdue lines count as late).<br>**Commit date:** the *first* confirmed date (customer: first SO confirmation; supplier: first PO acknowledgement), never a rescheduled one.<br>**Actual:** IoT geofence arrival → carrier POD → ERP GR posting date (fallback, flagged as lower confidence).<br>**Grain:** order line with a `DIRECTION` attribute (inbound / outbound); dates in the receiving site's local time.<br>**Renamed variants:** *Ship-On-Time* (goods issue vs plan), *Carrier On-Time Arrival* (stop vs appointment), *Supplier OTD* (canonical formula, inbound slice). |
| **Fill Rate** | **Formula:** units shipped from stock on the *first* delivery ÷ units ordered<br>**Source:** ERP `SALES_ORDER_LINE.ORDER_QTY`, `DELIVERY.SHIPPED_QTY`<br>**Grain:** outbound units; backorders filled later don't count<br>**Why:** tests the safety-stock policy: was the inventory there when demand arrived? | **Formula:** units received ÷ units ordered on the PO, cumulative over the PO's life<br>**Source:** ERP `PURCHASE_ORDER_LINE.ORDER_QTY` vs `GOODS_RECEIPT.QTY` (or `ADVANCE_SHIP_NOTICE.QTY` before receipt)<br>**Grain:** inbound PO line; over-shipments often uncapped, so the rate can exceed 100%<br>**Why:** supplier reliability. Any eventual receipt counts, however late. | **Formula:** loaded weight or cube ÷ trailer / container capacity (or lines picked complete ÷ lines released in WMS)<br>**Source:** `SHIPMENT.GROSS_WEIGHT`, `SHIPMENT.CUBE`, equipment capacity; `WMS_PICK`<br>**Grain:** shipment / equipment<br>**Why:** logistics uses "fill rate" for asset utilization. Same name, entirely different concept. | **Fill Rate (unit, outbound)** = Σ min(qty delivered by commit date, qty ordered) ÷ Σ qty ordered, over order lines with a commit date in the period.<br>**Rules:** base UoM; customer-cancelled qty removed from the denominator; substitutions count as unfilled; over-delivery capped at 100% per line.<br>**Renamed variants:** *Supplier Fill Rate* (same formula on inbound PO lines), *Trailer Utilization* (not a fill rate), *Pick Completeness* (WMS). |
| **Days of Inventory (DOI)** | **Formula:** (unrestricted on-hand + in-transit) ÷ average daily *forecast* demand, next 4 weeks<br>**Source:** ERP `INVENTORY_BALANCE`, `DEMAND_FORECAST`<br>**Grain:** units, item × site, forward-looking<br>**Why:** drives replenishment. What matters is how long current stock will last against future demand. | **Formula:** average inventory *value* ÷ COGS × 365 (financial DIO)<br>**Source:** ERP `INVENTORY_BALANCE` × `STANDARD_COST`, `GL_COGS`<br>**Grain:** value at standard cost, company / category level, trailing 12 months; includes owned in-transit by Incoterm (e.g. FOB origin)<br>**Why:** working capital. Feeds payment-term and consignment negotiations with suppliers. | **Formula:** units (or pallets) on hand in the DC ÷ average daily *outbound* units, trailing 30 days<br>**Source:** `WMS_INVENTORY` (all statuses incl. quarantine / blocked), `SHIPMENT_LINE`<br>**Grain:** physical site only, no in-transit, backward-looking<br>**Why:** space and labor planning. Anything occupying a slot counts, whatever its stock status. | **Days of Inventory** = (unrestricted on-hand + owned in-transit) ÷ average daily demand, in base UoM, at item × location × snapshot date.<br>**Demand:** consensus forecast for the next 28 days; fallback to trailing 28-day actual shipments (flagged).<br>**Owned in-transit:** title transferred per Incoterm.<br>**On-hand:** ERP book quantity, reconciled to WMS physical quantity as a data-quality check.<br>**Renamed variants:** *DIO* (financial, value ÷ COGS, Finance-owned), *DC Days on Hand* (physical, WMS). |
| **Landed Cost** | **Formula:** standard cost + standard freight uplift % (e.g. +6%)<br>**Source:** ERP `STANDARD_COST`, `MATERIAL_MASTER`<br>**Grain:** per unit, frozen for the fiscal year<br>**Why:** S&OP and margin planning need a stable cost that doesn't move with every shipment. | **Formula:** contract / PO price + quoted freight per Incoterm + duty rate × customs value<br>**Source:** `CONTRACT_PRICE`, `CONTRACT_TERMS`, `PURCHASE_ORDER_LINE`<br>**Grain:** per unit, *quoted* at award time; excludes accessorials<br>**Why:** sourcing decisions compare suppliers on expected total cost before anything ships. | **Formula:** Σ actual freight-invoice charges (linehaul + fuel + accessorials + detention / demurrage) ÷ units or kg shipped<br>**Source:** `FREIGHT_INVOICE`, `FREIGHT_INVOICE_CHARGE`, `SHIPMENT`<br>**Grain:** per shipment / kg; freight only, no product cost<br>**Why:** logistics owns the freight budget, so to them "landed cost" means the cost to land the goods. | **Actual Landed Cost per Unit** = (invoiced unit price × qty + allocated actual freight + accessorials + non-recoverable duties & taxes + insurance) ÷ received qty.<br>**Allocation:** freight shared from shipment to PO line by max(actual weight, dimensional weight).<br>**Grain:** PO line × goods receipt; base UoM; reporting currency at receipt-date FX rate.<br>**Renamed variants:** *Standard Landed Cost* (planning), *Quoted Landed Cost* (sourcing), *Freight Cost per Unit* (logistics component). |

---

## 4. Worked example: one order line, three answers

Outbound SO line, 100 units. Customer requested **10-Mar**; first confirmed **10-Mar**; rescheduled to **12-Mar** after a shortage.
Shipment 1: 60 units, goods issue 9-Mar, arrived 10-Mar within appointment.
Shipment 2: 40 units, goods issue 11-Mar, appointment 12-Mar 08:00–10:00, IoT geofence arrival 12-Mar 09:10.

| View | OTD result | Fill Rate result | Reason |
|---|---|---|---|
| Planning | Late | 60% | Last goods issue (11-Mar) after requested date; only 60 units on the first delivery |
| Procurement-style rule | On time | 100% | Measured against the *latest* confirmed date (12-Mar); all units eventually delivered |
| Logistics | 100% (2 / 2 stops) | n/a | Both stops arrived inside their booked appointments |
| **Canonical** | **Late** | **60%** | Last unit arrived 12-Mar, outside [9-Mar, 10-Mar] around the *first* commit date; 60 of 100 units delivered by the commit date |

Logistics wasn't wrong, the carrier did perform. The customer was still served late, and the canonical layer makes that visible while keeping *Carrier On-Time Arrival* as a separate, correctly named metric.
