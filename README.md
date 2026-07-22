# End-to-End Analytics Pipeline: Case Management Reporting System

A production-grade analytics pipeline built from scratch on a live SQL Server case management database, delivering organisation-wide reporting for a UK charity through a fully governed dimensional data model in Power BI.

This project documents the complete build from raw transactional data to executive dashboards including SQL architecture, data cleaning, dimensional modelling, DAX measures and data quality frameworks.

---

## The Problem

The organisation had no dedicated analytics capability. Reporting was produced manually from raw CRM exports using Excel, taking days to prepare and producing inconsistent results across teams. There was no single source of truth, no defined KPIs, and no ability to slice or drill into operational data in real time.

**My role:** sole analytics hire, responsible for designing and delivering the entire analytics function from zero.

---

## Scale

| Entity | Count |
|---|---|
| Clients | 83,000+ |
| Enquiries / Cases | 260,000+ |
| Actions / Contacts | 1M+ |
| Raw postcode variants | 19,000+ |
| Raw nationality variants | 496+ |
| Cleaned columns | 13+ |
| DAX measures | 60+ |

---

## Solution Architecture

```
SQL Server (Live CRM Database)
        ↓
Native SQL Statement (Power BI Import Mode)
        ↓
Power Query Staging Layer (cleaning + transformation)
        ↓
Dimensional Data Model (star schema)
        ↓
DAX Measures + Power BI Dashboards
```

---

## Technical Stack

| Layer | Technology |
|---|---|
| Source database | Microsoft SQL Server |
| Query language | T-SQL (CTEs, window functions, EAV pivots) |
| BI platform | Microsoft Power BI (Import mode) |
| Transformation | Power Query M |
| Semantic layer | DAX |
| Postcode enrichment | postcodes.io API + SharePoint cache |

---

## SQL Architecture

The core of the pipeline is a single CTE-based SQL query connecting 9 tables via a chain of natural key joins, pulling over 1 million rows of transactional casework data into a clean, analysis-ready flat structure.

**Key technical challenges solved:**

- **EAV schema unpivoting** - the source database stored client and case attributes in an Entity-Attribute-Value pattern across two tables. Built MAX(CASE WHEN) pivots to flatten 36 client fields and 5 case fields into a wide analytical structure.

- **Household reference logic** - clients exist in complex household relationships with many-to-many links across cases and family members. Implemented ROW_NUMBER() OVER (PARTITION BY) with descending date ordering to resolve the most recent household relationship per client without fan-out.

- **Previous owners** - case ownership history was stored in a separate audit table with no deleted flag. Used STRING_AGG to concatenate previous case owners into a single column per case.

- **Window functions** - calculated Last Action Date, Latest Deadline Date, Case Time and Last Action Notes at action grain using FIRST_VALUE and MAX OVER without pre-aggregating data.

- **Dual-view architecture** - designed two logical views of the data: a full 79-column version including PII for authorised users, and a 67-column analytics version with PII columns excluded for reporting consumers.

- **Soft delete handling** - the source database used inconsistent soft delete patterns across tables (datetime IS NULL vs BIT flag). Mapped and applied the correct deleted filter per table across the full join chain.

→ See [`sql/core_query.sql`](sql/core_query.sql)

---

## Data Cleaning - Power Query

The staging layer applies structured cleaning across 13+ demographic and operational columns, handling years of historical free-text entry before dropdown controls were introduced.

**Data context:**
- Pre-2019 records were migrated from a legacy system
- 2019 to mid-2024: new system running with free-text entry on most fields
- Mid-2024 onwards: controlled dropdowns introduced progressively

As a result, Invalid entry and Missing entry flags reflect historical free-text patterns and genuine data quality gaps — not solely caseworker error.

**Cleaning pattern per column:**

```
Raw value → Lookup merge (controlled list) → Custom column (unmatched variants) → Clean value
```

**DQ signal convention:**

| Signal | Meaning |
|---|---|
| Clean value | Mapped to controlled list |
| `Missing entry` | Null or blank at source |
| `Invalid entry` | Value entered but unclassifiable |
| `null` | New variant not yet mapped — surfaces for review |

**Cleaning coverage:**

| Column | Variants mapped | Notes |
|---|---|---|
| Gender | 200+ | Direction-aware trans handling; 40+ female spelling variants |
| Nationality | 496+ | Country names, demonyms, typos, ISO codes, dual entries |
| Ethnic Origin | 205+ | 19 controlled values |
| Spoken Language | 764 controlled values | Dialect and direction-aware handling |
| Employment Status | 50+ | Unemployment has 12+ spelling variants |
| Housing Status | 424+ | 8 controlled values |
| Housing Provider | 88+ | Named organisations |
| Action Type | 312+ | Channel vs topic distinction, see note below |
| Client Immigration Status | 205+ | 14 controlled values; visa types, abbreviations, legacy codes |
| Enquiry Immigration Status | 16 | Case-level status snapshot |
| Referral Agency | 443+ | Named organisations |
| Signpost Agency | 400+ | Named organisations |
| Postcode | 19,000+ | Three-layer validation, see note below |

**Notable cleaning decisions:**

*Action Type - channel vs topic:*
Before the action type dropdown was introduced, caseworkers recorded the subject of the action (Housing, Benefits, Immigration) rather than the mechanism (Telephone, Email, Advice). The controlled list captures mechanism only. All 270+ subject/topic entries are classified as `Invalid entry`. The stored value `"Face to Face"` maps to the current display label `"Advice"`, the front-end label was renamed without updating the stored database value, affecting 200,000+ historical records.

*Postcode - three-layer validation:*
1. Format normalisation - strips brackets, slashes, dashes, applies O→0/I→1/L→1 substitution, validates inward code format
2. SharePoint cache lookup - previously validated postcodes resolve instantly without an API call
3. postcodes.io API - only runs on cache misses, returns Local Authority, Ward and Region; falls back to prefix-based inference for Scottish and Welsh postcodes

→ See [`powerquery/cleaning/`](powerquery/cleaning/)

---

## Dimensional Model

Star schema with natural key relationships throughout — no surrogate keys.

```
fact_Actions (grain: one row per action/contact)
    ├── dim_Client    [Client Reference]   - active
    ├── dim_Enquiry   [Enquiry Reference]  - active
    ├── dim_Staff     [Name]               - active  (Action By)
    └── dim_Date      [Date]               - active  (Action Date)
```

**Full relationship map:**

| # | From | Cardinality | To | Status |
|---|---|---|---|---|
| 1 | fact_Actions (Action By) | Many to one | dim_Staff (Name) | **Active** |
| 2 | fact_Actions (Action Date) | Many to one | dim_Date (Date) | **Active** |
| 3 | fact_Actions (Client Reference) | Many to one | dim_Client (Client Reference) | **Active** |
| 4 | fact_Actions (Enquiry Reference) | Many to one | dim_Enquiry (Enquiry Reference) | **Active** |
| 5 | fact_Actions (Enquiry Owner) | Many to one | dim_Staff (Name) | Inactive |
| 6 | fact_Actions (Enquiry Closed By) | Many to one | dim_Staff (Name) | Inactive |
| 7 | dim_Enquiry (Client Reference) | Many to one | dim_Client (Client Reference) | Inactive |
| 8 | dim_Enquiry (Enquiry Date) | Many to one | dim_Date (Date) | Inactive |
| 9 | dim_Enquiry (Enquiry Closed Date) | Many to one | dim_Date (Date) | Inactive |
| 10 | dim_Enquiry (Enquiry Owner) | Many to one | dim_Staff (Name) | Inactive |
| 11 | dim_Enquiry (Enquiry Created By) | Many to one | dim_Staff (Name) | Inactive |
| 12 | dim_Enquiry (Enquiry Closed By) | Many to one | dim_Staff (Name) | Inactive |
| 13 | dim_Client (Client Added By) | Many to one | dim_Staff (Name) | Inactive |

Inactive relationships are activated via USERELATIONSHIP() in DAX measures where needed, for example filtering enquiries by their open date, filtering by closed date, or attributing actions to specific staff roles.

**dim_Client** - 83,000+ unique clients, 13 cleaned demographic columns, age banding, postcode-derived geography (Ward, Local Authority, Region).

**dim_Enquiry** - 267,000+ unique cases, IAA classification logic, immigration status, case type, outcome tracking, closure time banding.

**dim_Staff** - built directly from the Users table via SQL query (not derived from fact data), Text.Proper normalisation applied to resolve case inconsistencies across staff name entry points.

**dim_Date** - financial year aware, FY label, FY month number, quarter, week.

<img width="968" height="747" alt="data_model_diagram" src="https://github.com/user-attachments/assets/e732ed78-bd69-4926-9fe9-ea57727ea639" />

---

## DAX Measures

60+ measures organised across six categories:

**Client measures** - Total/New/Returning Clients Served, YoY growth, gender, disability, global majority backgrounds, NRPF, geography, % by Local Authority

**Enquiry measures** - Total/New/Returning Enquiries, Open/Closed, IAA, Avg Days to Closure, Q Answer analysis (INTERSECT-based), % by type, YoY growth

**Action measures** — Total Actions, IAA Actions, Referrals, Signposts, action time (hours), rates, YoY growth

**Staff measures** — workload distribution, avg actions per staff, avg enquiries owned and closed, closed with no attributed staff

**Geography measures** — in service area vs out of service area across clients, enquiries and actions

**Data quality measures** — client record completeness (missing and invalid rates), postcode DQ, staff accountability

→ See [`dax/`](dax/)

---

## Data Quality Framework

Every cleaned column outputs one of three DQ signals. This means the cleaning layer and the reporting layer are unified, no separate DQ pipeline required.

An unpivoted DQ table approach was evaluated but rejected due to volume: unpivoting 13 columns across 83,000+ client records produces 1M+ rows which exceeds practical import mode limits. Instead, DQ is measured directly from cleaned dimension tables using multi-condition OR filters, producing efficient headline metrics. Per-field breakdown is available via visual-level filters on the Data Quality dashboard page.

---

## Impact

- Replaced a multi-day manual reporting process with automated, refresh-on-demand dashboards
- Reduced data latency from weeks to hours
- Established the organisation's first single source of truth for operational and strategic reporting
- Delivered the first KPI framework grounded in verified, direct SQL data sources
- Enabled leadership to monitor performance across multiple offices from a single reporting solution
- Supported a successful business case for Microsoft Fabric and Power BI Premium licensing

---

## Project Structure

```
├── sql/
│   └── core_query.sql              # Full CTE pipeline query (anonymised)
├── powerquery/
│   ├── staging.m                   # Staging layer — trim, clean, type, staff normalisation
│   └── cleaning/
│       ├── gender_clean.m          # 200+ variants, direction-aware trans handling
│       ├── nationality_clean.m     # 496+ variants, controlled list merge
│       ├── postcode_clean.m        # Three-layer: format, cache, postcodes.io API
│       ├── employment_status_clean.m
│       └── action_type_clean.m     # Channel vs topic distinction
├── dax/
│   ├── client_measures.dax
│   ├── enquiry_measures.dax
│   ├── action_measures.dax
│   ├── staff_measures.dax
│   └── dq_measures.dax
├── docs/
│   └── data_model_diagram.png     
└── README.md
```

---

## Key Design Decisions

**Import mode over DirectQuery** - weekly off-hours refresh acceptable for this use case; Import delivers faster dashboard performance for end users and avoids query folding limitations on complex CTEs.

**Native SQL statement over database views** - read-only analytics account had no DDL permissions; native SQL statement in Power BI connection string achieved the same result without requiring CREATE VIEW access.

**Natural keys throughout** - no surrogate keys in the dimensional model; relationships built on Client Reference, Enquiry Reference and Staff Name for transparency and maintainability.

**Cleaning in Power Query, not SQL** - DQ classification (Missing entry / Invalid entry) requires business logic that belongs in the transformation layer, not the source database. Keeping it in Power Query also makes it visible, auditable and editable without database access.

**Single staging query with load enabled** - prevents the 11-minute SQL query from executing multiple times across downstream dimension queries. All dims read from the cached staging result; disabling load caused each dim to trigger a fresh SQL execution.

**dim_Staff from Users table** - initial approach derived staff names from an unpivot of all staff columns across fact and dimension tables. Replaced with a direct query to the Users table, which is cleaner, more stable, and avoids fan-out from the unpivot causing many-to-many relationship issues.

**SharePoint postcode cache** - postcodes.io API calls on 19,000+ distinct raw values would be prohibitively slow on every refresh. A SharePoint-hosted Excel cache stores previously validated postcodes; the API only runs on cache misses, reducing API calls to a small fraction of the total on each refresh.

## Related Projects
- [retail-analytics-dbt](https://github.com/tessogamba/retail-analytics-dbt) - Analytics engineering project built with dbt and Snowflake: staging layers, marts, and data quality testing
- [retail-analytics-tableau](https://github.com/tessogamba/retail-analytics-tableau) - Tableau dashboard created on top of the dbt pipeline
- [financial-analytics-bigquery](https://github.com/tessogamba/financial-analytics-bigquery) - Financial analytics engineering project created with BigQuery and raw SQL
- [financial-analytics-looker](https://github.com/tessogamba/financial-analytics-looker) - Looker Studio dashboard created on top of the BigQuery pipeline

---

*Built by Tess Ogamba · [github.com/tessogamba](https://github.com/tessogamba) · [LinkedIn](https://linkedin.com/in/tessogamba)*
