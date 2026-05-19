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
CREATE TYPE msg_type_enum          AS ENUM ('otp', 'loan_alert', 'repayment_due', 'marketing');
CREATE TYPE msg_status_enum        AS ENUM ('queued', 'sent', 'delivered', 'failed');
CREATE TYPE reg_status_enum        AS ENUM ('pending', 'kyc_verified', 'active', 'rejected');
CREATE TYPE customer_type_enum     AS ENUM ('person', 'company');

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
    user_id           UUID NOT NULL UNIQUE REFERENCES users(id),
    customer_type     customer_type_enum NOT NULL DEFAULT 'person',
    polaris_cust_code VARCHAR(100) UNIQUE,  -- Polaris/OI custCode
    national_id_encrypted BYTEA NOT NULL,
    national_id_hash  BYTEA NOT NULL UNIQUE,
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
    user_id          UUID NOT NULL UNIQUE REFERENCES users(id),
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
    user_id      UUID NOT NULL UNIQUE REFERENCES users(id),
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
    idempotency_key VARCHAR(100),
    purpose         otp_purpose_enum NOT NULL,
    attempt_count   INT NOT NULL DEFAULT 0,
    ip_address      INET,
    expires_at      TIMESTAMPTZ NOT NULL,
    verified_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE user_sessions (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id      UUID NOT NULL REFERENCES users(id),
    token_hash   VARCHAR(255) NOT NULL UNIQUE,
    device_id    VARCHAR(255),
    device_type  VARCHAR(50),
    ip_address   INET,
    expires_at   TIMESTAMPTZ NOT NULL,
    revoked_at   TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Message logs
CREATE TABLE message_logs (
    id                 UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id            UUID REFERENCES users(id),
    phone_number       VARCHAR(20) NOT NULL,
    msg_type           msg_type_enum NOT NULL,
    template_id        VARCHAR(100),
    content_encrypted  BYTEA,
    status             msg_status_enum NOT NULL DEFAULT 'queued',
    provider_response  JSONB,
    sent_at            TIMESTAMPTZ,
    delivered_at       TIMESTAMPTZ,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_users_phone         ON users(phone_number);
CREATE INDEX idx_customer_type       ON customer_profiles(customer_type);
CREATE INDEX idx_customer_polaris_cust_code ON customer_profiles(polaris_cust_code);
CREATE INDEX idx_otp_phone_purpose   ON otp_sessions(phone_number, purpose);
CREATE INDEX idx_sessions_user       ON user_sessions(user_id);


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
CREATE TYPE kyc_file_type_enum    AS ENUM ('image','pdf','document','video','audio','archive','other');
CREATE TYPE kyc_file_purpose_enum AS ENUM ('portrait','selfie','id_front','id_back','passport','proof_of_address','proof_of_income','bank_statement','contract','other');
CREATE TYPE relationship_type_enum AS ENUM ('spouse','parent','child','sibling','guardian','co_borrower','emergency_contact','employer','other');
CREATE TYPE kyc_record_status_enum AS ENUM ('pending','verified','rejected','expired');
CREATE TYPE bank_account_status_enum AS ENUM ('pending','verified','rejected','disabled');
CREATE TYPE hur_data_type_enum    AS ENUM ('marital_status','employment','salary','social_health_insurance','other');
CREATE TYPE register_number_type_enum AS ENUM ('mongolian_register','foreign_register','passport','taxpayer','other');
CREATE TYPE id_card_number_type_enum AS ENUM ('national_id_card','passport','residence_permit','driver_license','other');

-- Nationality/country lookup; country_code maps to Polaris/OI countryCode.
CREATE TABLE nationalities (
    id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    country_code   VARCHAR(10) NOT NULL UNIQUE,
    polaris_nationality_id INT UNIQUE,       -- Polaris/OI nationalityId
    country_name   VARCHAR(150) NOT NULL,
    is_active      BOOLEAN NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Multiple personal identity/detail records are allowed for aliases, document variants and history
CREATE TABLE kyc_personal_details (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id         UUID NOT NULL REFERENCES customer_profiles(id),
    family_name         VARCHAR(100),
    first_name          VARCHAR(100),
    last_name           VARCHAR(100),
    nickname            VARCHAR(100),
    gender              kyc_gender_enum DEFAULT 'unknown',
    nationality_id      UUID REFERENCES nationalities(id),
    register_number_type register_number_type_enum,
    register_number_encrypted BYTEA,
    register_number_hash BYTEA,
    id_card_number_type id_card_number_type_enum,
    id_card_number_encrypted BYTEA,
    id_card_number_hash BYTEA,
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
    customer_id         UUID NOT NULL REFERENCES customer_profiles(id),
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
    customer_id         UUID NOT NULL REFERENCES customer_profiles(id),
    bank_name           VARCHAR(150) NOT NULL,
    bank_code           VARCHAR(50),
    branch_name         VARCHAR(150),
    account_number_encrypted BYTEA NOT NULL,
    account_number_hash BYTEA NOT NULL,
    iban_encrypted      BYTEA,
    iban_hash           BYTEA,
    holder_name         VARCHAR(200) NOT NULL,
    currency            VARCHAR(10) NOT NULL DEFAULT 'MNT',
    is_primary          BOOLEAN NOT NULL DEFAULT FALSE,
    status              bank_account_status_enum NOT NULL DEFAULT 'pending',
    verified_at         TIMESTAMPTZ,
    disabled_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (customer_id, id),
    UNIQUE (customer_id, bank_name, account_number_hash),
    UNIQUE (customer_id, iban_hash)
);

-- Multiple registered, residential, work and temporary addresses per customer
CREATE TABLE kyc_addresses (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id         UUID NOT NULL REFERENCES customer_profiles(id),
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
    customer_id         UUID NOT NULL REFERENCES customer_profiles(id),
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
    customer_id         UUID NOT NULL REFERENCES customer_profiles(id),
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

-- KYC files such as images, PDFs, documents, videos and proof files
CREATE TABLE kyc_customer_files (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id         UUID NOT NULL REFERENCES customer_profiles(id),
    file_type           kyc_file_type_enum NOT NULL DEFAULT 'image',
    file_purpose        kyc_file_purpose_enum NOT NULL,
    file_url            TEXT NOT NULL,
    file_name           VARCHAR(255),
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
    customer_id               UUID NOT NULL REFERENCES customer_profiles(id),
    related_customer_id       UUID REFERENCES customer_profiles(id),
    relationship_type         relationship_type_enum NOT NULL,
    family_name               VARCHAR(100),
    first_name                VARCHAR(100),
    last_name                 VARCHAR(100),
    register_number_encrypted BYTEA,
    register_number_hash      BYTEA,
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
    customer_id         UUID NOT NULL REFERENCES customer_profiles(id),
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
    national_id_checked_encrypted BYTEA NOT NULL,
    national_id_checked_hash BYTEA NOT NULL,
    status              VARCHAR(20) NOT NULL DEFAULT 'pending',  -- pending|verified|failed|expired
    response_snapshot_encrypted BYTEA,
    response_snapshot_hash BYTEA,
    error_message       TEXT,
    verified_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- HUR — universal extracted data rows; one HUR fetch may create many rows sharing request_ref
CREATE TABLE hur_data_snapshots (
    id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id           UUID NOT NULL REFERENCES customer_profiles(id),
    request_ref           VARCHAR(100) NOT NULL,
    data_type             hur_data_type_enum NOT NULL,
    record_key            VARCHAR(150),
    period_start          DATE,
    period_end            DATE,
    effective_date        DATE,
    amount                NUMERIC(14,2),
    currency              VARCHAR(10) NOT NULL DEFAULT 'MNT',
    text_value            TEXT,
    numeric_value         NUMERIC(18,4),
    date_value            DATE,
    payload               JSONB NOT NULL DEFAULT '{}',
    snapshot_date         DATE NOT NULL,
    raw_response_encrypted BYTEA,
    raw_response_hash      BYTEA,
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
    raw_response_encrypted BYTEA,
    raw_response_hash BYTEA,
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
CREATE INDEX idx_hur_request_ref   ON hur_data_snapshots(request_ref);
CREATE INDEX idx_hur_customer_type ON hur_data_snapshots(customer_id, data_type);
CREATE INDEX idx_hur_period        ON hur_data_snapshots(customer_id, data_type, period_start, period_end);
CREATE INDEX idx_hur_record_key    ON hur_data_snapshots(data_type, record_key);
CREATE INDEX idx_hur_payload_gin   ON hur_data_snapshots USING GIN (payload);
CREATE INDEX idx_sain_customer     ON sain_score_requests(customer_id);
CREATE INDEX idx_kyc_steps_cust    ON kyc_verification_steps(customer_id);
CREATE INDEX idx_kyc_personal_customer    ON kyc_personal_details(customer_id);
CREATE INDEX idx_kyc_personal_nationality  ON kyc_personal_details(nationality_id);
CREATE INDEX idx_kyc_personal_register    ON kyc_personal_details(register_number_hash);
CREATE INDEX idx_kyc_personal_id_card     ON kyc_personal_details(id_card_number_hash);
CREATE UNIQUE INDEX idx_kyc_personal_primary ON kyc_personal_details(customer_id) WHERE is_primary = TRUE;
CREATE INDEX idx_kyc_contact_customer     ON kyc_contact_infos(customer_id);
CREATE INDEX idx_kyc_contact_value        ON kyc_contact_infos(contact_type, contact_value);
CREATE UNIQUE INDEX idx_kyc_contact_primary ON kyc_contact_infos(customer_id, contact_type) WHERE is_primary = TRUE;
CREATE INDEX idx_customer_bank_accounts_customer ON customer_bank_accounts(customer_id);
CREATE INDEX idx_customer_bank_accounts_number ON customer_bank_accounts(bank_name, account_number_hash);
CREATE UNIQUE INDEX idx_customer_bank_accounts_primary ON customer_bank_accounts(customer_id) WHERE is_primary = TRUE;
CREATE INDEX idx_kyc_address_customer     ON kyc_addresses(customer_id);
CREATE UNIQUE INDEX idx_kyc_address_primary ON kyc_addresses(customer_id, address_type) WHERE is_primary = TRUE;
CREATE INDEX idx_kyc_education_customer   ON kyc_educations(customer_id);
CREATE INDEX idx_kyc_employment_customer  ON kyc_employments(customer_id);
CREATE INDEX idx_kyc_employment_current   ON kyc_employments(customer_id, is_current);
CREATE INDEX idx_kyc_files_customer       ON kyc_customer_files(customer_id);
CREATE INDEX idx_kyc_files_type_purpose   ON kyc_customer_files(file_type, file_purpose);
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
    product_id            UUID NOT NULL REFERENCES loan_products(id),
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
    UNIQUE (product_id, id),
    UNIQUE (product_id, duration_value, duration_unit)
);

-- User-selectable BNPL split-count options configured per BNPL product
CREATE TABLE bnpl_installment_options (
    id                              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id                      UUID NOT NULL REFERENCES loan_products(id),
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
    UNIQUE (product_id, id),
    UNIQUE (product_id, installment_count)
);

CREATE TABLE loan_applications (
    id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id           UUID NOT NULL REFERENCES customer_profiles(id),
    product_id            UUID NOT NULL REFERENCES loan_products(id),
    credit_score_id       UUID NOT NULL REFERENCES credit_score_results(id),
    polaris_los_acnt_code_encrypted BYTEA,  -- Polaris/OI losAcntCode from /loan/createLos
    polaris_los_acnt_code_hash BYTEA,
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
        REFERENCES customer_bank_accounts(customer_id, id),
    FOREIGN KEY (product_id, duration_option_id)
        REFERENCES loan_product_duration_options(product_id, id),
    FOREIGN KEY (product_id, bnpl_installment_option_id)
        REFERENCES bnpl_installment_options(product_id, id)
);

CREATE TABLE loans (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    application_id      UUID NOT NULL UNIQUE REFERENCES loan_applications(id),
    customer_id         UUID NOT NULL REFERENCES customer_profiles(id),
    product_id          UUID NOT NULL REFERENCES loan_products(id),
    polaris_loan_account_id UUID NOT NULL,   -- Polaris/OI loan acntCode in polaris_accounts
    polaris_deposit_account_id UUID,         -- Polaris/OI deposit acntCode used for disbursement/collection
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
    disbursed_at        TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (
        (duration_value IS NULL AND duration_unit IS NULL)
        OR (duration_value IS NOT NULL AND duration_unit IS NOT NULL)
    ),
    FOREIGN KEY (customer_id, disbursement_bank_account_id)
        REFERENCES customer_bank_accounts(customer_id, id),
    FOREIGN KEY (product_id, duration_option_id)
        REFERENCES loan_product_duration_options(product_id, id),
    FOREIGN KEY (product_id, bnpl_installment_option_id)
        REFERENCES bnpl_installment_options(product_id, id)
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
CREATE INDEX idx_loans_polaris_loan_account ON loans(polaris_loan_account_id);
CREATE INDEX idx_loans_polaris_deposit_account ON loans(polaris_deposit_account_id);


-- ============================================================
-- 5. BNPL FLOW (EMART TERMINAL QR PAYMENT)
-- ============================================================

CREATE TYPE invoice_status_enum  AS ENUM ('pending','qr_generated','processing','approved','rejected','expired','refunded');
CREATE TYPE callback_type_enum   AS ENUM ('approved','rejected','timeout');
CREATE TYPE callback_status_enum AS ENUM ('pending','sent','acknowledged','failed');
CREATE TYPE pos_txn_status_enum AS ENUM ('processing','approved','rejected','disbursed');

CREATE TABLE pos_terminals (
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
CREATE TABLE pos_payment_invoices (
    id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    terminal_id       UUID NOT NULL REFERENCES pos_terminals(id),
    merchant_id       UUID NOT NULL REFERENCES merchant_profiles(id),
    cashier_reference VARCHAR(100),
    idempotency_key   VARCHAR(100),
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
CREATE TABLE pos_qr_codes (
    id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    invoice_id              UUID NOT NULL REFERENCES pos_payment_invoices(id),
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
CREATE TABLE pos_transactions (
    id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    loan_id                 UUID REFERENCES loans(id),
    invoice_id              UUID NOT NULL UNIQUE REFERENCES pos_payment_invoices(id),
    customer_id             UUID NOT NULL REFERENCES customer_profiles(id),
    merchant_id             UUID NOT NULL REFERENCES merchant_profiles(id),
    installment_option_id   UUID REFERENCES bnpl_installment_options(id),
    total_amount            NUMERIC(14,2) NOT NULL,
    installment_count       INT NOT NULL,
    per_installment_amount  NUMERIC(14,2) NOT NULL,
    interest_amount         NUMERIC(14,2) NOT NULL DEFAULT 0,
    status                  pos_txn_status_enum NOT NULL DEFAULT 'processing',
    approved_at             TIMESTAMPTZ,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Callbacks sent back to the terminal after approval/rejection
CREATE TABLE pos_terminal_callbacks (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    transaction_id  UUID NOT NULL REFERENCES pos_transactions(id),
    terminal_id     UUID NOT NULL REFERENCES pos_terminals(id),
    idempotency_key VARCHAR(100),
    callback_type   callback_type_enum NOT NULL,
    payload         JSONB NOT NULL,
    http_status     INT,
    retry_count     INT NOT NULL DEFAULT 0,
    status          callback_status_enum NOT NULL DEFAULT 'pending',
    sent_at         TIMESTAMPTZ,
    acknowledged_at TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_invoices_terminal  ON pos_payment_invoices(terminal_id);
CREATE INDEX idx_invoices_merchant  ON pos_payment_invoices(merchant_id);
CREATE INDEX idx_qr_invoice         ON pos_qr_codes(invoice_id);
CREATE INDEX idx_qr_installment_option ON pos_qr_codes(selected_installment_option_id);
CREATE INDEX idx_pos_txn_customer  ON pos_transactions(customer_id);
CREATE INDEX idx_pos_txn_installment_option ON pos_transactions(installment_option_id);


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
    total_due            NUMERIC(14,2) GENERATED ALWAYS AS (principal_amount + interest_amount + penalty_amount) STORED,
    paid_amount          NUMERIC(14,2) NOT NULL DEFAULT 0,
    outstanding_amount   NUMERIC(14,2) GENERATED ALWAYS AS (principal_amount + interest_amount + penalty_amount - paid_amount) STORED,
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
    idempotency_key     VARCHAR(100),
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
    idempotency_key             VARCHAR(100),
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
    ledger_journal_id  UUID,
    payment_channel     payment_chan_enum NOT NULL DEFAULT 'qpay',
    transaction_ref     VARCHAR(100) NOT NULL UNIQUE,
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
CREATE TYPE ledger_journal_status_enum AS ENUM ('draft','pending','posted','failed','reversed');
CREATE TYPE ledger_entry_side_enum AS ENUM ('debit','credit');
CREATE TYPE reconciliation_status_enum AS ENUM ('unreconciled','matched','mismatched','reconciled','failed');
CREATE TYPE queue_op_enum     AS ENUM ('create_account','post_txn','update_balance','close_account');
CREATE TYPE queue_status_enum AS ENUM ('pending','processing','completed','dead_letter');

-- Master registry of all Polaris/OI account numbers used by the system.
-- Polaris/OI acntCode, txnAcntCode and contAcntCode values are stored here.
CREATE TABLE polaris_accounts (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    polaris_acnt_code_encrypted BYTEA NOT NULL,
    polaris_acnt_code_hash BYTEA NOT NULL UNIQUE,
    account_type        polaris_acc_type NOT NULL,
    owner_type          VARCHAR(20) NOT NULL,  -- customer|merchant|system
    owner_id            UUID,                  -- references the relevant profile id
    polaris_prod_code   VARCHAR(50),           -- Polaris/OI prodCode
    polaris_brch_code   VARCHAR(50),           -- Polaris/OI brchCode
    polaris_sys_no      INT,                   -- Polaris/OI sysNo
    currency            VARCHAR(10) NOT NULL DEFAULT 'MNT',
    current_balance     NUMERIC(18,2) NOT NULL DEFAULT 0,
    status              VARCHAR(20) NOT NULL DEFAULT 'active',  -- active|frozen|closed
    polaris_synced_at   TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE loans
    ADD CONSTRAINT fk_loans_polaris_loan_account
    FOREIGN KEY (polaris_loan_account_id) REFERENCES polaris_accounts(id);

ALTER TABLE loans
    ADD CONSTRAINT fk_loans_polaris_deposit_account
    FOREIGN KEY (polaris_deposit_account_id) REFERENCES polaris_accounts(id);

-- Double-entry journal header for all money movement posted or reconciled with Polaris
CREATE TABLE ledger_journals (
    id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    journal_ref           VARCHAR(100) NOT NULL UNIQUE,
    idempotency_key       VARCHAR(100) NOT NULL UNIQUE,
    source_module         VARCHAR(50) NOT NULL,   -- loans|repayment|pos|refund|settlement|etc.
    source_table          VARCHAR(100) NOT NULL,
    source_id             UUID NOT NULL,
    source_operation      VARCHAR(50) NOT NULL,
    value_date            DATE NOT NULL,
    currency              VARCHAR(10) NOT NULL DEFAULT 'MNT',
    status                ledger_journal_status_enum NOT NULL DEFAULT 'pending',
    polaris_batch_ref     VARCHAR(100),
    polaris_jrno          BIGINT,              -- Polaris/OI jrno numeric journal number
    polaris_txn_ref       VARCHAR(100),
    reconciliation_status reconciliation_status_enum NOT NULL DEFAULT 'unreconciled',
    reconciled_at         TIMESTAMPTZ,
    failure_reason        TEXT,
    reversal_of_journal_id UUID REFERENCES ledger_journals(id),
    metadata              JSONB NOT NULL DEFAULT '{}',
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_by_user_id    UUID REFERENCES users(id),
    posted_at             TIMESTAMPTZ,
    failed_at             TIMESTAMPTZ,
    reversed_at           TIMESTAMPTZ,
    version               INT NOT NULL DEFAULT 1
);

-- Double-entry lines. Posted journals must balance: total debits = total credits.
CREATE TABLE ledger_entries (
    id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    journal_id            UUID NOT NULL REFERENCES ledger_journals(id),
    line_no               INT NOT NULL CHECK (line_no > 0),
    polaris_account_id    UUID NOT NULL REFERENCES polaris_accounts(id),
    entry_side            ledger_entry_side_enum NOT NULL,
    amount                NUMERIC(14,2) NOT NULL CHECK (amount > 0),
    currency              VARCHAR(10) NOT NULL DEFAULT 'MNT',
    narration             TEXT,
    polaris_line_ref      VARCHAR(100),
    balance_after         NUMERIC(18,2),
    reconciliation_status reconciliation_status_enum NOT NULL DEFAULT 'unreconciled',
    reconciled_at         TIMESTAMPTZ,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (journal_id, line_no)
);

ALTER TABLE repayment_transactions
    ADD CONSTRAINT fk_repay_txn_ledger_journal
    FOREIGN KEY (ledger_journal_id) REFERENCES ledger_journals(id);

-- Full log of every Polaris API call (request + response).
-- Persist sanitized payloads only; redact account/register values before insert.
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
    idempotency_key VARCHAR(100),
    payload         JSONB NOT NULL,
    retry_count     INT NOT NULL DEFAULT 0,
    status          queue_status_enum NOT NULL DEFAULT 'pending',
    error_message   TEXT,
    locked_at       TIMESTAMPTZ,
    locked_by       VARCHAR(100),
    next_retry_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed_at    TIMESTAMPTZ
);

CREATE INDEX idx_ledger_journals_source ON ledger_journals(source_table, source_id, source_operation);
CREATE INDEX idx_ledger_journals_status ON ledger_journals(status, value_date);
CREATE INDEX idx_ledger_entries_journal ON ledger_entries(journal_id);
CREATE INDEX idx_ledger_entries_account ON ledger_entries(polaris_account_id);
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
    pos_transaction_id          UUID NOT NULL REFERENCES pos_transactions(id),
    merchant_id                 UUID NOT NULL REFERENCES merchant_profiles(id),
    requested_by_portal_user_id UUID REFERENCES merchant_portal_users(id),
    ledger_journal_id           UUID REFERENCES ledger_journals(id),
    idempotency_key             VARCHAR(100),
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
    ledger_journal_id  UUID REFERENCES ledger_journals(id),
    idempotency_key    VARCHAR(100),
    total_bnpl_amount  NUMERIC(14,2) NOT NULL DEFAULT 0,
    total_refunds      NUMERIC(14,2) NOT NULL DEFAULT 0,
    net_settlement     NUMERIC(14,2) GENERATED ALWAYS AS (total_bnpl_amount - total_refunds) STORED,
    transaction_count  INT NOT NULL DEFAULT 0,
    status             settle_status_enum NOT NULL DEFAULT 'pending',
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    settled_at         TIMESTAMPTZ
);

CREATE INDEX idx_portal_users_merchant  ON merchant_portal_users(merchant_id);
CREATE INDEX idx_refunds_merchant       ON merchant_refund_requests(merchant_id);
CREATE INDEX idx_refunds_pos_transaction ON merchant_refund_requests(pos_transaction_id);
CREATE INDEX idx_refunds_status         ON merchant_refund_requests(status);
CREATE INDEX idx_settlements_merchant   ON merchant_settlements(merchant_id, settlement_date);


-- ============================================================
-- STATUS TRANSITION HISTORY
-- ============================================================

CREATE TABLE loan_application_status_history (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    loan_application_id UUID NOT NULL REFERENCES loan_applications(id),
    from_status         loan_app_status,
    to_status           loan_app_status NOT NULL,
    changed_by_user_id  UUID REFERENCES users(id),
    changed_by_staff_id UUID REFERENCES staff_profiles(id),
    reason              TEXT,
    metadata            JSONB NOT NULL DEFAULT '{}',
    changed_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE loan_status_history (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    loan_id             UUID NOT NULL REFERENCES loans(id),
    from_status         loan_status_enum,
    to_status           loan_status_enum NOT NULL,
    changed_by_user_id  UUID REFERENCES users(id),
    changed_by_staff_id UUID REFERENCES staff_profiles(id),
    reason              TEXT,
    metadata            JSONB NOT NULL DEFAULT '{}',
    changed_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE repayment_schedule_status_history (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    schedule_id         UUID NOT NULL REFERENCES repayment_schedules(id),
    from_status         sched_status_enum,
    to_status           sched_status_enum NOT NULL,
    changed_by_user_id  UUID REFERENCES users(id),
    changed_by_staff_id UUID REFERENCES staff_profiles(id),
    reason              TEXT,
    metadata            JSONB NOT NULL DEFAULT '{}',
    changed_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE repayment_transaction_status_history (
    id                       UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    repayment_transaction_id UUID NOT NULL REFERENCES repayment_transactions(id),
    from_status              repay_txn_status,
    to_status                repay_txn_status NOT NULL,
    changed_by_user_id       UUID REFERENCES users(id),
    changed_by_staff_id      UUID REFERENCES staff_profiles(id),
    reason                   TEXT,
    metadata                 JSONB NOT NULL DEFAULT '{}',
    changed_at               TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE merchant_refund_status_history (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    refund_request_id   UUID NOT NULL REFERENCES merchant_refund_requests(id),
    from_status         refund_status_enum,
    to_status           refund_status_enum NOT NULL,
    changed_by_user_id  UUID REFERENCES users(id),
    changed_by_staff_id UUID REFERENCES staff_profiles(id),
    reason              TEXT,
    metadata            JSONB NOT NULL DEFAULT '{}',
    changed_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE merchant_settlement_status_history (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    settlement_id       UUID NOT NULL REFERENCES merchant_settlements(id),
    from_status         settle_status_enum,
    to_status           settle_status_enum NOT NULL,
    changed_by_user_id  UUID REFERENCES users(id),
    changed_by_staff_id UUID REFERENCES staff_profiles(id),
    reason              TEXT,
    metadata            JSONB NOT NULL DEFAULT '{}',
    changed_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE kyc_verification_step_status_history (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    kyc_verification_step_id UUID NOT NULL REFERENCES kyc_verification_steps(id),
    from_status         VARCHAR(20),
    to_status           VARCHAR(20) NOT NULL,
    changed_by_user_id  UUID REFERENCES users(id),
    changed_by_staff_id UUID REFERENCES staff_profiles(id),
    reason              TEXT,
    metadata            JSONB NOT NULL DEFAULT '{}',
    changed_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_loan_app_status_hist_app ON loan_application_status_history(loan_application_id, changed_at DESC);
CREATE INDEX idx_loan_status_hist_loan ON loan_status_history(loan_id, changed_at DESC);
CREATE INDEX idx_sched_status_hist_sched ON repayment_schedule_status_history(schedule_id, changed_at DESC);
CREATE INDEX idx_repay_txn_status_hist_txn ON repayment_transaction_status_history(repayment_transaction_id, changed_at DESC);
CREATE INDEX idx_refund_status_hist_refund ON merchant_refund_status_history(refund_request_id, changed_at DESC);
CREATE INDEX idx_settlement_status_hist_settlement ON merchant_settlement_status_history(settlement_id, changed_at DESC);
CREATE INDEX idx_kyc_step_status_hist_step ON kyc_verification_step_status_history(kyc_verification_step_id, changed_at DESC);


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
    id             UUID NOT NULL DEFAULT uuid_generate_v4(),
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
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);  -- partition by month for scalability

CREATE TABLE audit_logs_2025_01 PARTITION OF audit_logs
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
CREATE TABLE audit_logs_2026_01 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE audit_logs_2026_02 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE audit_logs_2026_03 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE audit_logs_2026_04 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE audit_logs_2026_05 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE audit_logs_2026_06 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE audit_logs_2026_07 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE audit_logs_2026_08 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE audit_logs_2026_09 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE audit_logs_2026_10 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE audit_logs_2026_11 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE audit_logs_2026_12 PARTITION OF audit_logs
    FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');
CREATE TABLE audit_logs_2027_01 PARTITION OF audit_logs
    FOR VALUES FROM ('2027-01-01') TO ('2027-02-01');
CREATE TABLE audit_logs_2027_02 PARTITION OF audit_logs
    FOR VALUES FROM ('2027-02-01') TO ('2027-03-01');
CREATE TABLE audit_logs_2027_03 PARTITION OF audit_logs
    FOR VALUES FROM ('2027-03-01') TO ('2027-04-01');
CREATE TABLE audit_logs_2027_04 PARTITION OF audit_logs
    FOR VALUES FROM ('2027-04-01') TO ('2027-05-01');
CREATE TABLE audit_logs_2027_05 PARTITION OF audit_logs
    FOR VALUES FROM ('2027-05-01') TO ('2027-06-01');
CREATE TABLE audit_logs_2027_06 PARTITION OF audit_logs
    FOR VALUES FROM ('2027-06-01') TO ('2027-07-01');
CREATE TABLE audit_logs_2027_07 PARTITION OF audit_logs
    FOR VALUES FROM ('2027-07-01') TO ('2027-08-01');
CREATE TABLE audit_logs_2027_08 PARTITION OF audit_logs
    FOR VALUES FROM ('2027-08-01') TO ('2027-09-01');
CREATE TABLE audit_logs_2027_09 PARTITION OF audit_logs
    FOR VALUES FROM ('2027-09-01') TO ('2027-10-01');
CREATE TABLE audit_logs_2027_10 PARTITION OF audit_logs
    FOR VALUES FROM ('2027-10-01') TO ('2027-11-01');
CREATE TABLE audit_logs_2027_11 PARTITION OF audit_logs
    FOR VALUES FROM ('2027-11-01') TO ('2027-12-01');
CREATE TABLE audit_logs_2027_12 PARTITION OF audit_logs
    FOR VALUES FROM ('2027-12-01') TO ('2028-01-01');
CREATE TABLE audit_logs_default PARTITION OF audit_logs DEFAULT;
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
    recipient_address_encrypted BYTEA NOT NULL,
    recipient_address_hash BYTEA NOT NULL,
    rendered_content_encrypted BYTEA,
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
    id              UUID NOT NULL DEFAULT uuid_generate_v4(),
    service_name    VARCHAR(100) NOT NULL,
    event_type      VARCHAR(100) NOT NULL,
    severity        severity_enum NOT NULL DEFAULT 'info',
    message         TEXT NOT NULL,
    metadata        JSONB,
    trace_id        VARCHAR(100),
    correlation_id  VARCHAR(100),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

CREATE TABLE system_event_logs_2025_01 PARTITION OF system_event_logs
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
CREATE TABLE system_event_logs_2026_01 PARTITION OF system_event_logs
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE system_event_logs_2026_02 PARTITION OF system_event_logs
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE system_event_logs_2026_03 PARTITION OF system_event_logs
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE system_event_logs_2026_04 PARTITION OF system_event_logs
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE system_event_logs_2026_05 PARTITION OF system_event_logs
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE system_event_logs_2026_06 PARTITION OF system_event_logs
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE system_event_logs_2026_07 PARTITION OF system_event_logs
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE system_event_logs_2026_08 PARTITION OF system_event_logs
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE system_event_logs_2026_09 PARTITION OF system_event_logs
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE system_event_logs_2026_10 PARTITION OF system_event_logs
    FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE system_event_logs_2026_11 PARTITION OF system_event_logs
    FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE system_event_logs_2026_12 PARTITION OF system_event_logs
    FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');
CREATE TABLE system_event_logs_2027_01 PARTITION OF system_event_logs
    FOR VALUES FROM ('2027-01-01') TO ('2027-02-01');
CREATE TABLE system_event_logs_2027_02 PARTITION OF system_event_logs
    FOR VALUES FROM ('2027-02-01') TO ('2027-03-01');
CREATE TABLE system_event_logs_2027_03 PARTITION OF system_event_logs
    FOR VALUES FROM ('2027-03-01') TO ('2027-04-01');
CREATE TABLE system_event_logs_2027_04 PARTITION OF system_event_logs
    FOR VALUES FROM ('2027-04-01') TO ('2027-05-01');
CREATE TABLE system_event_logs_2027_05 PARTITION OF system_event_logs
    FOR VALUES FROM ('2027-05-01') TO ('2027-06-01');
CREATE TABLE system_event_logs_2027_06 PARTITION OF system_event_logs
    FOR VALUES FROM ('2027-06-01') TO ('2027-07-01');
CREATE TABLE system_event_logs_2027_07 PARTITION OF system_event_logs
    FOR VALUES FROM ('2027-07-01') TO ('2027-08-01');
CREATE TABLE system_event_logs_2027_08 PARTITION OF system_event_logs
    FOR VALUES FROM ('2027-08-01') TO ('2027-09-01');
CREATE TABLE system_event_logs_2027_09 PARTITION OF system_event_logs
    FOR VALUES FROM ('2027-09-01') TO ('2027-10-01');
CREATE TABLE system_event_logs_2027_10 PARTITION OF system_event_logs
    FOR VALUES FROM ('2027-10-01') TO ('2027-11-01');
CREATE TABLE system_event_logs_2027_11 PARTITION OF system_event_logs
    FOR VALUES FROM ('2027-11-01') TO ('2027-12-01');
CREATE TABLE system_event_logs_2027_12 PARTITION OF system_event_logs
    FOR VALUES FROM ('2027-12-01') TO ('2028-01-01');
CREATE TABLE system_event_logs_default PARTITION OF system_event_logs DEFAULT;

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
-- MUTABILITY, VERSIONING & RETENTION METADATA
-- ============================================================

DO $$
DECLARE
    v_table TEXT;
BEGIN
    FOREACH v_table IN ARRAY ARRAY[
        'customer_profiles',
        'customer_bank_accounts',
        'kyc_verification_steps',
        'loan_applications',
        'loans',
        'pos_payment_invoices',
        'pos_transactions',
        'qpay_repayment_invoices',
        'repayment_schedules',
        'repayment_transactions',
        'merchant_refund_requests',
        'merchant_settlements'
    ] LOOP
        EXECUTE format(
            'ALTER TABLE %I
                ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                ADD COLUMN updated_by_user_id UUID REFERENCES users(id),
                ADD COLUMN approved_by_staff_id UUID REFERENCES staff_profiles(id),
                ADD COLUMN rejected_by_staff_id UUID REFERENCES staff_profiles(id),
                ADD COLUMN version INT NOT NULL DEFAULT 1',
            v_table
        );
    END LOOP;
END $$;

DO $$
DECLARE
    v_table TEXT;
BEGIN
    FOREACH v_table IN ARRAY ARRAY[
        'otp_sessions',
        'message_logs',
        'nationalities',
        'merchant_profiles',
        'staff_profiles',
        'kyc_personal_details',
        'kyc_contact_infos',
        'kyc_addresses',
        'kyc_educations',
        'kyc_employments',
        'kyc_customer_files',
        'kyc_related_customers',
        'kyc_signature_images',
        'dan_verifications',
        'sain_score_requests',
        'loan_limits',
        'loan_products',
        'loan_product_duration_options',
        'bnpl_installment_options',
        'pos_terminals',
        'pos_qr_codes',
        'pos_terminal_callbacks',
        'qpay_repayment_callbacks',
        'penalty_records',
        'polaris_accounts',
        'polaris_sync_queue',
        'merchant_portal_users',
        'merchant_return_items',
        'service_pause_windows',
        'notification_templates',
        'notification_logs'
    ] LOOP
        EXECUTE format(
            'ALTER TABLE %I
                ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                ADD COLUMN updated_by_user_id UUID REFERENCES users(id),
                ADD COLUMN version INT NOT NULL DEFAULT 1',
            v_table
        );
    END LOOP;
END $$;

DO $$
DECLARE
    v_table TEXT;
BEGIN
    FOREACH v_table IN ARRAY ARRAY[
        'users',
        'message_logs',
        'otp_sessions',
        'user_sessions',
        'customer_profiles',
        'merchant_profiles',
        'staff_profiles',
        'kyc_personal_details',
        'kyc_contact_infos',
        'customer_bank_accounts',
        'kyc_addresses',
        'kyc_educations',
        'kyc_employments',
        'kyc_customer_files',
        'kyc_related_customers',
        'kyc_signature_images',
        'dan_verifications',
        'hur_data_snapshots',
        'sain_score_requests',
        'notification_logs'
    ] LOOP
        EXECUTE format(
            'ALTER TABLE %I
                ADD COLUMN deleted_at TIMESTAMPTZ,
                ADD COLUMN deleted_by_user_id UUID REFERENCES users(id),
                ADD COLUMN delete_reason TEXT,
                ADD COLUMN anonymized_at TIMESTAMPTZ,
                ADD COLUMN retention_until DATE',
            v_table
        );
    END LOOP;
END $$;


-- ============================================================
-- DATA INTEGRITY & IDEMPOTENCY GUARDS
-- ============================================================

ALTER TABLE loan_limits
    ADD CONSTRAINT chk_loan_limits_amounts CHECK (
        max_total_limit >= 0
        AND one_tap_limit >= 0
        AND bnpl_limit >= 0
        AND sme_limit >= 0
        AND utilized_amount >= 0
        AND utilized_amount <= max_total_limit
        AND max_total_limit >= one_tap_limit
        AND max_total_limit >= bnpl_limit
        AND max_total_limit >= sme_limit
    );

ALTER TABLE loan_products
    ADD CONSTRAINT chk_loan_products_amounts CHECK (
        min_amount >= 0
        AND max_amount >= min_amount
        AND annual_interest_rate >= 0
        AND annual_interest_rate <= 1
        AND max_term_months > 0
    );

ALTER TABLE loan_product_duration_options
    ADD CONSTRAINT chk_duration_options_amounts CHECK (
        (min_amount IS NULL OR min_amount >= 0)
        AND (max_amount IS NULL OR max_amount >= 0)
        AND fee_rate >= 0
        AND fee_rate <= 1
        AND fee_amount >= 0
        AND (annual_interest_rate IS NULL OR (annual_interest_rate >= 0 AND annual_interest_rate <= 1))
    );

ALTER TABLE bnpl_installment_options
    ADD CONSTRAINT chk_bnpl_installment_options_amounts CHECK (
        (min_amount IS NULL OR min_amount >= 0)
        AND (max_amount IS NULL OR max_amount >= 0)
        AND fee_rate >= 0
        AND fee_rate <= 1
        AND fee_amount >= 0
        AND (annual_interest_rate IS NULL OR (annual_interest_rate >= 0 AND annual_interest_rate <= 1))
    );

ALTER TABLE kyc_employments
    ADD CONSTRAINT chk_kyc_employments_income CHECK (
        monthly_income IS NULL OR monthly_income >= 0
    );

ALTER TABLE hur_data_snapshots
    ADD CONSTRAINT chk_hur_data_snapshots_amount CHECK (
        amount IS NULL OR amount >= 0
    );

ALTER TABLE loan_applications
    ADD CONSTRAINT chk_loan_applications_amount CHECK (requested_amount > 0);

ALTER TABLE loans
    ADD CONSTRAINT chk_loans_amounts CHECK (
        principal_amount > 0
        AND (disbursed_amount IS NULL OR (disbursed_amount >= 0 AND disbursed_amount <= principal_amount))
        AND interest_rate >= 0
        AND interest_rate <= 1
        AND (total_payable IS NULL OR total_payable >= principal_amount)
    );

ALTER TABLE pos_payment_invoices
    ADD CONSTRAINT chk_pos_payment_invoices_amount CHECK (total_amount > 0);

ALTER TABLE pos_transactions
    ADD CONSTRAINT chk_pos_transactions_amounts CHECK (
        total_amount > 0
        AND installment_count > 0
        AND per_installment_amount > 0
        AND interest_amount >= 0
    );

ALTER TABLE repayment_schedules
    ADD CONSTRAINT chk_repayment_schedules_amounts CHECK (
        principal_amount >= 0
        AND interest_amount >= 0
        AND penalty_amount >= 0
        AND paid_amount >= 0
        AND paid_amount <= principal_amount + interest_amount + penalty_amount
    );

ALTER TABLE qpay_repayment_invoices
    ADD CONSTRAINT chk_qpay_repayment_invoices_amount CHECK (amount > 0);

ALTER TABLE repayment_transactions
    ADD CONSTRAINT chk_repayment_transactions_amounts CHECK (
        amount > 0
        AND principal_portion >= 0
        AND interest_portion >= 0
        AND penalty_portion >= 0
        AND principal_portion + interest_portion + penalty_portion = amount
    );

ALTER TABLE penalty_records
    ADD CONSTRAINT chk_penalty_records_amounts CHECK (
        penalty_amount >= 0
        AND overdue_days >= 0
    );

ALTER TABLE polaris_accounts
    ADD CONSTRAINT chk_polaris_accounts_balance CHECK (current_balance >= 0);

ALTER TABLE ledger_entries
    ADD CONSTRAINT chk_ledger_entries_balance_after CHECK (
        balance_after IS NULL OR balance_after >= 0
    );

ALTER TABLE merchant_refund_requests
    ADD CONSTRAINT chk_merchant_refund_requests_amount CHECK (refund_amount > 0);

ALTER TABLE merchant_return_items
    ADD CONSTRAINT chk_merchant_return_items_amounts CHECK (
        quantity > 0
        AND unit_price >= 0
    );

ALTER TABLE merchant_settlements
    ADD CONSTRAINT chk_merchant_settlements_amounts CHECK (
        total_bnpl_amount >= 0
        AND total_refunds >= 0
        AND total_refunds <= total_bnpl_amount
    );

ALTER TABLE customer_profiles
    ADD CONSTRAINT chk_customer_profiles_pii_hash CHECK (octet_length(national_id_hash) = 32);

ALTER TABLE kyc_personal_details
    ADD CONSTRAINT chk_kyc_personal_hashes CHECK (
        (register_number_hash IS NULL OR octet_length(register_number_hash) = 32)
        AND (id_card_number_hash IS NULL OR octet_length(id_card_number_hash) = 32)
    );

ALTER TABLE customer_bank_accounts
    ADD CONSTRAINT chk_customer_bank_account_hashes CHECK (
        octet_length(account_number_hash) = 32
        AND (iban_hash IS NULL OR octet_length(iban_hash) = 32)
    );

ALTER TABLE loan_applications
    ADD CONSTRAINT chk_loan_applications_polaris_los_acnt_code_hash CHECK (
        polaris_los_acnt_code_hash IS NULL OR octet_length(polaris_los_acnt_code_hash) = 32
    );

ALTER TABLE kyc_related_customers
    ADD CONSTRAINT chk_kyc_related_customer_hashes CHECK (
        register_number_hash IS NULL OR octet_length(register_number_hash) = 32
    );

ALTER TABLE dan_verifications
    ADD CONSTRAINT chk_dan_verifications_hashes CHECK (
        octet_length(national_id_checked_hash) = 32
        AND (response_snapshot_hash IS NULL OR octet_length(response_snapshot_hash) = 32)
    );

ALTER TABLE hur_data_snapshots
    ADD CONSTRAINT chk_hur_data_snapshots_hashes CHECK (
        raw_response_hash IS NULL OR octet_length(raw_response_hash) = 32
    );

ALTER TABLE sain_score_requests
    ADD CONSTRAINT chk_sain_score_requests_hashes CHECK (
        raw_response_hash IS NULL OR octet_length(raw_response_hash) = 32
    );

ALTER TABLE notification_logs
    ADD CONSTRAINT chk_notification_recipient_hash CHECK (octet_length(recipient_address_hash) = 32);

ALTER TABLE polaris_accounts
    ADD CONSTRAINT chk_polaris_acnt_code_hash CHECK (octet_length(polaris_acnt_code_hash) = 32);

CREATE UNIQUE INDEX idx_otp_sessions_idempotency
    ON otp_sessions(idempotency_key)
    WHERE idempotency_key IS NOT NULL;

CREATE UNIQUE INDEX idx_pos_invoice_terminal_cashier_ref
    ON pos_payment_invoices(terminal_id, cashier_reference)
    WHERE cashier_reference IS NOT NULL;

CREATE UNIQUE INDEX idx_pos_payment_invoice_idempotency
    ON pos_payment_invoices(idempotency_key)
    WHERE idempotency_key IS NOT NULL;

CREATE UNIQUE INDEX idx_pos_txn_loan_unique
    ON pos_transactions(loan_id)
    WHERE loan_id IS NOT NULL;

CREATE UNIQUE INDEX idx_pos_terminal_callbacks_once
    ON pos_terminal_callbacks(transaction_id, callback_type);

CREATE UNIQUE INDEX idx_pos_terminal_callbacks_idempotency
    ON pos_terminal_callbacks(idempotency_key)
    WHERE idempotency_key IS NOT NULL;

CREATE UNIQUE INDEX idx_qpay_repayment_invoice_idempotency
    ON qpay_repayment_invoices(idempotency_key)
    WHERE idempotency_key IS NOT NULL;

CREATE UNIQUE INDEX idx_qpay_callbacks_payment_unique
    ON qpay_repayment_callbacks(qpay_payment_id)
    WHERE qpay_payment_id IS NOT NULL;

CREATE UNIQUE INDEX idx_qpay_callbacks_idempotency
    ON qpay_repayment_callbacks(idempotency_key)
    WHERE idempotency_key IS NOT NULL;

CREATE UNIQUE INDEX idx_repay_txn_completed_invoice
    ON repayment_transactions(qpay_repayment_invoice_id)
    WHERE qpay_repayment_invoice_id IS NOT NULL
      AND status = 'completed';

CREATE UNIQUE INDEX idx_loan_apps_polaris_los_acnt_code_hash
    ON loan_applications(polaris_los_acnt_code_hash)
    WHERE polaris_los_acnt_code_hash IS NOT NULL;

CREATE UNIQUE INDEX idx_ledger_journals_polaris_txn_ref
    ON ledger_journals(polaris_txn_ref)
    WHERE polaris_txn_ref IS NOT NULL;

CREATE UNIQUE INDEX idx_ledger_journals_polaris_jrno
    ON ledger_journals(polaris_jrno)
    WHERE polaris_jrno IS NOT NULL;

CREATE UNIQUE INDEX idx_ledger_entries_polaris_line_ref
    ON ledger_entries(polaris_line_ref)
    WHERE polaris_line_ref IS NOT NULL;

CREATE UNIQUE INDEX idx_sync_queue_idempotency
    ON polaris_sync_queue(idempotency_key)
    WHERE idempotency_key IS NOT NULL;

CREATE UNIQUE INDEX idx_sync_queue_active_source
    ON polaris_sync_queue(source_table, source_id, operation)
    WHERE status IN ('pending', 'processing');

CREATE UNIQUE INDEX idx_refunds_full_once_per_pos_txn
    ON merchant_refund_requests(pos_transaction_id)
    WHERE refund_type = 'full'
      AND status <> 'rejected';

CREATE UNIQUE INDEX idx_refunds_idempotency
    ON merchant_refund_requests(idempotency_key)
    WHERE idempotency_key IS NOT NULL;

CREATE UNIQUE INDEX idx_settlements_merchant_date_unique
    ON merchant_settlements(merchant_id, settlement_date);

CREATE UNIQUE INDEX idx_settlements_idempotency
    ON merchant_settlements(idempotency_key)
    WHERE idempotency_key IS NOT NULL;


-- Posted journals are valid only when they have at least two lines and balance exactly.
CREATE OR REPLACE FUNCTION assert_posted_ledger_journal_balance(p_journal_id UUID)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_status ledger_journal_status_enum;
    v_line_count INT;
    v_total_debit NUMERIC(18,2);
    v_total_credit NUMERIC(18,2);
BEGIN
    SELECT
        lj.status,
        COUNT(le.id),
        COALESCE(SUM(le.amount) FILTER (WHERE le.entry_side = 'debit'), 0),
        COALESCE(SUM(le.amount) FILTER (WHERE le.entry_side = 'credit'), 0)
    INTO v_status, v_line_count, v_total_debit, v_total_credit
    FROM ledger_journals lj
    LEFT JOIN ledger_entries le ON le.journal_id = lj.id
    WHERE lj.id = p_journal_id
    GROUP BY lj.id, lj.status;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF v_status = 'posted' AND (v_line_count < 2 OR v_total_debit <> v_total_credit) THEN
        RAISE EXCEPTION 'Posted ledger journal % must have at least two balanced lines: debit %, credit %',
            p_journal_id, v_total_debit, v_total_credit
            USING ERRCODE = '23514';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION validate_posted_ledger_journal_balance()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_journal_id UUID;
BEGIN
    IF TG_TABLE_NAME = 'ledger_journals' THEN
        IF TG_OP = 'DELETE' THEN
            v_journal_id := OLD.id;
        ELSE
            v_journal_id := NEW.id;
        END IF;

        PERFORM assert_posted_ledger_journal_balance(v_journal_id);
    ELSIF TG_OP = 'DELETE' THEN
        PERFORM assert_posted_ledger_journal_balance(OLD.journal_id);
    ELSIF TG_OP = 'UPDATE' AND OLD.journal_id IS DISTINCT FROM NEW.journal_id THEN
        PERFORM assert_posted_ledger_journal_balance(OLD.journal_id);
        PERFORM assert_posted_ledger_journal_balance(NEW.journal_id);
    ELSE
        PERFORM assert_posted_ledger_journal_balance(NEW.journal_id);
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_validate_ledger_journal_balance_on_journal
AFTER INSERT OR UPDATE OF status ON ledger_journals
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_posted_ledger_journal_balance();

CREATE CONSTRAINT TRIGGER trg_validate_ledger_journal_balance_on_entries
AFTER INSERT OR UPDATE OR DELETE ON ledger_entries
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION validate_posted_ledger_journal_balance();


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

CREATE TRIGGER trg_pause_pos_payment_invoice
BEFORE INSERT OR UPDATE ON pos_payment_invoices
FOR EACH ROW EXECUTE FUNCTION prevent_when_service_paused('bnpl');

CREATE TRIGGER trg_pause_loan_creation
BEFORE INSERT ON loans
FOR EACH ROW EXECUTE FUNCTION prevent_when_service_paused('loan_disbursement');

CREATE TRIGGER trg_pause_loan_disbursement_update
BEFORE UPDATE OF disbursed_at ON loans
FOR EACH ROW
WHEN (NEW.disbursed_at IS DISTINCT FROM OLD.disbursed_at)
EXECUTE FUNCTION prevent_when_service_paused('loan_disbursement');

CREATE TRIGGER trg_pause_ledger_journal
BEFORE INSERT OR UPDATE ON ledger_journals
FOR EACH ROW EXECUTE FUNCTION prevent_when_service_paused('polaris_sync');

CREATE TRIGGER trg_pause_ledger_entry
BEFORE INSERT OR UPDATE ON ledger_entries
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

CREATE OR REPLACE FUNCTION current_app_user_id()
RETURNS UUID
LANGUAGE SQL
STABLE
AS $$
    SELECT NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID;
$$;

CREATE OR REPLACE FUNCTION is_current_staff()
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM staff_profiles
        WHERE user_id = current_app_user_id()
    );
$$;

CREATE OR REPLACE FUNCTION is_current_customer(p_customer_id UUID)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM customer_profiles
        WHERE id = p_customer_id
          AND user_id = current_app_user_id()
    );
$$;

CREATE OR REPLACE FUNCTION is_current_merchant(p_merchant_id UUID)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM merchant_profiles
        WHERE id = p_merchant_id
          AND user_id = current_app_user_id()
    )
    OR EXISTS (
        SELECT 1
        FROM merchant_portal_users
        WHERE merchant_id = p_merchant_id
          AND user_id = current_app_user_id()
          AND status = 'active'
    );
$$;

CREATE OR REPLACE FUNCTION is_current_loan_customer(p_loan_id UUID)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM loans
        WHERE id = p_loan_id
          AND is_current_customer(customer_id)
    );
$$;

ALTER TABLE customer_profiles   ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_personal_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_contact_infos    ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_bank_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_addresses        ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_educations       ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_employments      ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_customer_files   ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_related_customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_signature_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE merchant_profiles   ENABLE ROW LEVEL SECURITY;
ALTER TABLE loan_applications   ENABLE ROW LEVEL SECURITY;
ALTER TABLE loans               ENABLE ROW LEVEL SECURITY;
ALTER TABLE repayment_schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE qpay_repayment_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE repayment_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE pos_transactions    ENABLE ROW LEVEL SECURITY;

CREATE POLICY pol_customer_profiles_select ON customer_profiles
    FOR SELECT USING (is_current_staff() OR user_id = current_app_user_id());
CREATE POLICY pol_customer_profiles_insert ON customer_profiles
    FOR INSERT WITH CHECK (is_current_staff() OR user_id = current_app_user_id());
CREATE POLICY pol_customer_profiles_update ON customer_profiles
    FOR UPDATE USING (is_current_staff() OR user_id = current_app_user_id())
    WITH CHECK (is_current_staff() OR user_id = current_app_user_id());

DO $$
DECLARE
    v_table TEXT;
BEGIN
    FOREACH v_table IN ARRAY ARRAY[
        'kyc_personal_details',
        'kyc_contact_infos',
        'customer_bank_accounts',
        'kyc_addresses',
        'kyc_educations',
        'kyc_employments',
        'kyc_customer_files',
        'kyc_related_customers',
        'kyc_signature_images'
    ] LOOP
        EXECUTE format(
            'CREATE POLICY %I ON %I FOR SELECT USING (is_current_staff() OR is_current_customer(customer_id))',
            'pol_' || v_table || '_select',
            v_table
        );
        EXECUTE format(
            'CREATE POLICY %I ON %I FOR INSERT WITH CHECK (is_current_staff() OR is_current_customer(customer_id))',
            'pol_' || v_table || '_insert',
            v_table
        );
        EXECUTE format(
            'CREATE POLICY %I ON %I FOR UPDATE USING (is_current_staff() OR is_current_customer(customer_id)) WITH CHECK (is_current_staff() OR is_current_customer(customer_id))',
            'pol_' || v_table || '_update',
            v_table
        );
    END LOOP;
END $$;

CREATE POLICY pol_merchant_profiles_select ON merchant_profiles
    FOR SELECT USING (is_current_staff() OR is_current_merchant(id));
CREATE POLICY pol_merchant_profiles_insert ON merchant_profiles
    FOR INSERT WITH CHECK (is_current_staff() OR user_id = current_app_user_id());
CREATE POLICY pol_merchant_profiles_update ON merchant_profiles
    FOR UPDATE USING (is_current_staff() OR is_current_merchant(id))
    WITH CHECK (is_current_staff() OR is_current_merchant(id));

CREATE POLICY pol_loan_applications_select ON loan_applications
    FOR SELECT USING (is_current_staff() OR is_current_customer(customer_id));
CREATE POLICY pol_loan_applications_insert ON loan_applications
    FOR INSERT WITH CHECK (is_current_staff() OR is_current_customer(customer_id));
CREATE POLICY pol_loan_applications_update ON loan_applications
    FOR UPDATE USING (is_current_staff())
    WITH CHECK (is_current_staff());

CREATE POLICY pol_loans_select ON loans
    FOR SELECT USING (is_current_staff() OR is_current_customer(customer_id));
CREATE POLICY pol_loans_insert ON loans
    FOR INSERT WITH CHECK (is_current_staff());
CREATE POLICY pol_loans_update ON loans
    FOR UPDATE USING (is_current_staff())
    WITH CHECK (is_current_staff());

CREATE POLICY pol_repayment_schedules_select ON repayment_schedules
    FOR SELECT USING (is_current_staff() OR is_current_loan_customer(loan_id));
CREATE POLICY pol_repayment_schedules_insert ON repayment_schedules
    FOR INSERT WITH CHECK (is_current_staff());
CREATE POLICY pol_repayment_schedules_update ON repayment_schedules
    FOR UPDATE USING (is_current_staff())
    WITH CHECK (is_current_staff());

CREATE POLICY pol_qpay_repayment_invoices_select ON qpay_repayment_invoices
    FOR SELECT USING (is_current_staff() OR is_current_customer(customer_id));
CREATE POLICY pol_qpay_repayment_invoices_insert ON qpay_repayment_invoices
    FOR INSERT WITH CHECK (is_current_staff() OR is_current_customer(customer_id));
CREATE POLICY pol_qpay_repayment_invoices_update ON qpay_repayment_invoices
    FOR UPDATE USING (is_current_staff())
    WITH CHECK (is_current_staff());

CREATE POLICY pol_repayment_transactions_select ON repayment_transactions
    FOR SELECT USING (is_current_staff() OR is_current_customer(customer_id));
CREATE POLICY pol_repayment_transactions_insert ON repayment_transactions
    FOR INSERT WITH CHECK (is_current_staff());
CREATE POLICY pol_repayment_transactions_update ON repayment_transactions
    FOR UPDATE USING (is_current_staff())
    WITH CHECK (is_current_staff());

CREATE POLICY pol_pos_transactions_select ON pos_transactions
    FOR SELECT USING (
        is_current_staff()
        OR is_current_customer(customer_id)
        OR is_current_merchant(merchant_id)
    );
CREATE POLICY pol_pos_transactions_insert ON pos_transactions
    FOR INSERT WITH CHECK (is_current_staff() OR is_current_merchant(merchant_id));
CREATE POLICY pol_pos_transactions_update ON pos_transactions
    FOR UPDATE USING (is_current_staff() OR is_current_merchant(merchant_id))
    WITH CHECK (is_current_staff() OR is_current_merchant(merchant_id));


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
    encode(cp.national_id_hash, 'hex') AS national_id_hash,
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
GROUP BY cp.id, cp.first_name, cp.last_name, cp.national_id_hash,
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

-- POS terminal activity
CREATE VIEW v_pos_terminal_activity AS
SELECT
    bt.id          AS terminal_id,
    bt.terminal_code,
    bt.terminal_name,
    mp.business_name,
    COUNT(pi.id)   AS total_invoices,
    SUM(CASE WHEN pi.status = 'approved' THEN 1 ELSE 0 END) AS approved_count,
    SUM(CASE WHEN pi.status = 'approved' THEN pi.total_amount ELSE 0 END) AS approved_amount,
    MAX(pi.created_at) AS last_invoice_at
FROM pos_terminals bt
JOIN merchant_profiles mp ON mp.id = bt.merchant_id
LEFT JOIN pos_payment_invoices pi ON pi.terminal_id = bt.id
GROUP BY bt.id, bt.terminal_code, bt.terminal_name, mp.business_name;
