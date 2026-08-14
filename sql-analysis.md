# SQL Analysis — Superstore

Companion analysis to the Power BI dashboard in this repository. The dashboard surfaced that discounting looked like the cause of the profit leak; this analysis tests that hypothesis properly in SQL and quantifies the threshold at which discounting stops being worth it.

**Database:** PostgreSQL 18 · **Queries:** [`analysis.sql`](analysis.sql)

---

## Headline result

Discounting does not gradually erode margin — **it crosses a cliff at 25%.**

| Discount band | Line items | Sales | Profit | Margin |
|---|---|---|---|---|
| 0% | 4,798 | $1,087,908 | $320,988 | **29.51%** |
| 1–15% | 146 | $81,928 | $10,448 | 12.75% |
| 16–25% | 3,657 | $764,594 | $90,337 | 11.82% |
| 26–40% | 460 | $234,138 | −$35,817 | **−15.30%** |
| 40%+ | 933 | $128,632 | −$99,559 | **−77.40%** |

Undiscounted business runs at 29.5% margin. Every discounted band is worse, and everything above 25% is loss-making outright. The 1,393 line items discounted above 25% destroy **$135,376** in profit — nearly half of what the company actually earned.

This is the single most actionable number in the dataset: it converts "discount less" into a specific, testable policy rule.

---

## The pattern holds at every level of aggregation

The same relationship — higher average discount, lower margin — appears independently in four different cuts of the data. That consistency is what makes discounting a plausible cause rather than a coincidence.

**By sub-category**

| Sub-category | Profit | Margin | Avg. discount |
|---|---|---|---|
| Tables | −$17,725 | −8.6% | 26.1% |
| Bookcases | −$3,473 | −3.0% | 21.1% |
| Supplies | −$1,189 | −2.5% | 7.7% |

**By region**

| Region | Margin | Avg. discount |
|---|---|---|
| West | 14.94% | 10.9% |
| East | 13.48% | 14.5% |
| South | 11.93% | 14.7% |
| Central | 7.92% | 24.0% |

Ranking regions by discount rate produces the exact inverse of ranking them by margin.

**By category**

| Category | Margin | Avg. discount |
|---|---|---|
| Technology | 17.40% | 13.2% |
| Office Supplies | 17.04% | 15.7% |
| Furniture | 2.49% | 17.4% |

**By customer**

| | Loss-making | Profitable |
|---|---|---|
| Customers | 155 | 638 |
| Share | 19.5% | 80.5% |
| Avg. discount | **23.8%** | **13.8%** |

Roughly one customer in five costs the business money, and those customers receive discounts averaging ten percentage points higher than profitable ones. Notably, 23.8% sits right at the 25% cliff identified above.

Supplies is the one partial exception — it loses money at only 7.7% average discount, suggesting a cost or pricing issue specific to that line rather than a discounting one. Worth separate investigation.

---

## Growth

| Year | Revenue | YoY |
|---|---|---|
| 2014 | $484,247 | — |
| 2015 | $470,533 | −2.8% |
| 2016 | $609,206 | +29.5% |
| 2017 | $733,215 | +20.4% |

Revenue grew 51.4% across the period, with a contraction in 2015 before two strong years. Profit did not keep pace, which is what prompted the margin investigation above.

---

## Customer retention

Cohorts are defined by month of first purchase. Taking all 2014 cohorts (595 customers) and following them forward:

| Months since first purchase | Active customers | Retention |
|---|---|---|
| 0 | 595 | 100.0% |
| 3 | 53 | 8.9% |
| 6 | 63 | 10.6% |
| 12 | 67 | 11.3% |

Monthly retention sits around 9–11% and, unusually, **rises slightly over time rather than decaying.** This is characteristic of low-frequency purchasing rather than churn: customers average 6.3 orders across four years, so in any given month most are simply between purchases rather than lost. Retention curves are the wrong lens for this business — a rolling 12-month active-customer measure would be more meaningful.

Worth stating plainly because the naive read of a 9% month-3 retention figure would be "we have a severe churn problem," and that conclusion would be wrong.

---

## Recommendations

1. **Cap discounts at 25%.** This is where margin turns negative, not a round number. The 1,393 line items above that threshold account for $135,376 of destroyed profit.
2. **Review Central's discount authority.** Central discounts at 24.0% against West's 10.9% and returns roughly half the margin. This is the largest single addressable gap.
3. **Audit the 155 loss-making customers** before renewing terms — they average 23.8% discount and are unprofitable in aggregate.
4. **Investigate Supplies separately.** It is the only loss-maker not explained by discounting, so the cause is likely cost or pricing.
5. **Validate with a controlled regional test** measuring volume elasticity against margin recovery before rolling out company-wide. The analysis establishes correlation across four independent cuts; it does not establish how much volume would be lost by discounting less.

---

## Technical notes

**Schema design**

- `postal_code` stored as `TEXT`, not `INTEGER` — US zip codes carry leading zeros (`02116`), which integer storage silently destroys. Zip codes are identifiers, not quantities.
- `sales` and `profit` as `NUMERIC(12,4)` rather than floating point, so rounding errors do not accumulate across 9,994 rows of currency.

**Loading**

- Source CSV is Windows-1252 encoded, not UTF-8 — it fails to parse on smart quotes and non-breaking spaces in product names. Converted to UTF-8 before `COPY`.
- `SET datestyle = 'MDY'` is required before loading. The dates are US-format, and without this Postgres silently misreads any date where the day is 12 or lower — `11/8/2016` becomes 8 November instead of 11 August. No error is raised.
- The load was reconciled against independently computed control totals (9,994 rows · 5,009 orders · 793 customers · $2,297,200.86) before any analysis was run.

**Query techniques**

- `COUNT(DISTINCT order_id)` rather than `COUNT(*)` — the table is at line-item grain, so a naive count returns 9,994 transactions where the business has 5,009 orders.
- `HAVING` to filter aggregated groups (loss-making sub-categories) rather than `WHERE`, which filters rows before aggregation.
- `CASE` bucketing to test the discount hypothesis directly, which is what surfaced the 25% threshold — a simple correlation would have shown a relationship but not where it breaks.
- `LAG()` and `SUM() OVER (ORDER BY ...)` for year-on-year growth and running totals without self-joins.
- Chained CTEs for cohort retention: first purchase per customer → active months → month offset via `AGE()` → join back to cohort sizes.
- `NTILE(5)` for RFM quintile scoring in the customer segmentation query.
- `FILTER (WHERE ...)` for conditional aggregation in a single pass over the customer summary.

---

*Analysis by Tanush Thakran · [Power BI dashboard](README.md)*
