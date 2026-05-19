-- ============================================================
-- LENDING APP — DATABASE SCHEMA (PostgreSQL)
-- ============================================================
-- Domains:
--   1. Users & Authentication
--   2. KYC & 3rd-party services (Dan, HUR, Sain Score)
--   3. Credit scoring & loan limits
--   4. Loan products, applications & disbursement
--   5. BNPL flow (Emart terminal QR payment)
--   6. Repayment schedules, QPAY invoices & transactions
--   7. Polaris core banking integration
--   8. Merchant portal (refunds, returns, settlements)
--   9. Audit trail, notifications & system logs
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- EXTENSIONS
-- ────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
-- 1. USERS & AUTHENTICATION
-- ============================================================

CREATE TYPE user_type_enum         AS ENUM ('customer', 'merchant', 'staff');
CREATE TYPE user_status_enum       AS ENUM ('active', 'suspended', 'deleted');
CREATE TYPE otp_purpose_enum       AS ENUM ('login', 'register', 'kyc', 'txn_confirm');
CREATE TYPE calpro_msg_type_enum   AS ENUM ('otp', 'loan_alert', 'repayment_due', 'marketing');
CREATE TYPE msg_status_enum        AS ENUM ('queued', 'sent', 'delivered', 'failed');
CREATE TYPE reg_status_enum        AS ENUM ('pending', 'kyc_verified', 'active', 'rejected');
CREATE TYPE customer_kind_enum     AS ENUM ('person', 'company');

CREATE TABLE users (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    phone_number    VARCHAR(20)  NOT NULL UNIQUE,
    email           VARCHAR(255) UNIQUE,
    password_hash   VARCHAR(255),
    user_type       user_type_enum NOT NULL,
    status          user_status_enum NOT NULL DEFAULT 'active',
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TABLE customer_profiles (
    id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id           UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    customer_kind     customer_kind_enum NOT NULL DEFAULT 'person',
    polaris_customer_id VARCHAR(100) UNIQUE,  -- customer reference returned by Polaris core system
    national_id       VARCHAR(20) NOT NULL UNIQUE,
    first_name        VARCHAR(100) NOT NULL,
    last_name         VARCHAR(100) NOT NULL,
    date_of_birth     DATE,
    gender            VARCHAR(10),
    address           TEXT,
    photo_url         TEXT,
    reg_status        reg_status_enum NOT NULL DEFAULT 'pending',
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE merchant_profiles (
    id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id          UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    business_name    VARCHAR(200) NOT NULL,
    business_reg_no  VARCHAR(50) NOT NULL UNIQUE,
    business_type    VARCHAR(100),
    contact_person   VARCHAR(150),
    address          TEXT,
    status           VARCHAR(20) NOT NULL DEFAULT 'pending',  -- pending|active|suspended
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE staff_profiles (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id      UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    employee_id  VARCHAR(50) NOT NULL UNIQUE,
    department   VARCHAR(100),
    role         VARCHAR(50) NOT NULL,
    permissions  JSONB NOT NULL DEFAULT '{}',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE otp_sessions (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID REFERENCES users(id),
    phone_number    VARCHAR(20) NOT NULL,
    otp_code_hash   VARCHAR(255) NOT NULL,
    purpose         otp_purpose_enum NOT NULL,
    attempt_count   INT NOT NULL DEFAULT 0,
    ip_address      INET,
    expires_at      TIMESTAMPTZ NOT NULL,
    verified_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE user_sessions (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash   VARCHAR(255) NOT NULL UNIQUE,
    device_id    VARCHAR(255),
    device_type  VARCHAR(50),
    ip_address   INET,
    expires_at   TIMESTAMPTZ NOT NULL,
    revoked_at   TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Calpro SMS/OTP delivery log
CREATE TABLE calpro_message_logs (
    id                 UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id            UUID REFERENCES users(id),
    phone_number       VARCHAR(20) NOT NULL,
    msg_type           calpro_msg_type_enum NOT NULL,
    template_id        VARCHAR(100),
    content            TEXT,
    status             msg_status_enum NOT NULL DEFAULT 'queued',
    provider_response  JSONB,
    sent_at            TIMESTAMPTZ,
    delivered_at       TIMESTAMPTZ,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_users_phone         ON users(phone_number);
CREATE INDEX idx_customer_kind       ON customer_profiles(customer_kind);
CREATE INDEX idx_customer_polaris_id ON customer_profiles(polaris_customer_id);
CREATE INDEX idx_otp_phone_purpose   ON otp_sessions(phone_number, purpose);
CREATE INDEX idx_sessions_user       ON user_sessions(user_id);
CREATE INDEX idx_calpro_user         ON calpro_message_logs(user_id);


-- ============================================================
-- 2. KYC & 3RD-PARTY SERVICES
-- ============================================================

CREATE TYPE kyc_gender_enum       AS ENUM ('male','female','other','unknown');
CREATE TYPE customer_segment_enum AS ENUM ('citizen','foreigner','living_abroad');
CREATE TYPE contact_type_enum     AS ENUM ('mobile','phone','email','social','messaging','fax','other');
CREATE TYPE address_type_enum     AS ENUM ('registered','residential','mailing','work','temporary','other');
CREATE TYPE education_level_enum  AS ENUM ('primary','secondary','vocational','bachelor','master','doctorate','other');
CREATE TYPE education_status_enum AS ENUM ('in_progress','completed','dropped','unknown');
CREATE TYPE employment_status_enum AS ENUM ('employed','self_employed','unemployed','student','retired','contract','other');
CREATE TYPE kyc_image_type_enum   AS ENUM ('portrait','selfie','id_front','id_back','passport','proof_of_address','proof_of_income','other');
CREATE TYPE relationship_type_enum AS ENUM ('spouse','parent','child','sibling','guardian','co_borrower','emergency_contact','employer','other');
CREATE TYPE kyc_record_status_enum AS ENUM ('pending','verified','rejected','expired');
CREATE TYPE bank_account_status_enum AS ENUM ('pending','verified','rejected','disabled');

-- Multiple personal identity/detail records are allowed for aliases, document variants and history
CREATE TABLE kyc_personal_details (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id         UUID NOT NULL REFERENCES customer_profiles(id) ON DELETE CASCADE,
    family_name         VARCHAR(100),
    first_name          VARCHAR(100),
    last_name           VARCHAR(100),
    nickname            VARCHAR(100),
    gender              kyc_gender_enum DEFAULT 'unknown',
    nationality         VARCHAR(100),
    register_number     VARCHAR(30),
    id_card_number      VARCHAR(50),
    birth_date          DATE,
    customer_segment    customer_segment_enum,
    work_industry       VARCHAR(150),
    is_primary          BOOLEAN NOT NULL DEFAULT FALSE,
    source              VARCHAR(50),          -- manual|dan|hur|staff|import
    status              kyc_record_status_enum NOT NULL DEFAULT 'pending',
    verified_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Multiple phones, emails and other contact points per customer
CREATE TABLE kyc_contact_infos (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id         UUID NOT NULL REFERENCES customer_profiles(id) ON DELETE CASCADE,
    contact_type        contact_type_enum NOT NULL,
    contact_value       VARCHAR(255) NOT NULL,
    label               VARCHAR(100),
    is_primary          BOOLEAN NOT NULL DEFAULT FALSE,
    is_verified         BOOLEAN NOT NULL DEFAULT FALSE,
    verified_at         TIMESTAMPTZ,
    source              VARCHAR(50),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Customer-linked bank accounts; customers may connect many and choose one primary
CREATE TABLE customer_bank_accounts (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id         UUID NOT NULL REFERENCES customer_profiles(id) ON DELETE CASCADE,
    bank_name           VARCHAR(150) NOT NULL,
    bank_code           VARCHAR(50),
    branch_name         VARCHAR(150),
    account_number      VARCHAR(50) NOT NULL,
    iban                VARCHAR(50),
    holder_name         VARCHAR(200) NOT NULL,
    currency            VARCHAR(10) NOT NULL DEFAULT 'MNT',
    is_primary          BOOLEAN NOT NULL DEFAULT FALSE,
    status              bank_account_status_enum NOT NULL DEFAULT 'pending',
    verified_at         TIMESTAMPTZ,
    disabled_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (customer_id, id),
    UNIQUE (customer_id, bank_name, account_number),
    UNIQUE (customer_id, iban)
);

-- Multiple registered, residential, work and temporary addresses per customer
CREATE TABLE kyc_addresses (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id         UUID NOT NULL REFERENCES customer_profiles(id) ON DELETE CASCADE,
    address_type        address_type_enum NOT NULL,
    country             VARCHAR(100),
    city                VARCHAR(100),
    district            VARCHAR(100),
    khoroo              VARCHAR(100),
    street              VARCHAR(200),
    building            VARCHAR(100),
    apartment           VARCHAR(100),
    postal_code         VARCHAR(30),
    full_address        TEXT NOT NULL,
    is_primary          BOOLEAN NOT NULL DEFAULT FALSE,
    source              VARCHAR(50),
    status              kyc_record_status_enum NOT NULL DEFAULT 'pending',
    verified_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Multiple education records per customer
CREATE TABLE kyc_educations (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id         UUID NOT NULL REFERENCES customer_profiles(id) ON DELETE CASCADE,
    institution_name    VARCHAR(200) NOT NULL,
    education_level     education_level_enum,
    field_of_study      VARCHAR(150),
    degree_name         VARCHAR(150),
    status              education_status_enum NOT NULL DEFAULT 'unknown',
    start_date          DATE,
    end_date            DATE,
    source              VARCHAR(50),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Multiple employment records per customer, including HUR/manual history
CREATE TABLE kyc_employments (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id         UUID NOT NULL REFERENCES customer_profiles(id) ON DELETE CASCADE,
    employer_name       VARCHAR(200),
    job_title           VARCHAR(150),
    work_industry       VARCHAR(150),
    employment_status   employment_status_enum,
    employment_type     VARCHAR(50),          -- full_time|part_time|contract|self_employed|etc.
    monthly_income      NUMERIC(14,2),
    income_currency     VARCHAR(10) NOT NULL DEFAULT 'MNT',
    start_date          DATE,
    end_date            DATE,
    is_current          BOOLEAN NOT NULL DEFAULT FALSE,
    source              VARCHAR(50),
    status              kyc_record_status_enum NOT NULL DEFAULT 'pending',
    verified_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- KYC images such as portrait, selfie, ID card, passport and proofs
CREATE TABLE kyc_customer_images (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id         UUID NOT NULL REFERENCES customer_profiles(id) ON DELETE CASCADE,
    image_type          kyc_image_type_enum NOT NULL,
    image_url           TEXT NOT NULL,
    file_hash           VARCHAR(128),
    mime_type           VARCHAR(100),
    captured_at         TIMESTAMPTZ,
    source              VARCHAR(50),
    status              kyc_record_status_enum NOT NULL DEFAULT 'pending',
    verified_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Related customers / related persons such as family, employer and emergency contacts
CREATE TABLE kyc_related_customers (
    id                        UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id               UUID NOT NULL REFERENCES customer_profiles(id) ON DELETE CASCADE,
    related_customer_id       UUID REFERENCES customer_profiles(id),
    relationship_type         relationship_type_enum NOT NULL,
    family_name               VARCHAR(100),
    first_name                VARCHAR(100),
    last_name                 VARCHAR(100),
    register_number           VARCHAR(30),
    phone_number              VARCHAR(20),
    email                     VARCHAR(255),
    notes                     TEXT,
    is_emergency_contact      BOOLEAN NOT NULL DEFAULT FALSE,
    source                    VARCHAR(50),
    status                    kyc_record_status_enum NOT NULL DEFAULT 'pending',
    verified_at               TIMESTAMPTZ,
    created_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (related_customer_id IS NULL OR related_customer_id <> customer_id)
);

-- Multiple signature images can be stored for refreshed KYC or contract versions
CREATE TABLE kyc_signature_images (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id         UUID NOT NULL REFERENCES customer_profiles(id) ON DELETE CASCADE,
    image_url           TEXT NOT NULL,
    file_hash           VARCHAR(128),
    mime_type           VARCHAR(100),
    signed_at           TIMESTAMPTZ,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    source              VARCHAR(50),
    status              kyc_record_status_enum NOT NULL DEFAULT 'pending',
    verified_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Mongolian Dan — national ID verification
CREATE TABLE dan_verifications (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id         UUID NOT NULL REFERENCES customer_profiles(id),
    request_ref         VARCHAR(100) NOT NULL UNIQUE,  -- Dan API reference
    national_id_checked VARCHAR(20) NOT NULL,
    status              VARCHAR(20) NOT NULL DEFAULT 'pending',  -- pending|verified|failed|expired
    response_snapshot   JSONB,
    error_message       TEXT,
    verified_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- HUR — employment, salary and social security data
CREATE TABLE hur_data_snapshots (
    id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id           UUID NOT NULL REFERENCES customer_profiles(id),
    request_ref           VARCHAR(100) NOT NULL UNIQUE,
    employer_name         VARCHAR(200),
    job_title             VARCHAR(150),
    employment_type       VARCHAR(30),  -- full_time|part_time|contract|self_employed
    salary_amount         NUMERIC(14,2),
    salary_currency       VARCHAR(10) NOT NULL DEFAULT 'MNT',
    social_security_months INT,
    snapshot_date         DATE NOT NULL,
    raw_response          JSONB,
    fetched_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Sain Score — FICO-based 3rd-party credit scoring
CREATE TABLE sain_score_requests (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id   UUID NOT NULL REFERENCES customer_profiles(id),
    request_ref   VARCHAR(100) NOT NULL UNIQUE,
    fico_score    INT,
    sain_score    NUMERIC(6,2),
    risk_grade    VARCHAR(5),  -- A, B, C, D, etc.
    raw_response  JSONB,
    requested_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at    TIMESTAMPTZ
);

-- Tracks each KYC step per customer
CREATE TABLE kyc_verification_steps (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id     UUID NOT NULL REFERENCES customer_profiles(id),
    step            VARCHAR(30) NOT NULL,  -- dan_check|hur_fetch|sain_score|final_review
    status          VARCHAR(20) NOT NULL DEFAULT 'pending',
    reference_id    UUID,    -- FK to the specific service result row
    reference_table VARCHAR(100),
    notes           TEXT,
    completed_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (customer_id, step)
);

CREATE INDEX idx_dan_customer      ON dan_verifications(customer_id);
CREATE INDEX idx_hur_customer      ON hur_data_snapshots(customer_id);
CREATE INDEX idx_sain_customer     ON sain_score_requests(customer_id);
CREATE INDEX idx_kyc_steps_cust    ON kyc_verification_steps(customer_id);
CREATE INDEX idx_kyc_personal_customer    ON kyc_personal_details(customer_id);
CREATE INDEX idx_kyc_personal_register    ON kyc_personal_details(register_number);
CREATE INDEX idx_kyc_personal_id_card     ON kyc_personal_details(id_card_number);
CREATE UNIQUE INDEX idx_kyc_personal_primary ON kyc_personal_details(customer_id) WHERE is_primary = TRUE;
CREATE INDEX idx_kyc_contact_customer     ON kyc_contact_infos(customer_id);
CREATE INDEX idx_kyc_contact_value        ON kyc_contact_infos(contact_type, contact_value);
CREATE UNIQUE INDEX idx_kyc_contact_primary ON kyc_contact_infos(customer_id, contact_type) WHERE is_primary = TRUE;
CREATE INDEX idx_customer_bank_accounts_customer ON customer_bank_accounts(customer_id);
CREATE INDEX idx_customer_bank_accounts_number ON customer_bank_accounts(bank_name, account_number);
CREATE UNIQUE INDEX idx_customer_bank_accounts_primary ON customer_bank_accounts(customer_id) WHERE is_primary = TRUE;
CREATE INDEX idx_kyc_address_customer     ON kyc_addresses(customer_id);
CREATE UNIQUE INDEX idx_kyc_address_primary ON kyc_addresses(customer_id, address_type) WHERE is_primary = TRUE;
CREATE INDEX idx_kyc_education_customer   ON kyc_educations(customer_id);
CREATE INDEX idx_kyc_employment_customer  ON kyc_employments(customer_id);
CREATE INDEX idx_kyc_employment_current   ON kyc_employments(customer_id, is_current);
CREATE INDEX idx_kyc_images_customer      ON kyc_customer_images(customer_id);
CREATE INDEX idx_kyc_related_customer     ON kyc_related_customers(customer_id);
CREATE INDEX idx_kyc_related_linked       ON kyc_related_customers(related_customer_id);
CREATE INDEX idx_kyc_signature_customer   ON kyc_signature_images(customer_id);
CREATE UNIQUE INDEX idx_kyc_signature_active ON kyc_signature_images(customer_id) WHERE is_active = TRUE;


-- ============================================================
-- 3. CREDIT SCORING & LOAN LIMITS
-- ============================================================

-- Combined final score from Sain + HUR + custom algorithm
CREATE TABLE credit_score_results (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id         UUID NOT NULL REFERENCES customer_profiles(id),
    sain_score_id       UUID NOT NULL REFERENCES sain_score_requests(id),
    hur_data_id         UUID NOT NULL REFERENCES hur_data_snapshots(id),
    final_score         NUMERIC(6,2) NOT NULL,
    risk_grade          VARCHAR(5),
    algorithm_version   VARCHAR(20) NOT NULL,
    score_breakdown     JSONB,
    calculated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    valid_until         TIMESTAMPTZ,
    status              VARCHAR(20) NOT NULL DEFAULT 'active'  -- active|expired|superseded
);

-- Individual factors used in scoring (for explainability / audit)
CREATE TABLE credit_scoring_factors (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    credit_score_id UUID NOT NULL REFERENCES credit_score_results(id),
    factor_name     VARCHAR(100) NOT NULL,
    raw_value       NUMERIC(14,4),
    weight          NUMERIC(6,4),
    contribution    NUMERIC(6,4),
    explanation     TEXT
);

-- Per-product credit limits for a customer
CREATE TABLE loan_limits (
    id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id      UUID NOT NULL REFERENCES customer_profiles(id),
    credit_score_id  UUID NOT NULL REFERENCES credit_score_results(id),
    max_total_limit  NUMERIC(14,2) NOT NULL,
    one_tap_limit    NUMERIC(14,2) NOT NULL DEFAULT 0,
    bnpl_limit       NUMERIC(14,2) NOT NULL DEFAULT 0,
    sme_limit        NUMERIC(14,2) NOT NULL DEFAULT 0,
    currency         VARCHAR(10) NOT NULL DEFAULT 'MNT',
    utilized_amount  NUMERIC(14,2) NOT NULL DEFAULT 0,
    available_amount NUMERIC(14,2) GENERATED ALWAYS AS (max_total_limit - utilized_amount) STORED,
    valid_until      TIMESTAMPTZ,
    status           VARCHAR(20) NOT NULL DEFAULT 'active',  -- active|expired|suspended
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_credit_customer ON credit_score_results(customer_id);
CREATE INDEX idx_limits_customer ON loan_limits(customer_id);


-- ============================================================
-- 4. LOAN PRODUCTS, APPLICATIONS & DISBURSEMENT
-- ============================================================

CREATE TYPE product_type_enum   AS ENUM ('one_tap', 'bnpl', 'sme');
CREATE TYPE loan_app_status     AS ENUM ('draft','submitted','approved','rejected','disbursed','cancelled');
CREATE TYPE loan_status_enum    AS ENUM ('active','closed','defaulted','written_off');
CREATE TYPE repayment_freq_enum AS ENUM ('daily','weekly','monthly');
CREATE TYPE loan_duration_unit_enum AS ENUM ('day','month');

CREATE TABLE loan_products (
    id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_type          product_type_enum NOT NULL,
    product_code          VARCHAR(20) NOT NULL UNIQUE,
    name                  VARCHAR(100) NOT NULL,
    min_amount            NUMERIC(14,2) NOT NULL,
    max_amount            NUMERIC(14,2) NOT NULL,
    annual_interest_rate  NUMERIC(6,4) NOT NULL,
    max_term_months       INT NOT NULL,
    repayment_freq        repayment_freq_enum NOT NULL DEFAULT 'monthly',
    product_config        JSONB NOT NULL DEFAULT '{}',
    is_active             BOOLEAN NOT NULL DEFAULT TRUE,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- User-selectable loan durations configured per product, e.g. 7 days, 30 days, 3 months
CREATE TABLE loan_product_duration_options (
    id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id            UUID NOT NULL REFERENCES loan_products(id) ON DELETE CASCADE,
    duration_value        INT NOT NULL CHECK (duration_value > 0),
    duration_unit         loan_duration_unit_enum NOT NULL,
    label                 VARCHAR(100) NOT NULL,
    repayment_freq        repayment_freq_enum,
    min_amount            NUMERIC(14,2),
    max_amount            NUMERIC(14,2),
    annual_interest_rate  NUMERIC(6,4),
    fee_rate              NUMERIC(6,4) NOT NULL DEFAULT 0,
    fee_amount            NUMERIC(14,2) NOT NULL DEFAULT 0,
    is_default            BOOLEAN NOT NULL DEFAULT FALSE,
    sort_order            INT NOT NULL DEFAULT 0,
    is_active             BOOLEAN NOT NULL DEFAULT TRUE,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (min_amount IS NULL OR max_amount IS NULL OR max_amount >= min_amount),
    UNIQUE (product_id, duration_value, duration_unit)
);

-- User-selectable BNPL split-count options configured per BNPL product
CREATE TABLE bnpl_installment_options (
    id                              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id                      UUID NOT NULL REFERENCES loan_products(id) ON DELETE CASCADE,
    installment_count               INT NOT NULL CHECK (installment_count > 0),
    label                           VARCHAR(100) NOT NULL,
    min_amount                      NUMERIC(14,2),
    max_amount                      NUMERIC(14,2),
    first_payment_due_value         INT NOT NULL DEFAULT 0 CHECK (first_payment_due_value >= 0),
    first_payment_due_unit          loan_duration_unit_enum NOT NULL DEFAULT 'day',
    installment_interval_value      INT NOT NULL DEFAULT 1 CHECK (installment_interval_value > 0),
    installment_interval_unit       loan_duration_unit_enum NOT NULL DEFAULT 'month',
    annual_interest_rate            NUMERIC(6,4),
    fee_rate                        NUMERIC(6,4) NOT NULL DEFAULT 0,
    fee_amount                      NUMERIC(14,2) NOT NULL DEFAULT 0,
    is_default                      BOOLEAN NOT NULL DEFAULT FALSE,
    sort_order                      INT NOT NULL DEFAULT 0,
    is_active                       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (min_amount IS NULL OR max_amount IS NULL OR max_amount >= min_amount),
    UNIQUE (product_id, installment_count)
);

CREATE TABLE loan_applications (
    id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id           UUID NOT NULL REFERENCES customer_profiles(id),
    product_id            UUID NOT NULL REFERENCES loan_products(id),
    credit_score_id       UUID NOT NULL REFERENCES credit_score_results(id),
    requested_amount      NUMERIC(14,2) NOT NULL,
    requested_disbursement_bank_account_id UUID REFERENCES customer_bank_accounts(id),
    duration_option_id    UUID REFERENCES loan_product_duration_options(id),
    requested_duration_value INT CHECK (requested_duration_value IS NULL OR requested_duration_value > 0),
    requested_duration_unit  loan_duration_unit_enum,
    requested_term_months INT,        -- legacy/monthly products; prefer duration_option_id + requested_duration_*
    bnpl_installment_option_id UUID REFERENCES bnpl_installment_options(id),
    purpose               VARCHAR(200),
    status                loan_app_status NOT NULL DEFAULT 'draft',
    rejection_reason      TEXT,
    processed_by_staff_id UUID REFERENCES staff_profiles(id),
    applied_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed_at          TIMESTAMPTZ,
    CHECK (
        (requested_duration_value IS NULL AND requested_duration_unit IS NULL)
        OR (requested_duration_value IS NOT NULL AND requested_duration_unit IS NOT NULL)
    ),
    FOREIGN KEY (customer_id, requested_disbursement_bank_account_id)
        REFERENCES customer_bank_accounts(customer_id, id)
);

CREATE TABLE loans (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    application_id      UUID NOT NULL UNIQUE REFERENCES loan_applications(id),
    customer_id         UUID NOT NULL REFERENCES customer_profiles(id),
    product_id          UUID NOT NULL REFERENCES loan_products(id),
    loan_number         VARCHAR(40) NOT NULL UNIQUE,
    principal_amount    NUMERIC(14,2) NOT NULL,
    disbursed_amount    NUMERIC(14,2),
    disbursement_bank_account_id UUID REFERENCES customer_bank_accounts(id),
    interest_rate       NUMERIC(6,4) NOT NULL,
    duration_option_id  UUID REFERENCES loan_product_duration_options(id),
    duration_value      INT CHECK (duration_value IS NULL OR duration_value > 0),
    duration_unit       loan_duration_unit_enum,
    term_months         INT,          -- legacy/monthly products; prefer duration_value + duration_unit
    bnpl_installment_option_id UUID REFERENCES bnpl_installment_options(id),
    total_payable       NUMERIC(14,2),
    maturity_date       DATE,
    status              loan_status_enum NOT NULL DEFAULT 'active',
    polaris_loan_acc_no VARCHAR(30),
    disbursed_at        TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (
        (duration_value IS NULL AND duration_unit IS NULL)
        OR (duration_value IS NOT NULL AND duration_unit IS NOT NULL)
    ),
    FOREIGN KEY (customer_id, disbursement_bank_account_id)
        REFERENCES customer_bank_accounts(customer_id, id)
);

-- Maps a loan to all Polaris account numbers used in its lifecycle
CREATE TABLE loan_account_mappings (
    id                          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    loan_id                     UUID NOT NULL UNIQUE REFERENCES loans(id),
    polaris_deposit_acc_no      VARCHAR(30),  -- customer's deposit account to disburse into
    polaris_loan_acc_no         VARCHAR(30),  -- loan balance account in Polaris
    polaris_repayment_pool_acc  VARCHAR(30),  -- internal repayment collection account
    polaris_merchant_debt_acc   VARCHAR(30),  -- BNPL: account to pay Emart
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_loans_customer     ON loans(customer_id);
CREATE INDEX idx_loan_apps_customer ON loan_applications(customer_id);
CREATE INDEX idx_loan_apps_disbursement_bank ON loan_applications(requested_disbursement_bank_account_id);
CREATE INDEX idx_duration_options_product ON loan_product_duration_options(product_id, is_active, sort_order);
CREATE UNIQUE INDEX idx_duration_options_default ON loan_product_duration_options(product_id) WHERE is_default = TRUE;
CREATE INDEX idx_bnpl_installment_options_product ON bnpl_installment_options(product_id, is_active, sort_order);
CREATE UNIQUE INDEX idx_bnpl_installment_options_default ON bnpl_installment_options(product_id) WHERE is_default = TRUE;
CREATE INDEX idx_loan_apps_duration_option ON loan_applications(duration_option_id);
CREATE INDEX idx_loan_apps_bnpl_option ON loan_applications(bnpl_installment_option_id);
CREATE INDEX idx_loans_duration_option ON loans(duration_option_id);
CREATE INDEX idx_loans_bnpl_option ON loans(bnpl_installment_option_id);
CREATE INDEX idx_loans_disbursement_bank ON loans(disbursement_bank_account_id);


-- ============================================================
-- 5. BNPL FLOW (EMART TERMINAL QR PAYMENT)
-- ============================================================

CREATE TYPE invoice_status_enum  AS ENUM ('pending','qr_generated','processing','approved','rejected','expired','refunded');
CREATE TYPE callback_type_enum   AS ENUM ('approved','rejected','timeout');
CREATE TYPE callback_status_enum AS ENUM ('pending','sent','acknowledged','failed');
CREATE TYPE bnpl_txn_status_enum AS ENUM ('processing','approved','rejected','disbursed');

CREATE TABLE bnpl_terminals (
    id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    merchant_id          UUID NOT NULL REFERENCES merchant_profiles(id),
    terminal_code        VARCHAR(50) NOT NULL UNIQUE,
    terminal_name        VARCHAR(100),
    location_description TEXT,
    api_endpoint         TEXT NOT NULL,
    secret_key_hash      VARCHAR(255) NOT NULL,
    status               VARCHAR(20) NOT NULL DEFAULT 'active',  -- active|inactive|maintenance
    registered_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Payment invoice created when cashier requests BNPL payment at terminal
CREATE TABLE bnpl_payment_invoices (
    id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    terminal_id       UUID NOT NULL REFERENCES bnpl_terminals(id),
    merchant_id       UUID NOT NULL REFERENCES merchant_profiles(id),
    cashier_reference VARCHAR(100),
    invoice_number    VARCHAR(50) NOT NULL UNIQUE,
    total_amount      NUMERIC(14,2) NOT NULL,
    currency          VARCHAR(10) NOT NULL DEFAULT 'MNT',
    items_snapshot    JSONB,           -- cart items at time of invoice
    status            invoice_status_enum NOT NULL DEFAULT 'pending',
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at        TIMESTAMPTZ NOT NULL,
    completed_at      TIMESTAMPTZ
);

-- QR code generated for each invoice, displayed on terminal screen
CREATE TABLE bnpl_qr_codes (
    id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    invoice_id              UUID NOT NULL REFERENCES bnpl_payment_invoices(id),
    qr_payload              TEXT NOT NULL,
    qr_image_url            TEXT,
    scanned_by_customer_id  UUID REFERENCES customer_profiles(id),
    selected_installment_option_id UUID REFERENCES bnpl_installment_options(id),
    selected_installments   INT,        -- denormalized split count shown/selected by customer
    generated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at              TIMESTAMPTZ NOT NULL,
    scanned_at              TIMESTAMPTZ
);

-- BNPL transaction record (linked to the loan created for it)
CREATE TABLE bnpl_transactions (
    id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    loan_id                 UUID REFERENCES loans(id),
    invoice_id              UUID NOT NULL UNIQUE REFERENCES bnpl_payment_invoices(id),
    customer_id             UUID NOT NULL REFERENCES customer_profiles(id),
    merchant_id             UUID NOT NULL REFERENCES merchant_profiles(id),
    installment_option_id   UUID REFERENCES bnpl_installment_options(id),
    total_amount            NUMERIC(14,2) NOT NULL,
    installment_count       INT NOT NULL,
    per_installment_amount  NUMERIC(14,2) NOT NULL,
    interest_amount         NUMERIC(14,2) NOT NULL DEFAULT 0,
    status                  bnpl_txn_status_enum NOT NULL DEFAULT 'processing',
    approved_at             TIMESTAMPTZ,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Callbacks sent back to the terminal after approval/rejection
CREATE TABLE bnpl_terminal_callbacks (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    transaction_id  UUID NOT NULL REFERENCES bnpl_transactions(id),
    terminal_id     UUID NOT NULL REFERENCES bnpl_terminals(id),
    callback_type   callback_type_enum NOT NULL,
    payload         JSONB NOT NULL,
    http_status     INT,
    retry_count     INT NOT NULL DEFAULT 0,
    status          callback_status_enum NOT NULL DEFAULT 'pending',
    sent_at         TIMESTAMPTZ,
    acknowledged_at TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_invoices_terminal  ON bnpl_payment_invoices(terminal_id);
CREATE INDEX idx_invoices_merchant  ON bnpl_payment_invoices(merchant_id);
CREATE INDEX idx_qr_invoice         ON bnpl_qr_codes(invoice_id);
CREATE INDEX idx_qr_installment_option ON bnpl_qr_codes(selected_installment_option_id);
CREATE INDEX idx_bnpl_txn_customer  ON bnpl_transactions(customer_id);
CREATE INDEX idx_bnpl_txn_installment_option ON bnpl_transactions(installment_option_id);


-- ============================================================
-- 6. REPAYMENT SCHEDULES, QPAY INVOICES & TRANSACTIONS
-- ============================================================

CREATE TYPE sched_status_enum   AS ENUM ('pending','partial','paid','overdue','waived');
CREATE TYPE payment_chan_enum   AS ENUM ('qpay');
CREATE TYPE qpay_invoice_status_enum AS ENUM ('pending','created','paid','expired','cancelled','failed');
CREATE TYPE qpay_callback_status_enum AS ENUM ('received','processed','failed','ignored');
CREATE TYPE repay_txn_status    AS ENUM ('pending','completed','failed','reversed');
CREATE TYPE penalty_type_enum   AS ENUM ('late_payment','early_exit');

-- Generated at disbursement; one row per installment
CREATE TABLE repayment_schedules (
    id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    loan_id              UUID NOT NULL REFERENCES loans(id),
    installment_number   INT NOT NULL,
    due_date             DATE NOT NULL,
    principal_amount     NUMERIC(14,2) NOT NULL,
    interest_amount      NUMERIC(14,2) NOT NULL,
    penalty_amount       NUMERIC(14,2) NOT NULL DEFAULT 0,
    total_due            NUMERIC(14,2) NOT NULL,
    paid_amount          NUMERIC(14,2) NOT NULL DEFAULT 0,
    outstanding_amount   NUMERIC(14,2) GENERATED ALWAYS AS (total_due + penalty_amount - paid_amount) STORED,
    status               sched_status_enum NOT NULL DEFAULT 'pending',
    paid_at              TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (loan_id, installment_number)
);

-- QPAY invoice created when a customer initiates repayment for an installment or loan payoff
CREATE TABLE qpay_repayment_invoices (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    schedule_id         UUID REFERENCES repayment_schedules(id),
    loan_id             UUID NOT NULL REFERENCES loans(id),
    customer_id         UUID NOT NULL REFERENCES customer_profiles(id),
    invoice_number      VARCHAR(100) NOT NULL UNIQUE,
    qpay_invoice_id     VARCHAR(100) UNIQUE,
    amount              NUMERIC(14,2) NOT NULL,
    currency            VARCHAR(10) NOT NULL DEFAULT 'MNT',
    qr_payload          TEXT,
    qr_image_url        TEXT,
    deep_link_url       TEXT,
    status              qpay_invoice_status_enum NOT NULL DEFAULT 'pending',
    request_payload     JSONB,
    response_payload    JSONB,
    expires_at          TIMESTAMPTZ,
    paid_at             TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Raw QPAY callbacks/webhooks, processed into repayment_transactions after validation
CREATE TABLE qpay_repayment_callbacks (
    id                          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    qpay_repayment_invoice_id   UUID REFERENCES qpay_repayment_invoices(id),
    qpay_invoice_id             VARCHAR(100),
    qpay_payment_id             VARCHAR(100),
    payment_status              VARCHAR(30),
    payload                     JSONB NOT NULL,
    status                      qpay_callback_status_enum NOT NULL DEFAULT 'received',
    error_message               TEXT,
    received_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed_at                TIMESTAMPTZ
);

-- Each QPAY payment recorded here; may cover one or more schedule rows
CREATE TABLE repayment_transactions (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    schedule_id         UUID REFERENCES repayment_schedules(id),
    loan_id             UUID NOT NULL REFERENCES loans(id),
    customer_id         UUID NOT NULL REFERENCES customer_profiles(id),
    amount              NUMERIC(14,2) NOT NULL,
    principal_portion   NUMERIC(14,2) NOT NULL DEFAULT 0,
    interest_portion    NUMERIC(14,2) NOT NULL DEFAULT 0,
    penalty_portion     NUMERIC(14,2) NOT NULL DEFAULT 0,
    qpay_repayment_invoice_id UUID REFERENCES qpay_repayment_invoices(id),
    payment_channel     payment_chan_enum NOT NULL DEFAULT 'qpay',
    transaction_ref     VARCHAR(100) NOT NULL UNIQUE,
    polaris_txn_ref     VARCHAR(100),
    status              repay_txn_status NOT NULL DEFAULT 'pending',
    processed_at        TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Late payment / early exit penalties (can be waived by staff)
CREATE TABLE penalty_records (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    schedule_id         UUID NOT NULL REFERENCES repayment_schedules(id),
    loan_id             UUID NOT NULL REFERENCES loans(id),
    penalty_amount      NUMERIC(14,2) NOT NULL,
    penalty_type        penalty_type_enum NOT NULL,
    overdue_days        INT NOT NULL DEFAULT 0,
    is_waived           BOOLEAN NOT NULL DEFAULT FALSE,
    waived_by_staff_id  UUID REFERENCES staff_profiles(id),
    waiver_reason       TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_sched_loan         ON repayment_schedules(loan_id);
CREATE INDEX idx_sched_due_date     ON repayment_schedules(due_date);
CREATE INDEX idx_qpay_invoice_loan  ON qpay_repayment_invoices(loan_id);
CREATE INDEX idx_qpay_invoice_sched ON qpay_repayment_invoices(schedule_id);
CREATE INDEX idx_qpay_cb_invoice    ON qpay_repayment_callbacks(qpay_repayment_invoice_id);
CREATE INDEX idx_repay_txn_loan     ON repayment_transactions(loan_id);
CREATE INDEX idx_repay_txn_qpay_inv ON repayment_transactions(qpay_repayment_invoice_id);


-- ============================================================
-- 7. POLARIS CORE BANKING INTEGRATION
-- ============================================================

CREATE TYPE polaris_acc_type  AS ENUM ('customer_deposit','loan','repayment_pool','internal','merchant_debt');
CREATE TYPE polaris_sync_stat AS ENUM ('pending','synced','failed');
CREATE TYPE queue_op_enum     AS ENUM ('create_account','post_txn','update_balance','close_account');
CREATE TYPE queue_status_enum AS ENUM ('pending','processing','completed','dead_letter');

-- Master registry of all Polaris account numbers used by the system
CREATE TABLE polaris_accounts (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    account_number      VARCHAR(30) NOT NULL UNIQUE,
    account_type        polaris_acc_type NOT NULL,
    owner_type          VARCHAR(20) NOT NULL,  -- customer|merchant|system
    owner_id            UUID,                  -- references the relevant profile id
    product_ref         VARCHAR(50),
    currency            VARCHAR(10) NOT NULL DEFAULT 'MNT',
    current_balance     NUMERIC(18,2) NOT NULL DEFAULT 0,
    status              VARCHAR(20) NOT NULL DEFAULT 'active',  -- active|frozen|closed
    polaris_synced_at   TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Full ledger of transactions posted to Polaris
CREATE TABLE polaris_transactions (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    polaris_account_id  UUID NOT NULL REFERENCES polaris_accounts(id),
    transaction_ref     VARCHAR(100) NOT NULL UNIQUE,
    polaris_txn_id      VARCHAR(100),         -- ID returned by Polaris API
    debit_credit        VARCHAR(6) NOT NULL,  -- debit|credit
    amount              NUMERIC(14,2) NOT NULL,
    balance_after       NUMERIC(18,2),
    narration           TEXT,
    source_module       VARCHAR(50),          -- loans|repayment|bnpl|refund|etc.
    source_ref_id       UUID,                 -- FK to the originating record
    value_date          DATE NOT NULL,
    posted_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    sync_status         polaris_sync_stat NOT NULL DEFAULT 'pending'
);

-- Full log of every Polaris API call (request + response)
CREATE TABLE polaris_api_logs (
    id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    endpoint         VARCHAR(255) NOT NULL,
    http_method      VARCHAR(10) NOT NULL,
    request_payload  JSONB,
    response_payload JSONB,
    http_status_code INT,
    duration_ms      INT,
    correlation_id   VARCHAR(100),
    error_message    TEXT,
    is_success       BOOLEAN NOT NULL DEFAULT FALSE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Outbound sync queue (handles retries, dead-letter)
CREATE TABLE polaris_sync_queue (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_table    VARCHAR(100) NOT NULL,
    source_id       UUID NOT NULL,
    operation       queue_op_enum NOT NULL,
    payload         JSONB NOT NULL,
    retry_count     INT NOT NULL DEFAULT 0,
    status          queue_status_enum NOT NULL DEFAULT 'pending',
    error_message   TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed_at    TIMESTAMPTZ
);

CREATE INDEX idx_polaris_txn_acc  ON polaris_transactions(polaris_account_id);
CREATE INDEX idx_polaris_txn_ref  ON polaris_transactions(transaction_ref);
CREATE INDEX idx_sync_queue_stat  ON polaris_sync_queue(status);
CREATE INDEX idx_api_logs_corr    ON polaris_api_logs(correlation_id);


-- ============================================================
-- 8. MERCHANT PORTAL
-- ============================================================

CREATE TYPE portal_role_enum    AS ENUM ('admin','cashier','viewer');
CREATE TYPE refund_type_enum    AS ENUM ('full','partial');
CREATE TYPE refund_status_enum  AS ENUM ('pending','under_review','approved','rejected','processed');
CREATE TYPE settle_status_enum  AS ENUM ('pending','processing','completed','failed');

-- Merchant portal user access (separate from the merchant owner user)
CREATE TABLE merchant_portal_users (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    merchant_id  UUID NOT NULL REFERENCES merchant_profiles(id),
    user_id      UUID NOT NULL REFERENCES users(id),
    role         portal_role_enum NOT NULL DEFAULT 'viewer',
    permissions  JSONB NOT NULL DEFAULT '{}',
    status       VARCHAR(20) NOT NULL DEFAULT 'active',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (merchant_id, user_id)
);

-- Refund / return requests raised by merchant portal
CREATE TABLE merchant_refund_requests (
    id                          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    bnpl_transaction_id         UUID NOT NULL REFERENCES bnpl_transactions(id),
    merchant_id                 UUID NOT NULL REFERENCES merchant_profiles(id),
    requested_by_portal_user_id UUID REFERENCES merchant_portal_users(id),
    refund_amount               NUMERIC(14,2) NOT NULL,
    refund_type                 refund_type_enum NOT NULL,
    reason                      TEXT NOT NULL,
    status                      refund_status_enum NOT NULL DEFAULT 'pending',
    reviewed_by_staff_id        UUID REFERENCES staff_profiles(id),
    staff_notes                 TEXT,
    polaris_reversal_ref        VARCHAR(100),
    requested_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    reviewed_at                 TIMESTAMPTZ,
    processed_at                TIMESTAMPTZ
);

-- Individual items being returned (one refund request may have many items)
CREATE TABLE merchant_return_items (
    id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    refund_request_id UUID NOT NULL REFERENCES merchant_refund_requests(id),
    item_code         VARCHAR(100),
    item_description  TEXT NOT NULL,
    quantity          INT NOT NULL DEFAULT 1,
    unit_price        NUMERIC(14,2) NOT NULL,
    total_price       NUMERIC(14,2) GENERATED ALWAYS AS (quantity * unit_price) STORED
);

-- Daily/weekly settlement batches to merchants
CREATE TABLE merchant_settlements (
    id                 UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    merchant_id        UUID NOT NULL REFERENCES merchant_profiles(id),
    settlement_date    DATE NOT NULL,
    total_bnpl_amount  NUMERIC(14,2) NOT NULL DEFAULT 0,
    total_refunds      NUMERIC(14,2) NOT NULL DEFAULT 0,
    net_settlement     NUMERIC(14,2) GENERATED ALWAYS AS (total_bnpl_amount - total_refunds) STORED,
    transaction_count  INT NOT NULL DEFAULT 0,
    status             settle_status_enum NOT NULL DEFAULT 'pending',
    polaris_txn_ref    VARCHAR(100),
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    settled_at         TIMESTAMPTZ
);

CREATE INDEX idx_portal_users_merchant  ON merchant_portal_users(merchant_id);
CREATE INDEX idx_refunds_merchant       ON merchant_refund_requests(merchant_id);
CREATE INDEX idx_refunds_status         ON merchant_refund_requests(status);
CREATE INDEX idx_settlements_merchant   ON merchant_settlements(merchant_id, settlement_date);


-- ============================================================
-- 9. AUDIT TRAIL, NOTIFICATIONS & SYSTEM LOGS
-- ============================================================

CREATE TYPE severity_enum    AS ENUM ('debug','info','warn','error','critical');
CREATE TYPE notif_chan_enum  AS ENUM ('sms','push','email','in_app');
CREATE TYPE notif_status     AS ENUM ('queued','sent','delivered','read','failed');
CREATE TYPE review_type_enum AS ENUM ('routine','escalated','compliance');
CREATE TYPE service_pause_scope_enum AS ENUM (
    'all',
    'repayment',
    'bnpl',
    'loan_disbursement',
    'polaris_sync',
    'merchant_settlement'
);
CREATE TYPE service_pause_status_enum AS ENUM ('scheduled','active','completed','cancelled');

-- Immutable audit log for every state-changing action
CREATE TABLE audit_logs (
    id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id        UUID REFERENCES users(id),
    action         VARCHAR(100) NOT NULL,   -- e.g. LOAN_APPROVED, KYC_VERIFIED
    entity_type    VARCHAR(100) NOT NULL,
    entity_id      UUID NOT NULL,
    old_value      JSONB,
    new_value      JSONB,
    ip_address     INET,
    user_agent     TEXT,
    session_id     UUID,
    source_module  VARCHAR(50),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
) PARTITION BY RANGE (created_at);  -- partition by month for scalability

CREATE TABLE audit_logs_2025_01 PARTITION OF audit_logs
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
-- (Add monthly partitions as needed)

-- Compliance / spot-check reviews of audit entries by staff
CREATE TABLE staff_action_reviews (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    audit_log_id        UUID NOT NULL,  -- references audit_logs(id)
    reviewer_staff_id   UUID NOT NULL REFERENCES staff_profiles(id),
    review_type         review_type_enum NOT NULL,
    outcome             VARCHAR(50),
    notes               TEXT,
    reviewed_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Operational pause windows for end-of-day or core system processing
CREATE TABLE service_pause_windows (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    scope               service_pause_scope_enum NOT NULL,
    reason              TEXT NOT NULL,
    status              service_pause_status_enum NOT NULL DEFAULT 'scheduled',
    starts_at           TIMESTAMPTZ NOT NULL,
    ends_at             TIMESTAMPTZ,
    started_by_staff_id UUID REFERENCES staff_profiles(id),
    ended_by_staff_id   UUID REFERENCES staff_profiles(id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (ends_at IS NULL OR ends_at > starts_at)
);

-- Reusable message templates per channel and language
CREATE TABLE notification_templates (
    id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    template_code  VARCHAR(100) NOT NULL,
    channel        notif_chan_enum NOT NULL,
    subject        VARCHAR(255),
    body_template  TEXT NOT NULL,
    language       VARCHAR(10) NOT NULL DEFAULT 'mn',
    is_active      BOOLEAN NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (template_code, channel, language)
);

-- Per-delivery record for every notification sent
CREATE TABLE notification_logs (
    id                 UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id            UUID NOT NULL REFERENCES users(id),
    template_id        UUID REFERENCES notification_templates(id),
    channel            notif_chan_enum NOT NULL,
    recipient_address  VARCHAR(255) NOT NULL,
    rendered_content   TEXT,
    status             notif_status NOT NULL DEFAULT 'queued',
    provider_message_id VARCHAR(200),
    error_message      TEXT,
    queued_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    sent_at            TIMESTAMPTZ,
    delivered_at       TIMESTAMPTZ,
    read_at            TIMESTAMPTZ
);

-- Infrastructure / service-level event log
CREATE TABLE system_event_logs (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    service_name    VARCHAR(100) NOT NULL,
    event_type      VARCHAR(100) NOT NULL,
    severity        severity_enum NOT NULL DEFAULT 'info',
    message         TEXT NOT NULL,
    metadata        JSONB,
    trace_id        VARCHAR(100),
    correlation_id  VARCHAR(100),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
) PARTITION BY RANGE (created_at);

CREATE TABLE system_event_logs_2025_01 PARTITION OF system_event_logs
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');

CREATE INDEX idx_audit_entity       ON audit_logs(entity_type, entity_id);
CREATE INDEX idx_audit_user         ON audit_logs(user_id);
CREATE INDEX idx_service_pause_active
    ON service_pause_windows(scope, starts_at, ends_at)
    WHERE status = 'active';
CREATE INDEX idx_notif_user         ON notification_logs(user_id);
CREATE INDEX idx_notif_status       ON notification_logs(status);
CREATE INDEX idx_syslog_severity    ON system_event_logs(severity, created_at DESC);
CREATE INDEX idx_syslog_service     ON system_event_logs(service_name);


-- ============================================================
-- OPERATIONAL PAUSE GUARDS
-- ============================================================

CREATE OR REPLACE FUNCTION is_service_paused(p_scope service_pause_scope_enum)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM service_pause_windows
        WHERE status = 'active'
          AND starts_at <= NOW()
          AND (ends_at IS NULL OR ends_at > NOW())
          AND scope IN ('all'::service_pause_scope_enum, p_scope)
    );
$$;

CREATE OR REPLACE FUNCTION prevent_when_service_paused()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_scope service_pause_scope_enum := TG_ARGV[0]::service_pause_scope_enum;
BEGIN
    IF is_service_paused(v_scope) THEN
        RAISE EXCEPTION 'Service scope % is paused for end-of-day/core processing', v_scope
            USING ERRCODE = '55000';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_pause_qpay_repayment_invoice
BEFORE INSERT OR UPDATE ON qpay_repayment_invoices
FOR EACH ROW EXECUTE FUNCTION prevent_when_service_paused('repayment');

CREATE TRIGGER trg_pause_repayment_transaction
BEFORE INSERT OR UPDATE ON repayment_transactions
FOR EACH ROW EXECUTE FUNCTION prevent_when_service_paused('repayment');

CREATE TRIGGER trg_pause_bnpl_payment_invoice
BEFORE INSERT OR UPDATE ON bnpl_payment_invoices
FOR EACH ROW EXECUTE FUNCTION prevent_when_service_paused('bnpl');

CREATE TRIGGER trg_pause_loan_creation
BEFORE INSERT ON loans
FOR EACH ROW EXECUTE FUNCTION prevent_when_service_paused('loan_disbursement');

CREATE TRIGGER trg_pause_loan_disbursement_update
BEFORE UPDATE OF disbursed_at ON loans
FOR EACH ROW
WHEN (NEW.disbursed_at IS DISTINCT FROM OLD.disbursed_at)
EXECUTE FUNCTION prevent_when_service_paused('loan_disbursement');

CREATE TRIGGER trg_pause_polaris_transaction
BEFORE INSERT OR UPDATE ON polaris_transactions
FOR EACH ROW EXECUTE FUNCTION prevent_when_service_paused('polaris_sync');

CREATE TRIGGER trg_pause_polaris_sync_queue
BEFORE INSERT OR UPDATE ON polaris_sync_queue
FOR EACH ROW EXECUTE FUNCTION prevent_when_service_paused('polaris_sync');

CREATE TRIGGER trg_pause_merchant_settlement
BEFORE INSERT OR UPDATE ON merchant_settlements
FOR EACH ROW EXECUTE FUNCTION prevent_when_service_paused('merchant_settlement');


-- ============================================================
-- ROW-LEVEL SECURITY (enable per-tenant isolation)
-- ============================================================
ALTER TABLE customer_profiles   ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_personal_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_contact_infos    ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_bank_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_addresses        ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_educations       ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_employments      ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_customer_images  ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_related_customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_signature_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE merchant_profiles   ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_applications   ENABLE ROW LEVEL SECURITY;
ALTER TABLE loans               ENABLE ROW LEVEL SECURITY;
ALTER TABLE repayment_schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE qpay_repayment_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE repayment_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE bnpl_transactions   ENABLE ROW LEVEL SECURITY;


-- ============================================================
-- USEFUL VIEWS
-- ============================================================

-- Active service pauses affecting money-moving operations
CREATE VIEW v_active_service_pauses AS
SELECT
    id,
    scope,
    reason,
    starts_at,
    ends_at,
    started_by_staff_id,
    created_at
FROM service_pause_windows
WHERE status = 'active'
  AND starts_at <= NOW()
  AND (ends_at IS NULL OR ends_at > NOW())
ORDER BY starts_at DESC;

-- Active loan duration options to show customers when applying for non-BNPL loans
CREATE VIEW v_active_loan_duration_options AS
SELECT
    lp.id AS product_id,
    lp.product_code,
    lp.product_type,
    lp.name AS product_name,
    ldo.id AS duration_option_id,
    ldo.label,
    ldo.duration_value,
    ldo.duration_unit,
    ldo.repayment_freq,
    COALESCE(ldo.min_amount, lp.min_amount) AS min_amount,
    COALESCE(ldo.max_amount, lp.max_amount) AS max_amount,
    COALESCE(ldo.annual_interest_rate, lp.annual_interest_rate) AS annual_interest_rate,
    ldo.fee_rate,
    ldo.fee_amount,
    ldo.is_default,
    ldo.sort_order
FROM loan_products lp
JOIN loan_product_duration_options ldo ON ldo.product_id = lp.id
WHERE lp.is_active = TRUE
  AND ldo.is_active = TRUE
  AND lp.product_type <> 'bnpl'
ORDER BY lp.product_code, ldo.sort_order, ldo.duration_unit, ldo.duration_value;

-- Active BNPL installment split options to show customers at checkout
CREATE VIEW v_active_bnpl_installment_options AS
SELECT
    lp.id AS product_id,
    lp.product_code,
    lp.name AS product_name,
    bio.id AS installment_option_id,
    bio.label,
    bio.installment_count,
    COALESCE(bio.min_amount, lp.min_amount) AS min_amount,
    COALESCE(bio.max_amount, lp.max_amount) AS max_amount,
    bio.first_payment_due_value,
    bio.first_payment_due_unit,
    bio.installment_interval_value,
    bio.installment_interval_unit,
    COALESCE(bio.annual_interest_rate, lp.annual_interest_rate) AS annual_interest_rate,
    bio.fee_rate,
    bio.fee_amount,
    bio.is_default,
    bio.sort_order
FROM loan_products lp
JOIN bnpl_installment_options bio ON bio.product_id = lp.id
WHERE lp.is_active = TRUE
  AND bio.is_active = TRUE
  AND lp.product_type = 'bnpl'
ORDER BY lp.product_code, bio.sort_order, bio.installment_count;

-- Customer loan summary
CREATE VIEW v_customer_loan_summary AS
SELECT
    cp.id                AS customer_id,
    cp.first_name || ' ' || cp.last_name AS full_name,
    cp.national_id,
    ll.max_total_limit,
    ll.utilized_amount,
    ll.available_amount,
    ll.status            AS limit_status,
    COUNT(l.id)          AS total_loans,
    SUM(CASE WHEN l.status = 'active' THEN 1 ELSE 0 END) AS active_loans,
    SUM(l.principal_amount) AS total_principal
FROM customer_profiles cp
LEFT JOIN loan_limits ll ON ll.customer_id = cp.id AND ll.status = 'active'
LEFT JOIN loans l ON l.customer_id = cp.id
GROUP BY cp.id, cp.first_name, cp.last_name, cp.national_id,
         ll.max_total_limit, ll.utilized_amount, ll.available_amount, ll.status;

-- Overdue repayments
CREATE VIEW v_overdue_repayments AS
SELECT
    rs.id,
    rs.loan_id,
    l.loan_number,
    cp.first_name || ' ' || cp.last_name AS customer_name,
    cp.id AS customer_id,
    rs.installment_number,
    rs.due_date,
    rs.outstanding_amount,
    NOW()::date - rs.due_date AS days_overdue
FROM repayment_schedules rs
JOIN loans l ON l.id = rs.loan_id
JOIN customer_profiles cp ON cp.id = l.customer_id
WHERE rs.status = 'overdue'
ORDER BY days_overdue DESC;

-- BNPL terminal activity
CREATE VIEW v_bnpl_terminal_activity AS
SELECT
    bt.id          AS terminal_id,
    bt.terminal_code,
    bt.terminal_name,
    mp.business_name,
    COUNT(pi.id)   AS total_invoices,
    SUM(CASE WHEN pi.status = 'approved' THEN 1 ELSE 0 END) AS approved_count,
    SUM(CASE WHEN pi.status = 'approved' THEN pi.total_amount ELSE 0 END) AS approved_amount,
    MAX(pi.created_at) AS last_invoice_at
FROM bnpl_terminals bt
JOIN merchant_profiles mp ON mp.id = bt.merchant_id
LEFT JOIN bnpl_payment_invoices pi ON pi.terminal_id = bt.id
GROUP BY bt.id, bt.terminal_code, bt.terminal_name, mp.business_name;
