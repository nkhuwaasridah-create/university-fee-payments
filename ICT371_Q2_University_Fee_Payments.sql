-- ICT371 Advanced Database - Question 2: University Fee Payments

-- ==== Setup ====
-- Run top to bottom in psql / pgAdmin (PostgreSQL 11 or later).
-- Scheduling in part (g) needs the pg_cron extension.
DROP TABLE IF EXISTS daily_collections, payment_audit, payments, students CASCADE;

-- ==== (a) Database and seed data ====
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE NOT NULL
);

CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INTEGER NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INTEGER NOT NULL,
    total_amount    NUMERIC(14,2) NOT NULL
);

-- Three students with different balances; Chanda will have no payments
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('S001', 'Alice Mwansa',  5000.00),
    ('S002', 'Brian Phiri',   3000.00),
    ('S003', 'Chanda Banda',  4000.00);

-- The six payments are loaded through pr_receive_payment at the end of
-- part (d), after the function, procedure and trigger exist.

-- ==== (b) Function: fn_fee_balance ====
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC AS $$
DECLARE
    v_fee  NUMERIC(12,2);
    v_paid NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_fee
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student: %', p_student_id;
    END IF;

    -- COALESCE returns 0 when the student has no payments: balance = full fee
    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN v_fee - v_paid;
END;
$$ LANGUAGE plpgsql;

SELECT fn_fee_balance(3);            -- 4000.00 (no payments yet)
-- SELECT fn_fee_balance(99);        -- error: unknown student

-- ==== (c) Procedure: pr_receive_payment ====
CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be positive (got %)', p_amount;
    END IF;
    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date must not be NULL';
    END IF;

    -- Lock the student row so two payments cannot both pass the balance check
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;

    v_balance := fn_fee_balance(p_student_id);     -- also rejects unknown student

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance %',
                        p_amount, v_balance;
    END IF;

    -- fee_due is never changed; the audit row is written by the trigger
    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- CALL pr_receive_payment(1, NULL, CURRENT_DATE);   -- error: NULL amount
-- CALL pr_receive_payment(1, 0, CURRENT_DATE);      -- error: zero
-- CALL pr_receive_payment(1, -50, CURRENT_DATE);    -- error: negative
-- CALL pr_receive_payment(3, 99999, CURRENT_DATE);  -- error: above balance

-- ==== (d) Trigger: automatic payment audit ====
CREATE OR REPLACE FUNCTION trg_fn_payment_audit() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payment_audit();

-- Seed: six payments through the procedure
CALL pr_receive_payment(1, 1000, '2026-11-18');
CALL pr_receive_payment(1, 1500, '2026-11-19');
CALL pr_receive_payment(1,  500, '2026-11-20');
CALL pr_receive_payment(2, 1000, '2026-11-19');
CALL pr_receive_payment(2,  500, '2026-11-20');
CALL pr_receive_payment(2, 1500, '2026-11-20');   -- Brian is now fully settled

SELECT * FROM payments ORDER BY payment_id;
SELECT * FROM payment_audit ORDER BY audit_id;    -- six rows, written by the trigger

-- ==== (e) View: v_fee_balances ====
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;   -- settled students excluded

SELECT * FROM v_fee_balances;                     -- Alice 2000, Chanda 4000

-- ==== (f) Index ====
-- Justification: the query tests student_id by equality and paid_on by range.
-- Putting the equality column first and the range column second lets the B-tree
-- go straight to one student's entries and read the date range in order.
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);
ANALYZE payments;

SET enable_seqscan = off;   -- demo only: tiny tables would otherwise use a seq scan
EXPLAIN
SELECT payment_id, amount, paid_on
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN '2026-11-18' AND '2026-11-20';
RESET enable_seqscan;

-- ==== (g) Scheduled job: pr_refresh_collections ====
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_count  INTEGER;
    v_amount NUMERIC(14,2);
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Day must not be NULL';
    END IF;

    SELECT COUNT(*), COALESCE(SUM(amount), 0)
    INTO v_count, v_amount
    FROM payments
    WHERE paid_on = p_day;

    -- Replace an existing summary row when rerun
    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    VALUES (p_day, v_count, v_amount)
    ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount  = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_collections('2026-11-20');
CALL pr_refresh_collections('2026-11-20');        -- rerun replaces, does not add
SELECT * FROM daily_collections;

-- Schedule daily at 01:00 for the previous day (pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'refresh_collections_daily',
    '0 1 * * *',
    $$CALL pr_refresh_collections(CURRENT_DATE - 1)$$
);
SELECT jobid, jobname, schedule, command FROM cron.job;
