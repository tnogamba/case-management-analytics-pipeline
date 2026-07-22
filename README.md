# End-to-End Analytics Pipeline: Case Management Reporting System

A production-grade analytics pipeline built from scratch on a live SQL Server case management database, delivering organisation-wide reporting for a UK public sector organisation through a fully governed dimensional data model in Power BI.

This project documents the complete build from raw transactional data to executive dashboards including SQL architecture, data cleaning, dimensional modelling, DAX measures and data quality frameworks.

---

## The Problem

The organisation had no dedicated analytics capability. Reporting was produced manually from raw CRM exports using Excel, taking days to prepare and producing inconsistent results across teams. There was no single source of truth, no defined KPIs, and no ability to slice or drill into operational data in real time.

**My role:** sole analytics hire, responsible for designing and delivering the entire analytics function from zero.

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
| Data catalogue | Custom DB Reference Guide |

---

## SQL Architecture

The core of the pipeline is a single CTE-based SQL query connecting 9 tables via a chain of natural key joins, pulling over 1 million rows of transactional casework data into a clean, analysis-ready flat structure.

**Key technical challenges solved:**

- **EAV schema unpivoting** — the source database stored client and enquiry attributes in an Entity-Attribute-Value pattern across two tables. Built MAX(CASE WHEN) pivots to flatten 36 client fields and 5 enquiry fields into a wide analytical structure.

- **Household reference logic** — clients exist in complex household relationships with many-to-many links across cases and family members. Implemented ROW_NUMBER() OVER (PARTITION BY) with descending date ordering to resolve the most recent household relationship per client without fan-out.

- **Previous owners** — enquiry ownership history was stored in a separate audit table with no deleted flag. Used STRING_AGG to concatenate previous case owners into a single column per enquiry.

- **Window functions** — calculated Last Action Date, Latest Deadline Date, Enquiry Time and Last Action Info at action grain using FIRST_VALUE and MAX OVER without pre-aggregating data.

- **Dual-view architecture** — designed two logical views of the data: a full 79-column version including PII for authorised users, and a 67-column analytics version with PII columns excluded for reporting consumers.

- **Soft delete handling** — the source database used inconsistent soft delete patterns across tables (datetime IS NULL vs BIT flag). Mapped and applied the correct deleted filter per table across the full join chain.

---

## Data Cleaning — Power Query

The staging layer applies structured cleaning across 13+ demographic and operational columns, handling years of historical free-text entries before dropdown controls were introduced.

Each column follows the same pattern:

```
Raw value → Lookup merge (controlled list) → Custom column (unmatched variants) → Clean value
```

**Cleaning coverage:**

| Column | Variants mapped | DQ output |
|---|---|---|
| Gender | 60+ | Male / Female / Non-binary / Other / Prefer not to say / Missing / Invalid |
| Nationality | 440+ | 228 controlled values / Missing / Invalid |
| Ethnic Origin | 205+ | 19 controlled values / Missing / Invalid |
| Spoken Language | 764 control values | Direction-aware dialect handling / Missing / Invalid |
| Employment Status | 50+ | 5 controlled values / Missing / Invalid |
| Housing Status | 424+ | 8 controlled values / Missing / Invalid |
| Housing Provider | 88+ | 8 controlled values / Missing / Invalid |
| Action Type | 312+ | 21 controlled values / Invalid (service topics pre-dating dropdown) |
| Immigration Status | 205+ | 14 controlled values / Missing / Invalid |
| Referral Agency | 443+ | Named organisations / Missing / Invalid |
| Signpost Agency | 400+ | Named organisations / Missing / Invalid |

---

## Dimensional Model

Star schema with natural key relationships throughout — no surrogate keys.

```
fact_Actions (grain: one row per action)
    ├── dim_Client       [Client Reference]  — active
    ├── dim_Enquiry      [Enquiry Reference] — active
    ├── dim_Staff        [Name]              — active (Action By)
    ├── dim_Staff        [Name]              — inactive (Enquiry Owner)
    ├── dim_Staff        [Name]              — inactive (Enquiry Closed By)
    └── dim_Date         [Date]              — active (Action Date)

dim_Enquiry
    ├── dim_Client       [Client Reference]  — inactive
    └── dim_Date         [Date]              — inactive (Enquiry Date)
```

**dim_Client** — 96,000+ unique clients, 13 cleaned demographic columns, age banding, postcode-derived geography (Ward, Local Authority, Region) via API lookup.

**dim_Enquiry** — 60,000+ unique enquiries, IAA classification logic, immigration status, enquiry type, outcome tracking.

**dim_Staff** — built from Users table via direct SQL query, Text.Proper standardisation, volunteer vs staff classification.

**dim_Date** — financial year aware, FY label, FY month number, quarter, week.

---

## DAX Measures

60+ measures organised across six categories:

**Client measures** — Total Clients Served, New Clients Served, Returning Clients, growth %, demographic breakdowns (gender, disability, global majority, NRPF, geography)

**Enquiry measures** — Total, New, Returning, Open, Closed, IAA, Avg Days to Closure, period on period growth

**Action measures** — Total Actions, IAA Actions, Referrals, Signposts, action time, growth %

**Staff measures** — workload distribution, avg actions per staff, avg enquiries owned, closed enquiries per staff

**Geography measures** — West Midlands vs out of service area across clients, enquiries and actions

**Data quality measures** — missing entry rates, invalid entry rates, postcode DQ, staff accountability

---

## Data Quality Framework

Every cleaned column outputs one of three DQ signals:

- **Clean value** — mapped to the controlled list
- **Missing entry** — null or blank at source
- **Invalid entry** — something was entered but it cannot be mapped (noise, wrong field, historical free-text)

This allows DQ reporting without a separate DQ pipeline — the cleaning layer and the reporting layer are unified.

---

## Impact

- Replaced a multi-day manual reporting process with automated, refresh-on-demand dashboards
- Reduced data latency from weeks to hours
- Established the organisation's first single source of truth for operational and strategic reporting
- Delivered the first KPI framework grounded in verified, direct SQL data sources
- Enabled leadership to monitor performance across four offices from a single reporting solution
- Supported a successful business case for Microsoft Fabric and Power BI Premium licensing

---

## Project Structure

```
├── sql/
│   └── core_query.sql          # Full CTE pipeline query (anonymised)
├── powerquery/
│   ├── staging.m               # Staging layer — trim, clean, type, staff normalisation
│   ├── cleaning/
│   │   ├── gender_clean.m
│   │   ├── nationality_clean.m
│   │   ├── ethnic_origin_clean.m
│   │   └── ...
│   └── dimensions/
│       ├── dim_client.m
│       ├── dim_enquiry.m
│       ├── dim_staff.m
│       └── fact_actions.m
├── dax/
│   ├── client_measures.dax
│   ├── enquiry_measures.dax
│   ├── action_measures.dax
│   ├── staff_measures.dax
│   ├── geography_measures.dax
│   └── dq_measures.dax
└── docs/
    ├── architecture_decisions.md
    └── data_model_diagram.png
```

---

## Key Design Decisions

**Import mode over DirectQuery** — 11-minute refresh acceptable for weekly off-hours scheduling; Import delivers faster dashboard performance for end users.

**Native SQL statement over database views** — BIUser account had read-only permissions; native SQL statement in Power BI connection string achieved the same result without requiring DDL permissions.

**Natural keys throughout** — no surrogate keys in the dimensional model; relationships built on Client Reference, Enquiry Reference and Staff Name for transparency and maintainability.

**Cleaning in Power Query, not SQL** — DQ classification (Missing entry / Invalid entry) requires business logic that lives in the transformation layer, not the source database.

**Single staging query with load enabled** — enables query folding and caches the SQL result once per refresh, preventing the 11-minute SQL query from executing multiple times across downstream dimensions.

---

*Built by Tess Ogamba — github.com/tessogamba*
