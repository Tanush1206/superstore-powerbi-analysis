DROP TABLE IF EXISTS orders;

CREATE TABLE orders (
    row_id        INTEGER,
    order_id      TEXT,
    order_date    DATE,
    ship_date     DATE,
    ship_mode     TEXT,
    customer_id   TEXT,
    customer_name TEXT,
    segment       TEXT,
    country       TEXT,
    city          TEXT,
    state         TEXT,
    postal_code   TEXT,
    region        TEXT,
    product_id    TEXT,
    category      TEXT,
    sub_category  TEXT,
    product_name  TEXT,
    sales         NUMERIC(12,4),
    quantity      INTEGER,
    discount      NUMERIC(5,2),
    profit        NUMERIC(12,4)
);


SET datestyle = 'MDY';

COPY orders
FROM 'C:\superstore\Superstore_UTF8.csv'
WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');



-- ============================================================
-- Superstore SQL Analysis
-- PostgreSQL 18
--
-- Question: the business is profitable overall (12.47% margin)
-- but some segments lose money. Where, and why?
-- ============================================================


-- ------------------------------------------------------------
-- 0. VALIDATION
-- Always reconcile against known totals before analysing.
-- Expected: 9994 rows | 5009 orders | 793 customers
--           2014-01-03 to 2017-12-30 | 2,297,200.86 sales
-- ------------------------------------------------------------
SELECT
    COUNT(*)                        AS line_items,
    COUNT(DISTINCT order_id)        AS orders,
    COUNT(DISTINCT customer_id)     AS customers,
    MIN(order_date)                 AS first_order,
    MAX(order_date)                 AS last_order,
    ROUND(SUM(sales), 2)            AS total_sales,
    ROUND(SUM(profit), 2)           AS total_profit,
    ROUND(100 * SUM(profit) / SUM(sales), 2) AS margin_pct
FROM orders;


-- ------------------------------------------------------------
-- 1. WHICH SUB-CATEGORIES LOSE MONEY?
-- Basic aggregation + HAVING to filter groups, not rows.
-- Expected: Tables -17,725 | Bookcases -3,473 | Supplies -1,189
-- ------------------------------------------------------------
SELECT
    sub_category,
    ROUND(SUM(sales), 0)                            AS sales,
    ROUND(SUM(profit), 0)                           AS profit,
    ROUND(100 * SUM(profit) / SUM(sales), 2)        AS margin_pct,
    ROUND(100 * AVG(discount), 1)                   AS avg_discount_pct
FROM orders
GROUP BY sub_category
HAVING SUM(profit) < 0
ORDER BY profit;


-- ------------------------------------------------------------
-- 2. IS DISCOUNTING THE CAUSE?
-- CASE bucketing to test the hypothesis directly.
-- This is the key query: margin collapses as discount rises,
-- and turns negative above 25%.
-- Expected: 0% -> 29.51% | 16-25% -> 11.82% | 40%+ -> -77.40%
-- ------------------------------------------------------------
SELECT
    CASE
        WHEN discount = 0      THEN '0%'
        WHEN discount <= 0.15  THEN '1-15%'
        WHEN discount <= 0.25  THEN '16-25%'
        WHEN discount <= 0.40  THEN '26-40%'
        ELSE '40%+'
    END                                             AS discount_band,
    COUNT(*)                                        AS line_items,
    ROUND(SUM(sales), 0)                            AS sales,
    ROUND(SUM(profit), 0)                           AS profit,
    ROUND(100 * SUM(profit) / SUM(sales), 2)        AS margin_pct
FROM orders
GROUP BY discount_band
ORDER BY MIN(discount);


-- ------------------------------------------------------------
-- 3. REGIONAL PERFORMANCE
-- Window function to compute each region's share of total
-- without a second pass over the table.
-- Expected: Central 7.92% margin @ 24.0% discount
--           West   14.94% margin @ 10.9% discount
-- ------------------------------------------------------------
SELECT
    region,
    ROUND(SUM(sales), 0)                                    AS sales,
    ROUND(SUM(profit), 0)                                   AS profit,
    ROUND(100 * SUM(profit) / SUM(sales), 2)                AS margin_pct,
    ROUND(100 * AVG(discount), 1)                           AS avg_discount_pct,
    ROUND(100 * SUM(profit) / SUM(SUM(profit)) OVER (), 1)  AS pct_of_total_profit
FROM orders
GROUP BY region
ORDER BY margin_pct DESC;


-- ------------------------------------------------------------
-- 4. YEAR-ON-YEAR GROWTH
-- LAG() to reach the previous row without a self-join.
-- Expected: 2015 -2.8% | 2016 +29.5% | 2017 +20.4%
-- ------------------------------------------------------------
WITH yearly AS (
    SELECT
        EXTRACT(YEAR FROM order_date)::INT AS yr,
        SUM(sales)                         AS sales,
        SUM(profit)                        AS profit
    FROM orders
    GROUP BY 1
)
SELECT
    yr,
    ROUND(sales, 0)                                     AS sales,
    ROUND(LAG(sales) OVER (ORDER BY yr), 0)             AS prev_year_sales,
    ROUND(100 * (sales - LAG(sales) OVER (ORDER BY yr))
              / LAG(sales) OVER (ORDER BY yr), 1)       AS yoy_growth_pct,
    ROUND(SUM(sales) OVER (ORDER BY yr), 0)             AS cumulative_sales
FROM yearly
ORDER BY yr;


-- ------------------------------------------------------------
-- 5. COHORT RETENTION
-- Group customers by the month of their first purchase,
-- then measure what share return in each later month.
-- The standard analyst interview question.
-- ------------------------------------------------------------
WITH first_purchase AS (
    SELECT
        customer_id,
        DATE_TRUNC('month', MIN(order_date))::DATE AS cohort_month
    FROM orders
    GROUP BY customer_id
),
activity AS (
    SELECT DISTINCT
        o.customer_id,
        f.cohort_month,
        DATE_TRUNC('month', o.order_date)::DATE AS active_month
    FROM orders o
    JOIN first_purchase f ON o.customer_id = f.customer_id
),
offsets AS (
    SELECT
        cohort_month,
        customer_id,
        (EXTRACT(YEAR  FROM AGE(active_month, cohort_month)) * 12
       + EXTRACT(MONTH FROM AGE(active_month, cohort_month)))::INT AS months_since_first
    FROM activity
),
cohort_sizes AS (
    SELECT cohort_month, COUNT(DISTINCT customer_id) AS cohort_size
    FROM first_purchase
    GROUP BY cohort_month
)
SELECT
    o.cohort_month,
    c.cohort_size,
    o.months_since_first,
    COUNT(DISTINCT o.customer_id)                       AS active_customers,
    ROUND(100.0 * COUNT(DISTINCT o.customer_id)
          / c.cohort_size, 1)                           AS retention_pct
FROM offsets o
JOIN cohort_sizes c ON o.cohort_month = c.cohort_month
WHERE o.cohort_month < '2015-01-01'      -- 2014 cohorts have full 4-year history
  AND o.months_since_first <= 12
GROUP BY o.cohort_month, c.cohort_size, o.months_since_first
ORDER BY o.cohort_month, o.months_since_first;


-- ------------------------------------------------------------
-- 6. RFM CUSTOMER SEGMENTATION
-- NTILE() to split customers into quintiles on recency,
-- frequency and monetary value, then label the segments.
-- ------------------------------------------------------------
WITH customer_stats AS (
    SELECT
        customer_id,
        customer_name,
        MAX(order_date)                             AS last_order,
        (SELECT MAX(order_date) FROM orders)
            - MAX(order_date)                       AS recency_days,
        COUNT(DISTINCT order_id)                    AS frequency,
        SUM(sales)                                  AS monetary,
        SUM(profit)                                 AS profit
    FROM orders
    GROUP BY customer_id, customer_name
),
scored AS (
    SELECT
        *,
        NTILE(5) OVER (ORDER BY recency_days DESC)  AS r_score,
        NTILE(5) OVER (ORDER BY frequency)          AS f_score,
        NTILE(5) OVER (ORDER BY monetary)           AS m_score
    FROM customer_stats
)
SELECT
    customer_name,
    recency_days,
    frequency,
    ROUND(monetary, 0)      AS lifetime_sales,
    ROUND(profit, 0)        AS lifetime_profit,
    r_score, f_score, m_score,
    CASE
        WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 'Champion'
        WHEN r_score >= 3 AND f_score >= 3                  THEN 'Loyal'
        WHEN r_score >= 4 AND f_score <= 2                  THEN 'New / Promising'
        WHEN r_score <= 2 AND f_score >= 4                  THEN 'At risk'
        WHEN r_score <= 2 AND f_score <= 2                  THEN 'Lost'
        ELSE 'Needs attention'
    END                     AS segment
FROM scored
ORDER BY monetary DESC
LIMIT 25;


-- ------------------------------------------------------------
-- 7. UNPROFITABLE CUSTOMERS
-- Which customers cost more than they bring in, and is it
-- again explained by discount?
-- ------------------------------------------------------------
SELECT
    COUNT(*) FILTER (WHERE profit < 0)                          AS loss_making_customers,
    COUNT(*)                                                    AS total_customers,
    ROUND(100.0 * COUNT(*) FILTER (WHERE profit < 0) / COUNT(*), 1) AS pct_loss_making,
    ROUND(AVG(avg_discount) FILTER (WHERE profit < 0) * 100, 1) AS avg_discount_loss_makers,
    ROUND(AVG(avg_discount) FILTER (WHERE profit >= 0) * 100, 1) AS avg_discount_profitable
FROM (
    SELECT customer_id, SUM(profit) AS profit, AVG(discount) AS avg_discount
    FROM orders
    GROUP BY customer_id
) c;