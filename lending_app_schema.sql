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
CREATE TYPE auth_factor_status_enum AS ENUM ('active','locked','disabled','revoked');
CREATE TYPE login_auth_method_enum AS ENUM ('password','otp','biometric');
CREATE TYPE txn_auth_method_enum   AS ENUM ('pin','biometric');
CREATE TYPE txn_auth_status_enum   AS ENUM ('pending','authorized','failed','expired','cancelled');
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
    primary_deposit_account_id UUID,        -- FK added after Polaris account registry is created
    polaris_cif_status VARCHAR(30) NOT NULL DEFAULT 'pending', -- pending|synced|failed|pending_reconcile
    polaris_cif_synced_at TIMESTAMPTZ,
    polaris_kyc_sync_status VARCHAR(30) NOT NULL DEFAULT 'pending',
    polaris_kyc_synced_at TIMESTAMPTZ,
    polaris_sync_error TEXT,
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
    polaris_merchant_passive_account_id UUID,
    polaris_settlement_account_id UUID,
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

-- Customer transaction PIN. The raw four-digit PIN is validated by the app and never stored.
CREATE TABLE customer_pin_credentials (
    id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id          UUID NOT NULL UNIQUE REFERENCES customer_profiles(id),
    pin_hash             VARCHAR(255) NOT NULL, -- KMS-peppered hash of the four-digit PIN
    pin_key_version      VARCHAR(50),
    pin_length           SMALLINT NOT NULL DEFAULT 4 CHECK (pin_length = 4),
    status               auth_factor_status_enum NOT NULL DEFAULT 'active',
    failed_attempt_count INT NOT NULL DEFAULT 0 CHECK (failed_attempt_count >= 0),
    locked_until         TIMESTAMPTZ,
    last_verified_at     TIMESTAMPTZ,
    changed_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Device biometric/passkey credentials. No biometric template is stored server-side.
CREATE TABLE customer_biometric_credentials (
    id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id             UUID NOT NULL REFERENCES customer_profiles(id),
    credential_id_hash      BYTEA NOT NULL UNIQUE,
    credential_public_key   BYTEA NOT NULL,
    authenticator_aaguid    UUID,
    device_id               VARCHAR(255) NOT NULL,
    device_name             VARCHAR(100),
    platform                VARCHAR(50),
    sign_count              BIGINT NOT NULL DEFAULT 0 CHECK (sign_count >= 0),
    enabled_for_login       BOOLEAN NOT NULL DEFAULT TRUE,
    enabled_for_transactions BOOLEAN NOT NULL DEFAULT TRUE,
    status                  auth_factor_status_enum NOT NULL DEFAULT 'active',
    last_used_at            TIMESTAMPTZ,
    revoked_at              TIMESTAMPTZ,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (customer_id, id)
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
    login_method  login_auth_method_enum NOT NULL DEFAULT 'otp',
    biometric_credential_id UUID REFERENCES customer_biometric_credentials(id),
    ip_address   INET,
    expires_at   TIMESTAMPTZ NOT NULL,
    revoked_at   TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (login_method <> 'biometric' OR biometric_credential_id IS NOT NULL)
);

-- Records customer authorization for money-moving actions using PIN or biometric.
CREATE TABLE customer_transaction_authorizations (
    id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id             UUID NOT NULL REFERENCES customer_profiles(id),
    session_id              UUID REFERENCES user_sessions(id),
    source_table            VARCHAR(100) NOT NULL,
    source_id               UUID NOT NULL,
    authorization_ref       VARCHAR(100) NOT NULL UNIQUE,
    auth_method             txn_auth_method_enum NOT NULL,
    biometric_credential_id UUID,
    amount                  NUMERIC(14,2),
    currency                VARCHAR(10) NOT NULL DEFAULT 'MNT',
    status                  txn_auth_status_enum NOT NULL DEFAULT 'pending',
    failure_reason          TEXT,
    authorized_at           TIMESTAMPTZ,
    expires_at              TIMESTAMPTZ,
    metadata                JSONB NOT NULL DEFAULT '{}',
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (customer_id, id),
    FOREIGN KEY (customer_id, biometric_credential_id)
        REFERENCES customer_biometric_credentials(customer_id, id),
    CHECK (
        (auth_method = 'biometric' AND biometric_credential_id IS NOT NULL)
        OR (auth_method = 'pin' AND biometric_credential_id IS NULL)
    ),
    CHECK (amount IS NULL OR amount >= 0),
    CHECK (status <> 'authorized' OR authorized_at IS NOT NULL)
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
CREATE INDEX idx_customer_pin_credentials_status ON customer_pin_credentials(customer_id, status);
CREATE INDEX idx_customer_biometric_credentials_customer ON customer_biometric_credentials(customer_id, status);
CREATE UNIQUE INDEX idx_customer_biometric_credentials_active_device
    ON customer_biometric_credentials(customer_id, device_id)
    WHERE status = 'active';
CREATE INDEX idx_otp_phone_purpose   ON otp_sessions(phone_number, purpose);
CREATE INDEX idx_sessions_user       ON user_sessions(user_id);
CREATE INDEX idx_sessions_biometric_credential ON user_sessions(biometric_credential_id);
CREATE INDEX idx_txn_auth_customer_status ON customer_transaction_authorizations(customer_id, status);
CREATE INDEX idx_txn_auth_source ON customer_transaction_authorizations(source_table, source_id);
CREATE INDEX idx_txn_auth_session ON customer_transaction_authorizations(session_id);
CREATE UNIQUE INDEX idx_txn_auth_authorized_source
    ON customer_transaction_authorizations(source_table, source_id)
    WHERE status = 'authorized';


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
    fico_score          NUMERIC(6,2),
    custom_score        NUMERIC(6,2),
    final_score         NUMERIC(6,2) NOT NULL,
    risk_grade          VARCHAR(5),
    algorithm_version   VARCHAR(20) NOT NULL,
    custom_model_version VARCHAR(50),
    score_breakdown     JSONB,
    polaris_score_sync_status VARCHAR(30) NOT NULL DEFAULT 'pending',
    polaris_score_synced_at TIMESTAMPTZ,
    polaris_score_sync_error TEXT,
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
    active_credit_line_account_id UUID,
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
CREATE TYPE loan_app_status     AS ENUM (
    'draft',
    'submitted',
    'approved',
    'pending_core_setup',
    'pending_grant',
    'pending_reconcile',
    'disbursed',
    'rejected',
    'cancelled'
);
CREATE TYPE loan_status_enum    AS ENUM (
    'pending_core_setup',
    'pending_schedule',
    'pending_line_link',
    'pending_grant',
    'pending_bnpl_transfer',
    'pending_reconcile',
    'active',
    'closed',
    'defaulted',
    'written_off',
    'failed',
    'cancelled'
);
CREATE TYPE repayment_freq_enum AS ENUM ('daily','weekly','monthly');
CREATE TYPE loan_duration_unit_enum AS ENUM ('day','month');

CREATE TABLE loan_products (
    id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_type          product_type_enum NOT NULL,
    product_code          VARCHAR(20) NOT NULL UNIQUE,
    polaris_product_config_id UUID,          -- FK added after Polaris product config table is created
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
    requested_customer_deposit_account_id UUID,
    credit_line_account_id UUID,
    credit_limit_reservation_id UUID,
    requested_amount      NUMERIC(14,2) NOT NULL,
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
    polaris_product_config_id UUID NOT NULL, -- child loan account product config selected at approval
    polaris_loan_account_id UUID,            -- Polaris/OI child loan acntCode in polaris_accounts
    polaris_deposit_account_id UUID,         -- Customer Polaris CASA/deposit acntCode used for grant/repayment
    customer_deposit_account_id UUID,
    credit_line_account_id UUID,
    credit_limit_reservation_id UUID UNIQUE,
    loan_number         VARCHAR(40) NOT NULL UNIQUE,
    principal_amount    NUMERIC(14,2) NOT NULL,
    disbursed_amount    NUMERIC(14,2),
    interest_rate       NUMERIC(6,4) NOT NULL,
    duration_option_id  UUID REFERENCES loan_product_duration_options(id),
    duration_value      INT CHECK (duration_value IS NULL OR duration_value > 0),
    duration_unit       loan_duration_unit_enum,
    term_months         INT,          -- legacy/monthly products; prefer duration_value + duration_unit
    bnpl_installment_option_id UUID REFERENCES bnpl_installment_options(id),
    total_payable       NUMERIC(14,2),
    maturity_date       DATE,
    status              loan_status_enum NOT NULL DEFAULT 'pending_core_setup',
    schedule_status     VARCHAR(30) NOT NULL DEFAULT 'not_started',
    line_link_status    VARCHAR(30) NOT NULL DEFAULT 'not_started',
    grant_status        VARCHAR(30) NOT NULL DEFAULT 'not_started',
    bnpl_merchant_transfer_status VARCHAR(30) NOT NULL DEFAULT 'not_required',
    polaris_schedule_created_at TIMESTAMPTZ,
    polaris_line_linked_at TIMESTAMPTZ,
    grant_ledger_journal_id UUID,
    grant_polaris_jrno  BIGINT,
    bnpl_merchant_transfer_journal_id UUID,
    bnpl_merchant_transfer_polaris_jrno BIGINT,
    disbursed_at        TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (
        (duration_value IS NULL AND duration_unit IS NULL)
        OR (duration_value IS NOT NULL AND duration_unit IS NOT NULL)
    ),
    FOREIGN KEY (product_id, duration_option_id)
        REFERENCES loan_product_duration_options(product_id, id),
    FOREIGN KEY (product_id, bnpl_installment_option_id)
        REFERENCES bnpl_installment_options(product_id, id)
);

CREATE INDEX idx_loans_customer     ON loans(customer_id);
CREATE INDEX idx_loan_apps_customer ON loan_applications(customer_id);
CREATE INDEX idx_loan_apps_customer_deposit ON loan_applications(requested_customer_deposit_account_id);
CREATE INDEX idx_loan_apps_credit_line ON loan_applications(credit_line_account_id);
CREATE INDEX idx_loan_apps_limit_reservation ON loan_applications(credit_limit_reservation_id);
CREATE INDEX idx_duration_options_product ON loan_product_duration_options(product_id, is_active, sort_order);
CREATE UNIQUE INDEX idx_duration_options_default ON loan_product_duration_options(product_id) WHERE is_default = TRUE;
CREATE INDEX idx_bnpl_installment_options_product ON bnpl_installment_options(product_id, is_active, sort_order);
CREATE UNIQUE INDEX idx_bnpl_installment_options_default ON bnpl_installment_options(product_id) WHERE is_default = TRUE;
CREATE INDEX idx_loan_apps_duration_option ON loan_applications(duration_option_id);
CREATE INDEX idx_loan_apps_bnpl_option ON loan_applications(bnpl_installment_option_id);
CREATE INDEX idx_loans_duration_option ON loans(duration_option_id);
CREATE INDEX idx_loans_bnpl_option ON loans(bnpl_installment_option_id);
CREATE INDEX idx_loans_customer_deposit ON loans(customer_deposit_account_id);
CREATE INDEX idx_loans_credit_line ON loans(credit_line_account_id);
CREATE INDEX idx_loans_polaris_product_config ON loans(polaris_product_config_id);
CREATE INDEX idx_loans_polaris_loan_account ON loans(polaris_loan_account_id);
CREATE INDEX idx_loans_polaris_deposit_account ON loans(polaris_deposit_account_id);


-- ============================================================
-- 5. BNPL FLOW (EMART TERMINAL QR PAYMENT)
-- ============================================================

CREATE TYPE invoice_status_enum  AS ENUM ('pending','qr_generated','processing','approved','rejected','expired','refunded');
CREATE TYPE callback_type_enum   AS ENUM ('approved','rejected','timeout');
CREATE TYPE callback_status_enum AS ENUM ('pending','sent','acknowledged','failed');
CREATE TYPE pos_txn_status_enum AS ENUM (
    'processing',
    'pending_loan',
    'pending_grant',
    'pending_merchant_transfer',
    'pending_reconcile',
    'approved',
    'rejected',
    'failed'
);

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
    merchant_passive_account_id UUID,
    merchant_transfer_ledger_journal_id UUID,
    merchant_transfer_polaris_jrno BIGINT,
    merchant_transfer_status VARCHAR(30) NOT NULL DEFAULT 'not_started',
    status                  pos_txn_status_enum NOT NULL DEFAULT 'processing',
    approved_at             TIMESTAMPTZ,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Callbacks sent back to the terminal after approval/rejection
CREATE TABLE pos_terminal_callbacks (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    transaction_id  UUID NOT NULL REFERENCES pos_transactions(id),
    terminal_id     UUID NOT NULL REFERENCES pos_terminals(id),
    idempotency_key VARCHAR(100) NOT NULL,
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
CREATE INDEX idx_pos_txn_merchant_transfer_status ON pos_transactions(merchant_transfer_status);


-- ============================================================
-- 6. REPAYMENT SCHEDULES, QPAY INVOICES & TRANSACTIONS
-- ============================================================

CREATE TYPE sched_status_enum   AS ENUM ('pending','partial','paid','overdue','waived');
CREATE TYPE payment_chan_enum   AS ENUM ('qpay','bank_transfer','manual_adjustment');
CREATE TYPE qpay_invoice_status_enum AS ENUM ('pending','created','paid','expired','cancelled','failed');
CREATE TYPE qpay_callback_status_enum AS ENUM ('received','processed','failed','ignored');
CREATE TYPE repay_txn_status    AS ENUM ('pending','processing','pending_reconcile','completed','failed','reversed');
CREATE TYPE penalty_type_enum   AS ENUM ('late_payment','early_exit');
CREATE TYPE cashback_calc_base_enum AS ENUM ('paid_amount','principal_portion','interest_portion','total_due');
CREATE TYPE cashback_reward_type_enum AS ENUM ('fixed_amount','percentage');
CREATE TYPE cashback_record_status_enum AS ENUM ('pending','credited','failed','cancelled','reversed');
CREATE TYPE cashback_wallet_status_enum AS ENUM ('active','frozen','closed');
CREATE TYPE cashback_wallet_txn_type_enum AS ENUM (
    'cashback_credit',
    'repayment_offset',
    'redemption',
    'adjustment_credit',
    'adjustment_debit',
    'reversal',
    'expiry'
);
CREATE TYPE cashback_wallet_txn_status_enum AS ENUM ('pending','posted','failed','reversed','cancelled');

-- Automatic repayment cashback rules. product_id/product_type are optional so rules can be
-- product-specific, product-type-wide, or global; priority resolves overlapping active rules.
CREATE TABLE repayment_cashback_configs (
    id                          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    config_code                 VARCHAR(50) NOT NULL UNIQUE,
    name                        VARCHAR(100) NOT NULL,
    product_id                  UUID REFERENCES loan_products(id),
    product_type                product_type_enum,
    reward_type                 cashback_reward_type_enum NOT NULL,
    reward_value                NUMERIC(14,4) NOT NULL,
    calculation_base            cashback_calc_base_enum NOT NULL DEFAULT 'paid_amount',
    max_cashback_amount         NUMERIC(14,2),
    min_payment_amount          NUMERIC(14,2),
    grace_days                  INT NOT NULL DEFAULT 0,
    applies_to_installment_number INT,
    requires_full_installment_payment BOOLEAN NOT NULL DEFAULT TRUE,
    currency                    VARCHAR(10) NOT NULL DEFAULT 'MNT',
    effective_from              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    effective_until             TIMESTAMPTZ,
    is_active                   BOOLEAN NOT NULL DEFAULT TRUE,
    priority                    INT NOT NULL DEFAULT 0,
    metadata                    JSONB NOT NULL DEFAULT '{}',
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

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
    allocation_locked_at TIMESTAMPTZ,
    allocation_locked_by VARCHAR(100),
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
    customer_deposit_account_id UUID,
    amount              NUMERIC(14,2) NOT NULL,
    principal_portion   NUMERIC(14,2) NOT NULL DEFAULT 0,
    interest_portion    NUMERIC(14,2) NOT NULL DEFAULT 0,
    penalty_portion     NUMERIC(14,2) NOT NULL DEFAULT 0,
    qpay_repayment_invoice_id UUID REFERENCES qpay_repayment_invoices(id),
    ledger_journal_id  UUID,
    inbound_ledger_journal_id UUID,
    loan_payment_ledger_journal_id UUID,
    inbound_polaris_jrno BIGINT,
    loan_payment_polaris_jrno BIGINT,
    reconciliation_status VARCHAR(30) NOT NULL DEFAULT 'unreconciled',
    payment_channel     payment_chan_enum NOT NULL DEFAULT 'qpay',
    transaction_ref     VARCHAR(100) NOT NULL UNIQUE,
    status              repay_txn_status NOT NULL DEFAULT 'pending',
    reversal_of_repayment_transaction_id UUID REFERENCES repayment_transactions(id),
    processed_at        TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Exact allocation of one repayment transaction across one or many schedules.
CREATE TABLE repayment_allocations (
    id                       UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    repayment_transaction_id UUID NOT NULL REFERENCES repayment_transactions(id),
    schedule_id              UUID NOT NULL REFERENCES repayment_schedules(id),
    principal_amount         NUMERIC(14,2) NOT NULL DEFAULT 0,
    interest_amount          NUMERIC(14,2) NOT NULL DEFAULT 0,
    penalty_amount           NUMERIC(14,2) NOT NULL DEFAULT 0,
    total_amount             NUMERIC(14,2) GENERATED ALWAYS AS (principal_amount + interest_amount + penalty_amount) STORED,
    allocation_order         INT NOT NULL DEFAULT 1 CHECK (allocation_order > 0),
    created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (repayment_transaction_id, schedule_id)
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

-- Customer-facing reward wallet where on-time repayment cashback is collected.
-- Balance is app-owned; backing_polaris_account_id can point to the pooled/core account if needed.
CREATE TABLE customer_cashback_wallets (
    id                          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id                 UUID NOT NULL REFERENCES customer_profiles(id),
    currency                    VARCHAR(10) NOT NULL DEFAULT 'MNT',
    available_balance           NUMERIC(14,2) NOT NULL DEFAULT 0,
    pending_balance             NUMERIC(14,2) NOT NULL DEFAULT 0,
    lifetime_earned             NUMERIC(14,2) NOT NULL DEFAULT 0,
    lifetime_redeemed           NUMERIC(14,2) NOT NULL DEFAULT 0,
    backing_polaris_account_id  UUID,
    status                      cashback_wallet_status_enum NOT NULL DEFAULT 'active',
    opened_at                   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    closed_at                   TIMESTAMPTZ,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (customer_id, currency),
    UNIQUE (customer_id, id),
    UNIQUE (id, currency)
);

-- Ledger of reward wallet movements. Credits come from cashback records; debits can be
-- repayment offsets, redemptions, expiry, reversals, or staff adjustments.
CREATE TABLE customer_cashback_wallet_transactions (
    id                          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    wallet_id                   UUID NOT NULL REFERENCES customer_cashback_wallets(id),
    customer_id                 UUID NOT NULL REFERENCES customer_profiles(id),
    authorization_id            UUID REFERENCES customer_transaction_authorizations(id),
    transaction_type            cashback_wallet_txn_type_enum NOT NULL,
    status                      cashback_wallet_txn_status_enum NOT NULL DEFAULT 'pending',
    amount                      NUMERIC(14,2) NOT NULL,
    currency                    VARCHAR(10) NOT NULL DEFAULT 'MNT',
    balance_before              NUMERIC(14,2),
    balance_after               NUMERIC(14,2),
    source_table                VARCHAR(100),
    source_id                   UUID,
    ledger_journal_id           UUID,
    reversal_of_transaction_id  UUID REFERENCES customer_cashback_wallet_transactions(id),
    idempotency_key             VARCHAR(100),
    failure_reason              TEXT,
    expires_at                  TIMESTAMPTZ,
    posted_at                   TIMESTAMPTZ,
    failed_at                   TIMESTAMPTZ,
    reversed_at                 TIMESTAMPTZ,
    metadata                    JSONB NOT NULL DEFAULT '{}',
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (wallet_id, id),
    UNIQUE (wallet_id, id, currency)
);

-- One audit row per on-time installment cashback decision/credit. The automatic processor
-- creates records from completed repayment_transactions and the due_date/grace_days rule.
CREATE TABLE repayment_cashback_records (
    id                          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    config_id                   UUID NOT NULL REFERENCES repayment_cashback_configs(id),
    schedule_id                 UUID NOT NULL REFERENCES repayment_schedules(id),
    repayment_transaction_id    UUID NOT NULL REFERENCES repayment_transactions(id),
    loan_id                     UUID NOT NULL REFERENCES loans(id),
    customer_id                 UUID NOT NULL REFERENCES customer_profiles(id),
    cashback_wallet_id          UUID REFERENCES customer_cashback_wallets(id),
    wallet_transaction_id       UUID REFERENCES customer_cashback_wallet_transactions(id),
    reversal_wallet_transaction_id UUID REFERENCES customer_cashback_wallet_transactions(id),
    destination_polaris_account_id UUID,
    ledger_journal_id           UUID,
    reversal_ledger_journal_id  UUID,
    idempotency_key             VARCHAR(100),
    reward_type                 cashback_reward_type_enum NOT NULL,
    reward_value                NUMERIC(14,4) NOT NULL,
    calculation_base            cashback_calc_base_enum NOT NULL,
    calculation_base_amount     NUMERIC(14,2) NOT NULL,
    cashback_amount             NUMERIC(14,2) NOT NULL,
    currency                    VARCHAR(10) NOT NULL DEFAULT 'MNT',
    due_date                    DATE NOT NULL,
    paid_at                     TIMESTAMPTZ NOT NULL,
    grace_days_applied          INT NOT NULL DEFAULT 0,
    status                      cashback_record_status_enum NOT NULL DEFAULT 'pending',
    failure_reason              TEXT,
    metadata                    JSONB NOT NULL DEFAULT '{}',
    credited_at                 TIMESTAMPTZ,
    reversed_at                 TIMESTAMPTZ,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (schedule_id, config_id)
);

ALTER TABLE customer_cashback_wallet_transactions
    ADD CONSTRAINT fk_cashback_wallet_txn_customer_wallet
    FOREIGN KEY (customer_id, wallet_id) REFERENCES customer_cashback_wallets(customer_id, id);

ALTER TABLE customer_cashback_wallet_transactions
    ADD CONSTRAINT fk_cashback_wallet_txn_wallet_currency
    FOREIGN KEY (wallet_id, currency) REFERENCES customer_cashback_wallets(id, currency);

ALTER TABLE customer_cashback_wallet_transactions
    ADD CONSTRAINT fk_cashback_wallet_txn_customer_authorization
    FOREIGN KEY (customer_id, authorization_id)
    REFERENCES customer_transaction_authorizations(customer_id, id);

ALTER TABLE repayment_cashback_records
    ADD CONSTRAINT fk_cashback_record_customer_wallet
    FOREIGN KEY (customer_id, cashback_wallet_id) REFERENCES customer_cashback_wallets(customer_id, id);

ALTER TABLE repayment_cashback_records
    ADD CONSTRAINT fk_cashback_record_wallet_currency
    FOREIGN KEY (cashback_wallet_id, currency) REFERENCES customer_cashback_wallets(id, currency);

ALTER TABLE repayment_cashback_records
    ADD CONSTRAINT fk_cashback_record_wallet_txn
    FOREIGN KEY (cashback_wallet_id, wallet_transaction_id)
    REFERENCES customer_cashback_wallet_transactions(wallet_id, id);

ALTER TABLE repayment_cashback_records
    ADD CONSTRAINT fk_cashback_record_wallet_txn_currency
    FOREIGN KEY (cashback_wallet_id, wallet_transaction_id, currency)
    REFERENCES customer_cashback_wallet_transactions(wallet_id, id, currency);

ALTER TABLE repayment_cashback_records
    ADD CONSTRAINT fk_cashback_record_reversal_wallet_txn
    FOREIGN KEY (cashback_wallet_id, reversal_wallet_transaction_id)
    REFERENCES customer_cashback_wallet_transactions(wallet_id, id);

ALTER TABLE repayment_cashback_records
    ADD CONSTRAINT fk_cashback_record_reversal_wallet_txn_currency
    FOREIGN KEY (cashback_wallet_id, reversal_wallet_transaction_id, currency)
    REFERENCES customer_cashback_wallet_transactions(wallet_id, id, currency);

CREATE INDEX idx_sched_loan         ON repayment_schedules(loan_id);
CREATE INDEX idx_sched_due_date     ON repayment_schedules(due_date);
CREATE INDEX idx_qpay_invoice_loan  ON qpay_repayment_invoices(loan_id);
CREATE INDEX idx_qpay_invoice_sched ON qpay_repayment_invoices(schedule_id);
CREATE INDEX idx_qpay_cb_invoice    ON qpay_repayment_callbacks(qpay_repayment_invoice_id);
CREATE INDEX idx_repay_txn_loan     ON repayment_transactions(loan_id);
CREATE INDEX idx_repay_txn_qpay_inv ON repayment_transactions(qpay_repayment_invoice_id);
CREATE INDEX idx_repay_txn_customer_deposit ON repayment_transactions(customer_deposit_account_id);
CREATE INDEX idx_repay_alloc_txn    ON repayment_allocations(repayment_transaction_id);
CREATE INDEX idx_repay_alloc_sched  ON repayment_allocations(schedule_id);
CREATE INDEX idx_cashback_configs_active
    ON repayment_cashback_configs(is_active, effective_from, effective_until);
CREATE INDEX idx_cashback_configs_product
    ON repayment_cashback_configs(product_id, is_active, priority);
CREATE INDEX idx_cashback_configs_product_type
    ON repayment_cashback_configs(product_type, is_active, priority);
CREATE INDEX idx_cashback_wallets_customer
    ON customer_cashback_wallets(customer_id, status);
CREATE INDEX idx_cashback_wallet_transactions_wallet
    ON customer_cashback_wallet_transactions(wallet_id, created_at DESC);
CREATE INDEX idx_cashback_wallet_transactions_customer
    ON customer_cashback_wallet_transactions(customer_id, status, created_at DESC);
CREATE INDEX idx_cashback_wallet_transactions_source
    ON customer_cashback_wallet_transactions(source_table, source_id);
CREATE INDEX idx_cashback_wallet_transactions_authorization
    ON customer_cashback_wallet_transactions(authorization_id);
CREATE INDEX idx_cashback_wallet_transactions_status
    ON customer_cashback_wallet_transactions(status, created_at);
CREATE INDEX idx_cashback_records_customer
    ON repayment_cashback_records(customer_id, status, created_at DESC);
CREATE INDEX idx_cashback_records_wallet
    ON repayment_cashback_records(cashback_wallet_id, status);
CREATE INDEX idx_cashback_records_schedule
    ON repayment_cashback_records(schedule_id);
CREATE INDEX idx_cashback_records_transaction
    ON repayment_cashback_records(repayment_transaction_id);
CREATE INDEX idx_cashback_records_status
    ON repayment_cashback_records(status, created_at);


-- ============================================================
-- 7. POLARIS CORE BANKING INTEGRATION
-- ============================================================

CREATE TYPE polaris_acc_type  AS ENUM (
    'customer_deposit',
    'line_loan',
    'loan',
    'internal_funding',
    'repayment_pool',
    'merchant_passive',
    'merchant_settlement',
    'internal',
    'merchant_debt'
);
CREATE TYPE polaris_product_config_kind AS ENUM (
    'customer_deposit',
    'line_loan',
    'child_loan',
    'merchant_passive',
    'internal_account'
);
CREATE TYPE polaris_txn_config_kind AS ENUM (
    'loan_grant',
    'bnpl_merchant_transfer',
    'repayment_inbound',
    'loan_repayment',
    'loan_close',
    'reversal',
    'merchant_settlement'
);
CREATE TYPE customer_deposit_account_status_enum AS ENUM (
    'pending_create',
    'created',
    'pending_open',
    'active',
    'frozen',
    'closed',
    'failed',
    'pending_reconcile'
);
CREATE TYPE credit_line_status_enum AS ENUM (
    'pending_create',
    'created',
    'pending_open',
    'active',
    'suspended',
    'closed',
    'failed',
    'pending_reconcile'
);
CREATE TYPE credit_reservation_status_enum AS ENUM (
    'reserved',
    'consumed',
    'released',
    'expired',
    'failed'
);
CREATE TYPE loan_core_step_enum AS ENUM (
    'create_customer_deposit',
    'open_customer_deposit',
    'sync_customer_kyc',
    'sync_credit_score',
    'create_line_account',
    'open_line_account',
    'adjust_line_limit',
    'create_loan_account',
    'open_loan_account',
    'calculate_schedule',
    'create_schedule',
    'link_line_account_to_loan',
    'grant_loan',
    'bnpl_merchant_transfer',
    'repayment_inbound',
    'loan_repayment',
    'close_loan',
    'reverse_transaction'
);
CREATE TYPE loan_core_step_status_enum AS ENUM (
    'pending',
    'processing',
    'succeeded',
    'failed',
    'pending_reconcile',
    'skipped',
    'cancelled'
);
CREATE TYPE ledger_journal_status_enum AS ENUM ('draft','pending','pending_reconcile','posted','failed','reversed');
CREATE TYPE ledger_entry_side_enum AS ENUM ('debit','credit');
CREATE TYPE reconciliation_status_enum AS ENUM ('unreconciled','matched','mismatched','reconciled','failed');
CREATE TYPE queue_op_enum     AS ENUM (
    'create_account',
    'post_txn',
    'update_balance',
    'close_account',
    'create_cif_person',
    'update_cif_person',
    'create_customer_deposit_account',
    'open_customer_deposit_account',
    'sync_kyc_to_polaris',
    'sync_credit_score_to_polaris',
    'create_line_account',
    'open_line_account',
    'adjust_line_limit',
    'create_loan_account',
    'open_loan_account',
    'calculate_repayment_schedule',
    'create_repayment_schedule',
    'link_line_account_to_loan',
    'grant_loan_non_cash',
    'bnpl_merchant_transfer',
    'repayment_inbound_transfer',
    'loan_payment_non_cash',
    'close_loan_account',
    'reverse_transaction',
    'reconcile_account',
    'reconcile_journal'
);
CREATE TYPE queue_status_enum AS ENUM (
    'pending',
    'processing',
    'completed',
    'pending_reconcile',
    'reconciled',
    'failed',
    'cancelled',
    'dead_letter'
);

-- Polaris product/account configuration. Services load productCode/branch/category
-- and dynamicData templates from here instead of hardcoding core-banking values.
CREATE TABLE polaris_product_configs (
    id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    config_key            VARCHAR(100) NOT NULL UNIQUE,
    config_kind           polaris_product_config_kind NOT NULL,
    loan_product_id       UUID REFERENCES loan_products(id),
    prod_code             VARCHAR(50) NOT NULL,
    brch_code             VARCHAR(50) NOT NULL,
    cur_code              VARCHAR(10) NOT NULL DEFAULT 'MNT',
    cat_code              VARCHAR(50),
    cat_sub_code          VARCHAR(50),
    purpose               VARCHAR(100),
    sub_purpose           VARCHAR(100),
    seg_code              VARCHAR(50),
    chart_code            VARCHAR(100),
    term_basis            VARCHAR(30),
    term_len              INT,
    repay_order           INT,
    repay_priority        INT,
    int_type_code         VARCHAR(50),
    dynamic_data_template JSONB NOT NULL DEFAULT '[]',
    metadata              JSONB NOT NULL DEFAULT '{}',
    is_active             BOOLEAN NOT NULL DEFAULT TRUE,
    valid_from            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    valid_until           TIMESTAMPTZ,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (valid_until IS NULL OR valid_until > valid_from)
);

CREATE TABLE polaris_transaction_configs (
    id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    config_key            VARCHAR(100) NOT NULL UNIQUE,
    txn_kind              polaris_txn_config_kind NOT NULL,
    endpoint              VARCHAR(255) NOT NULL,
    txn_def_code          VARCHAR(50),
    txn_type              VARCHAR(50),
    source_account_type   polaris_acc_type,
    contra_account_type   polaris_acc_type,
    source_type           VARCHAR(50),
    description_template  TEXT,
    payload_template      JSONB NOT NULL DEFAULT '{}',
    is_money_movement     BOOLEAN NOT NULL DEFAULT TRUE,
    is_active             BOOLEAN NOT NULL DEFAULT TRUE,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE polaris_dynamic_field_mappings (
    id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    field_scope           VARCHAR(50) NOT NULL, -- cif_person|credit_score|customer_deposit|line_loan|child_loan
    product_config_id     UUID REFERENCES polaris_product_configs(id),
    app_field_name        VARCHAR(100) NOT NULL,
    polaris_obj_type      VARCHAR(50),
    polaris_field_id      INT NOT NULL,
    polaris_field_type    INT,
    polaris_field_name    VARCHAR(100),
    is_mandatory          BOOLEAN NOT NULL DEFAULT FALSE,
    transform_expression  TEXT,
    is_active             BOOLEAN NOT NULL DEFAULT TRUE,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (field_scope, app_field_name, polaris_field_id)
);

-- Master registry of all Polaris/OI account numbers used by the system.
-- Polaris/OI acntCode, txnAcntCode and contAcntCode values are stored here.
CREATE TABLE polaris_accounts (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    polaris_acnt_code_encrypted BYTEA NOT NULL,
    polaris_acnt_code_hash BYTEA NOT NULL UNIQUE,
    account_type        polaris_acc_type NOT NULL,
    owner_type          VARCHAR(20) NOT NULL,  -- customer|merchant|system
    owner_id            UUID,                  -- references the relevant profile id
    product_config_id   UUID REFERENCES polaris_product_configs(id),
    polaris_prod_code   VARCHAR(50),           -- Polaris/OI prodCode
    polaris_brch_code   VARCHAR(50),           -- Polaris/OI brchCode
    polaris_sys_no      INT,                   -- Polaris/OI sysNo
    currency            VARCHAR(10) NOT NULL DEFAULT 'MNT',
    current_balance     NUMERIC(18,2) NOT NULL DEFAULT 0,
    status              VARCHAR(20) NOT NULL DEFAULT 'active',  -- active|frozen|closed
    polaris_synced_at   TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE customer_deposit_accounts (
    id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id           UUID NOT NULL REFERENCES customer_profiles(id),
    polaris_account_id    UUID UNIQUE REFERENCES polaris_accounts(id),
    product_config_id     UUID NOT NULL REFERENCES polaris_product_configs(id),
    purpose               VARCHAR(50) NOT NULL DEFAULT 'loan_grant_repayment',
    is_primary            BOOLEAN NOT NULL DEFAULT FALSE,
    status                customer_deposit_account_status_enum NOT NULL DEFAULT 'pending_create',
    opened_at             TIMESTAMPTZ,
    failed_at             TIMESTAMPTZ,
    failure_reason        TEXT,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (customer_id, id)
);

CREATE TABLE credit_line_accounts (
    id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id           UUID NOT NULL REFERENCES customer_profiles(id),
    loan_limit_id         UUID NOT NULL REFERENCES loan_limits(id),
    credit_score_id       UUID NOT NULL REFERENCES credit_score_results(id),
    customer_deposit_account_id UUID NOT NULL REFERENCES customer_deposit_accounts(id),
    polaris_account_id    UUID UNIQUE REFERENCES polaris_accounts(id),
    product_config_id     UUID NOT NULL REFERENCES polaris_product_configs(id),
    line_amount           NUMERIC(14,2) NOT NULL,
    utilized_amount       NUMERIC(14,2) NOT NULL DEFAULT 0,
    reserved_amount       NUMERIC(14,2) NOT NULL DEFAULT 0,
    available_amount      NUMERIC(14,2) GENERATED ALWAYS AS (line_amount - utilized_amount - reserved_amount) STORED,
    currency              VARCHAR(10) NOT NULL DEFAULT 'MNT',
    status                credit_line_status_enum NOT NULL DEFAULT 'pending_create',
    valid_until           TIMESTAMPTZ,
    polaris_created_at    TIMESTAMPTZ,
    opened_at             TIMESTAMPTZ,
    failed_at             TIMESTAMPTZ,
    failure_reason        TEXT,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (customer_id, loan_limit_id)
);

CREATE TABLE credit_limit_reservations (
    id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id           UUID NOT NULL REFERENCES customer_profiles(id),
    credit_line_account_id UUID NOT NULL REFERENCES credit_line_accounts(id),
    loan_application_id   UUID NOT NULL UNIQUE REFERENCES loan_applications(id),
    loan_id               UUID UNIQUE REFERENCES loans(id),
    idempotency_key       VARCHAR(100) UNIQUE,
    reserved_amount       NUMERIC(14,2) NOT NULL,
    currency              VARCHAR(10) NOT NULL DEFAULT 'MNT',
    status                credit_reservation_status_enum NOT NULL DEFAULT 'reserved',
    expires_at            TIMESTAMPTZ,
    consumed_at           TIMESTAMPTZ,
    released_at           TIMESTAMPTZ,
    failed_at             TIMESTAMPTZ,
    failure_reason        TEXT,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (credit_line_account_id, loan_application_id)
);

ALTER TABLE customer_profiles
    ADD CONSTRAINT fk_customer_profiles_primary_deposit_account
    FOREIGN KEY (primary_deposit_account_id) REFERENCES customer_deposit_accounts(id);

ALTER TABLE merchant_profiles
    ADD CONSTRAINT fk_merchant_profiles_passive_account
    FOREIGN KEY (polaris_merchant_passive_account_id) REFERENCES polaris_accounts(id);

ALTER TABLE merchant_profiles
    ADD CONSTRAINT fk_merchant_profiles_settlement_account
    FOREIGN KEY (polaris_settlement_account_id) REFERENCES polaris_accounts(id);

ALTER TABLE loan_limits
    ADD CONSTRAINT fk_loan_limits_active_credit_line
    FOREIGN KEY (active_credit_line_account_id) REFERENCES credit_line_accounts(id);

ALTER TABLE loan_products
    ADD CONSTRAINT fk_loan_products_polaris_product_config
    FOREIGN KEY (polaris_product_config_id) REFERENCES polaris_product_configs(id);

ALTER TABLE loans
    ADD CONSTRAINT fk_loans_polaris_product_config
    FOREIGN KEY (polaris_product_config_id) REFERENCES polaris_product_configs(id);

ALTER TABLE loans
    ADD CONSTRAINT fk_loans_polaris_loan_account
    FOREIGN KEY (polaris_loan_account_id) REFERENCES polaris_accounts(id);

ALTER TABLE loans
    ADD CONSTRAINT fk_loans_polaris_deposit_account
    FOREIGN KEY (polaris_deposit_account_id) REFERENCES polaris_accounts(id);

ALTER TABLE loan_applications
    ADD CONSTRAINT fk_loan_apps_requested_customer_deposit
    FOREIGN KEY (requested_customer_deposit_account_id) REFERENCES customer_deposit_accounts(id);

ALTER TABLE loan_applications
    ADD CONSTRAINT fk_loan_apps_credit_line
    FOREIGN KEY (credit_line_account_id) REFERENCES credit_line_accounts(id);

ALTER TABLE loan_applications
    ADD CONSTRAINT fk_loan_apps_limit_reservation
    FOREIGN KEY (credit_limit_reservation_id) REFERENCES credit_limit_reservations(id);

ALTER TABLE loans
    ADD CONSTRAINT fk_loans_customer_deposit
    FOREIGN KEY (customer_deposit_account_id) REFERENCES customer_deposit_accounts(id);

ALTER TABLE loans
    ADD CONSTRAINT fk_loans_credit_line
    FOREIGN KEY (credit_line_account_id) REFERENCES credit_line_accounts(id);

ALTER TABLE loans
    ADD CONSTRAINT fk_loans_limit_reservation
    FOREIGN KEY (credit_limit_reservation_id) REFERENCES credit_limit_reservations(id);

-- Double-entry journal header for all money movement posted or reconciled with Polaris
CREATE TABLE ledger_journals (
    id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    journal_ref           VARCHAR(100) NOT NULL UNIQUE,
    idempotency_key       VARCHAR(100) NOT NULL UNIQUE,
    source_module         VARCHAR(50) NOT NULL,   -- loans|repayment|pos|refund|settlement|etc.
    source_table          VARCHAR(100) NOT NULL,
    source_id             UUID NOT NULL,
    source_operation      VARCHAR(50) NOT NULL,
    transaction_config_id UUID REFERENCES polaris_transaction_configs(id),
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

ALTER TABLE loans
    ADD CONSTRAINT fk_loans_grant_ledger_journal
    FOREIGN KEY (grant_ledger_journal_id) REFERENCES ledger_journals(id);

ALTER TABLE loans
    ADD CONSTRAINT fk_loans_bnpl_merchant_transfer_journal
    FOREIGN KEY (bnpl_merchant_transfer_journal_id) REFERENCES ledger_journals(id);

ALTER TABLE pos_transactions
    ADD CONSTRAINT fk_pos_txn_merchant_passive_account
    FOREIGN KEY (merchant_passive_account_id) REFERENCES polaris_accounts(id);

ALTER TABLE pos_transactions
    ADD CONSTRAINT fk_pos_txn_merchant_transfer_journal
    FOREIGN KEY (merchant_transfer_ledger_journal_id) REFERENCES ledger_journals(id);

ALTER TABLE repayment_transactions
    ADD CONSTRAINT fk_repay_txn_customer_deposit
    FOREIGN KEY (customer_deposit_account_id) REFERENCES customer_deposit_accounts(id);

ALTER TABLE repayment_transactions
    ADD CONSTRAINT fk_repay_txn_inbound_ledger_journal
    FOREIGN KEY (inbound_ledger_journal_id) REFERENCES ledger_journals(id);

ALTER TABLE repayment_transactions
    ADD CONSTRAINT fk_repay_txn_loan_payment_ledger_journal
    FOREIGN KEY (loan_payment_ledger_journal_id) REFERENCES ledger_journals(id);

ALTER TABLE customer_cashback_wallets
    ADD CONSTRAINT fk_cashback_wallet_backing_polaris_account
    FOREIGN KEY (backing_polaris_account_id) REFERENCES polaris_accounts(id);

ALTER TABLE customer_cashback_wallet_transactions
    ADD CONSTRAINT fk_cashback_wallet_txn_ledger_journal
    FOREIGN KEY (ledger_journal_id) REFERENCES ledger_journals(id);

ALTER TABLE repayment_cashback_records
    ADD CONSTRAINT fk_cashback_destination_polaris_account
    FOREIGN KEY (destination_polaris_account_id) REFERENCES polaris_accounts(id);

ALTER TABLE repayment_cashback_records
    ADD CONSTRAINT fk_cashback_ledger_journal
    FOREIGN KEY (ledger_journal_id) REFERENCES ledger_journals(id);

ALTER TABLE repayment_cashback_records
    ADD CONSTRAINT fk_cashback_reversal_ledger_journal
    FOREIGN KEY (reversal_ledger_journal_id) REFERENCES ledger_journals(id);

-- Full log of every Polaris API call (request + response).
-- Persist sanitized payloads only; redact account/register values before insert.
CREATE TABLE polaris_api_logs (
    id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    sync_queue_id    UUID,
    operation_attempt_id UUID,
    endpoint         VARCHAR(255) NOT NULL,
    http_method      VARCHAR(10) NOT NULL,
    idempotency_key  VARCHAR(100),
    request_payload  JSONB,
    response_payload JSONB,
    request_payload_hash BYTEA,
    response_payload_hash BYTEA,
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
    endpoint        VARCHAR(255),
    product_config_id UUID REFERENCES polaris_product_configs(id),
    transaction_config_id UUID REFERENCES polaris_transaction_configs(id),
    idempotency_key VARCHAR(100) NOT NULL,
    correlation_id  VARCHAR(100),
    reconciliation_key VARCHAR(150),
    payload         JSONB NOT NULL,
    retry_count     INT NOT NULL DEFAULT 0,
    status          queue_status_enum NOT NULL DEFAULT 'pending',
    error_message   TEXT,
    locked_at       TIMESTAMPTZ,
    locked_by       VARCHAR(100),
    last_attempt_at TIMESTAMPTZ,
    next_retry_at   TIMESTAMPTZ,
    reconciled_at   TIMESTAMPTZ,
    dead_letter_at  TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed_at    TIMESTAMPTZ
);

CREATE TABLE polaris_operation_attempts (
    id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    sync_queue_id        UUID NOT NULL REFERENCES polaris_sync_queue(id),
    endpoint             VARCHAR(255) NOT NULL,
    http_method          VARCHAR(10) NOT NULL DEFAULT 'POST',
    idempotency_key      VARCHAR(100) NOT NULL,
    request_payload_hash BYTEA,
    request_payload      JSONB,
    response_payload     JSONB,
    http_status_code     INT,
    duration_ms          INT,
    polaris_jrno         BIGINT,
    polaris_txn_ref      VARCHAR(100),
    correlation_id       VARCHAR(100),
    status               queue_status_enum NOT NULL DEFAULT 'processing',
    error_message        TEXT,
    started_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at         TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE polaris_api_logs
    ADD CONSTRAINT fk_polaris_api_logs_sync_queue
    FOREIGN KEY (sync_queue_id) REFERENCES polaris_sync_queue(id);

ALTER TABLE polaris_api_logs
    ADD CONSTRAINT fk_polaris_api_logs_operation_attempt
    FOREIGN KEY (operation_attempt_id) REFERENCES polaris_operation_attempts(id);

CREATE TABLE loan_core_steps (
    id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    loan_id              UUID REFERENCES loans(id),
    loan_application_id  UUID REFERENCES loan_applications(id),
    customer_id          UUID NOT NULL REFERENCES customer_profiles(id),
    step                 loan_core_step_enum NOT NULL,
    status               loan_core_step_status_enum NOT NULL DEFAULT 'pending',
    operation_order      INT NOT NULL DEFAULT 1 CHECK (operation_order > 0),
    polaris_sync_queue_id UUID REFERENCES polaris_sync_queue(id),
    endpoint             VARCHAR(255),
    idempotency_key      VARCHAR(100) UNIQUE,
    polaris_jrno         BIGINT,
    polaris_txn_ref      VARCHAR(100),
    request_payload      JSONB,
    response_payload     JSONB,
    failure_reason       TEXT,
    started_at           TIMESTAMPTZ,
    completed_at         TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (loan_id IS NOT NULL OR loan_application_id IS NOT NULL)
);

CREATE INDEX idx_polaris_product_configs_kind ON polaris_product_configs(config_kind, is_active);
CREATE INDEX idx_polaris_product_configs_loan_product ON polaris_product_configs(loan_product_id, config_kind, is_active);
CREATE INDEX idx_polaris_txn_configs_kind ON polaris_transaction_configs(txn_kind, is_active);
CREATE INDEX idx_polaris_dynamic_mappings_scope ON polaris_dynamic_field_mappings(field_scope, is_active);
CREATE INDEX idx_loan_products_polaris_config ON loan_products(polaris_product_config_id)
    WHERE polaris_product_config_id IS NOT NULL;
CREATE UNIQUE INDEX idx_customer_deposit_accounts_primary
    ON customer_deposit_accounts(customer_id)
    WHERE is_primary = TRUE AND status NOT IN ('closed','failed');
CREATE INDEX idx_customer_deposit_accounts_customer ON customer_deposit_accounts(customer_id, status);
CREATE UNIQUE INDEX idx_credit_line_accounts_active
    ON credit_line_accounts(customer_id)
    WHERE status = 'active';
CREATE INDEX idx_credit_line_accounts_limit ON credit_line_accounts(loan_limit_id, status);
CREATE INDEX idx_credit_line_accounts_customer ON credit_line_accounts(customer_id, status);
CREATE INDEX idx_credit_reservations_customer ON credit_limit_reservations(customer_id, status);
CREATE INDEX idx_credit_reservations_line_status ON credit_limit_reservations(credit_line_account_id, status);
CREATE INDEX idx_ledger_journals_source ON ledger_journals(source_table, source_id, source_operation);
CREATE INDEX idx_ledger_journals_txn_config ON ledger_journals(transaction_config_id);
CREATE INDEX idx_ledger_journals_status ON ledger_journals(status, value_date);
CREATE INDEX idx_ledger_entries_journal ON ledger_entries(journal_id);
CREATE INDEX idx_ledger_entries_account ON ledger_entries(polaris_account_id);
CREATE INDEX idx_sync_queue_stat  ON polaris_sync_queue(status);
CREATE INDEX idx_sync_queue_reconcile ON polaris_sync_queue(reconciliation_key, status);
CREATE INDEX idx_sync_queue_product_config ON polaris_sync_queue(product_config_id)
    WHERE product_config_id IS NOT NULL;
CREATE INDEX idx_sync_queue_txn_config ON polaris_sync_queue(transaction_config_id)
    WHERE transaction_config_id IS NOT NULL;
CREATE INDEX idx_api_logs_corr    ON polaris_api_logs(correlation_id);
CREATE INDEX idx_api_logs_queue_attempt ON polaris_api_logs(sync_queue_id, operation_attempt_id);
CREATE INDEX idx_api_logs_idempotency ON polaris_api_logs(idempotency_key)
    WHERE idempotency_key IS NOT NULL;
CREATE INDEX idx_operation_attempts_queue ON polaris_operation_attempts(sync_queue_id, started_at DESC);
CREATE INDEX idx_operation_attempts_jrno ON polaris_operation_attempts(polaris_jrno) WHERE polaris_jrno IS NOT NULL;
CREATE INDEX idx_operation_attempts_idempotency
    ON polaris_operation_attempts(idempotency_key)
    WHERE idempotency_key IS NOT NULL;
CREATE INDEX idx_loan_core_steps_loan ON loan_core_steps(loan_id, operation_order);
CREATE INDEX idx_loan_core_steps_app ON loan_core_steps(loan_application_id, operation_order);
CREATE UNIQUE INDEX idx_loan_core_steps_loan_step_active
    ON loan_core_steps(loan_id, step)
    WHERE loan_id IS NOT NULL
      AND status IN ('pending', 'processing', 'succeeded', 'pending_reconcile');
CREATE UNIQUE INDEX idx_loan_core_steps_app_step_active
    ON loan_core_steps(loan_application_id, step)
    WHERE loan_application_id IS NOT NULL
      AND status IN ('pending', 'processing', 'succeeded', 'pending_reconcile');
CREATE UNIQUE INDEX idx_loan_core_steps_loan_order_active
    ON loan_core_steps(loan_id, operation_order)
    WHERE loan_id IS NOT NULL
      AND status IN ('pending', 'processing', 'succeeded', 'pending_reconcile', 'skipped');
CREATE UNIQUE INDEX idx_loan_core_steps_app_order_active
    ON loan_core_steps(loan_application_id, operation_order)
    WHERE loan_application_id IS NOT NULL
      AND status IN ('pending', 'processing', 'succeeded', 'pending_reconcile', 'skipped');


-- ============================================================
-- 8. MERCHANT PORTAL
-- ============================================================

CREATE TYPE portal_role_enum    AS ENUM ('admin','cashier','viewer');
CREATE TYPE refund_type_enum    AS ENUM ('full','partial');
CREATE TYPE refund_status_enum  AS ENUM ('pending','under_review','approved','rejected','processed');
CREATE TYPE settle_status_enum  AS ENUM ('pending','processing','pending_reconcile','completed','failed','reversed');

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
    merchant_passive_account_id UUID REFERENCES polaris_accounts(id),
    merchant_settlement_account_id UUID REFERENCES polaris_accounts(id),
    polaris_jrno       BIGINT,
    idempotency_key    VARCHAR(100),
    total_bnpl_amount  NUMERIC(14,2) NOT NULL DEFAULT 0,
    total_refunds      NUMERIC(14,2) NOT NULL DEFAULT 0,
    net_settlement     NUMERIC(14,2) GENERATED ALWAYS AS (total_bnpl_amount - total_refunds) STORED,
    transaction_count  INT NOT NULL DEFAULT 0,
    status             settle_status_enum NOT NULL DEFAULT 'pending',
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    settled_at         TIMESTAMPTZ
);

CREATE TABLE merchant_settlement_items (
    id                 UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    settlement_id      UUID NOT NULL REFERENCES merchant_settlements(id),
    pos_transaction_id UUID NOT NULL REFERENCES pos_transactions(id),
    gross_amount       NUMERIC(14,2) NOT NULL,
    refund_amount      NUMERIC(14,2) NOT NULL DEFAULT 0,
    net_amount         NUMERIC(14,2) GENERATED ALWAYS AS (gross_amount - refund_amount) STORED,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (settlement_id, pos_transaction_id)
);

CREATE INDEX idx_portal_users_merchant  ON merchant_portal_users(merchant_id);
CREATE INDEX idx_refunds_merchant       ON merchant_refund_requests(merchant_id);
CREATE INDEX idx_refunds_pos_transaction ON merchant_refund_requests(pos_transaction_id);
CREATE INDEX idx_refunds_status         ON merchant_refund_requests(status);
CREATE INDEX idx_settlements_merchant   ON merchant_settlements(merchant_id, settlement_date);
CREATE INDEX idx_settlement_items_settlement ON merchant_settlement_items(settlement_id);
CREATE INDEX idx_settlement_items_pos_txn ON merchant_settlement_items(pos_transaction_id);
CREATE UNIQUE INDEX idx_settlement_items_pos_txn_unique ON merchant_settlement_items(pos_transaction_id);

-- ============================================================
-- 9. AUDIT TRAIL, NOTIFICATIONS & SYSTEM LOGS
-- ============================================================

CREATE TYPE severity_enum    AS ENUM ('debug','info','warn','error','critical');
CREATE TYPE notif_chan_enum  AS ENUM ('sms','push','email','in_app');
CREATE TYPE notif_status     AS ENUM ('queued','sent','delivered','read','failed');
CREATE TYPE review_type_enum AS ENUM ('routine','escalated','compliance');
CREATE TYPE audit_actor_type_enum AS ENUM ('customer','merchant','staff','system','service','external');
CREATE TYPE audit_event_category_enum AS ENUM (
    'auth',
    'kyc',
    'scoring',
    'limit',
    'loan',
    'repayment',
    'bnpl',
    'merchant',
    'polaris',
    'finance',
    'admin',
    'security',
    'data_change',
    'system'
);
CREATE TYPE audit_operation_type_enum AS ENUM (
    'create',
    'update',
    'delete',
    'status_change',
    'submit',
    'approve',
    'reject',
    'cancel',
    'authorize',
    'sync',
    'post_transaction',
    'reverse',
    'reconcile',
    'login',
    'logout',
    'read_sensitive',
    'export'
);
CREATE TYPE audit_outcome_enum AS ENUM ('success','failure','rejected','pending','pending_reconcile');
CREATE TYPE service_pause_scope_enum AS ENUM (
    'all',
    'repayment',
    'cashback',
    'bnpl',
    'loan_disbursement',
    'polaris_sync',
    'merchant_settlement'
);
CREATE TYPE service_pause_status_enum AS ENUM ('scheduled','active','completed','cancelled');

-- Immutable audit log for business, security and financial state changes.
-- Do not write routine debug logs or every SELECT here; use system_event_logs for runtime
-- events, polaris_api_logs/operation_attempts for external calls, and ledger_journals
-- for accounting facts. Log sensitive reads only when compliance requires it.
CREATE TABLE audit_logs (
    id                         UUID NOT NULL DEFAULT uuid_generate_v4(),
    event_category             audit_event_category_enum NOT NULL,
    operation_type             audit_operation_type_enum NOT NULL,
    outcome                    audit_outcome_enum NOT NULL DEFAULT 'success',
    action                     VARCHAR(100) NOT NULL,   -- e.g. LOAN_APPROVED, KYC_VERIFIED
    actor_type                 audit_actor_type_enum NOT NULL DEFAULT 'system',
    user_id                    UUID REFERENCES users(id),
    staff_id                   UUID REFERENCES staff_profiles(id),
    customer_id                UUID REFERENCES customer_profiles(id),
    merchant_id                UUID REFERENCES merchant_profiles(id),
    subject_customer_id        UUID REFERENCES customer_profiles(id),
    subject_merchant_id        UUID REFERENCES merchant_profiles(id),
    entity_type                VARCHAR(100) NOT NULL,
    entity_id                  UUID NOT NULL,
    source_table               VARCHAR(100),
    source_id                  UUID,
    related_entity_type        VARCHAR(100),
    related_entity_id          UUID,
    from_status                VARCHAR(50),
    to_status                  VARCHAR(50),
    old_value                  JSONB,
    new_value                  JSONB,
    diff_value                 JSONB,
    reason                     TEXT,
    metadata                   JSONB NOT NULL DEFAULT '{}',
    ip_address                 INET,
    user_agent                 TEXT,
    session_id                 UUID,
    request_id                 VARCHAR(100),
    correlation_id             VARCHAR(100),
    trace_id                   VARCHAR(100),
    idempotency_key            VARCHAR(100),
    source_module              VARCHAR(50),
    ledger_journal_id          UUID REFERENCES ledger_journals(id),
    polaris_sync_queue_id      UUID REFERENCES polaris_sync_queue(id),
    polaris_operation_attempt_id UUID REFERENCES polaris_operation_attempts(id),
    polaris_jrno               BIGINT,
    request_payload_hash       BYTEA,
    previous_hash              BYTEA,
    record_hash                BYTEA,
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (id, created_at),
    CHECK (operation_type <> 'status_change' OR to_status IS NOT NULL),
    CHECK (request_payload_hash IS NULL OR octet_length(request_payload_hash) = 32),
    CHECK (previous_hash IS NULL OR octet_length(previous_hash) = 32),
    CHECK (record_hash IS NULL OR octet_length(record_hash) = 32)
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
    audit_log_id        UUID NOT NULL,
    audit_log_created_at TIMESTAMPTZ NOT NULL,
    reviewer_staff_id   UUID NOT NULL REFERENCES staff_profiles(id),
    review_type         review_type_enum NOT NULL,
    outcome             VARCHAR(50),
    notes               TEXT,
    reviewed_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (audit_log_id, audit_log_created_at) REFERENCES audit_logs(id, created_at)
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
CREATE INDEX idx_audit_subject_customer ON audit_logs(subject_customer_id, created_at DESC)
    WHERE subject_customer_id IS NOT NULL;
CREATE INDEX idx_audit_subject_merchant ON audit_logs(subject_merchant_id, created_at DESC)
    WHERE subject_merchant_id IS NOT NULL;
CREATE INDEX idx_audit_category_action ON audit_logs(event_category, operation_type, created_at DESC);
CREATE INDEX idx_audit_status_change ON audit_logs(entity_type, entity_id, from_status, to_status, created_at DESC)
    WHERE operation_type = 'status_change';
CREATE INDEX idx_audit_correlation ON audit_logs(correlation_id, created_at DESC)
    WHERE correlation_id IS NOT NULL;
CREATE INDEX idx_audit_idempotency ON audit_logs(idempotency_key, created_at DESC)
    WHERE idempotency_key IS NOT NULL;
CREATE INDEX idx_audit_polaris_jrno ON audit_logs(polaris_jrno, created_at DESC)
    WHERE polaris_jrno IS NOT NULL;
CREATE INDEX idx_audit_ledger_journal ON audit_logs(ledger_journal_id, created_at DESC)
    WHERE ledger_journal_id IS NOT NULL;
CREATE INDEX idx_staff_action_reviews_audit ON staff_action_reviews(audit_log_id, audit_log_created_at);
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
        'customer_pin_credentials',
        'customer_biometric_credentials',
        'customer_transaction_authorizations',
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
        'repayment_cashback_configs',
        'customer_cashback_wallets',
        'customer_cashback_wallet_transactions',
        'repayment_cashback_records',
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
        'customer_pin_credentials',
        'customer_biometric_credentials',
        'customer_transaction_authorizations',
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
    ADD CONSTRAINT chk_loan_applications_amount CHECK (
        requested_amount > 0
        AND (
            status NOT IN ('approved','pending_core_setup','pending_grant','pending_reconcile','disbursed')
            OR (
                requested_customer_deposit_account_id IS NOT NULL
                AND credit_line_account_id IS NOT NULL
                AND credit_limit_reservation_id IS NOT NULL
            )
        )
    );

ALTER TABLE loans
    ADD CONSTRAINT chk_loans_amounts CHECK (
        principal_amount > 0
        AND (disbursed_amount IS NULL OR (disbursed_amount >= 0 AND disbursed_amount <= principal_amount))
        AND interest_rate >= 0
        AND interest_rate <= 1
        AND (total_payable IS NULL OR total_payable >= principal_amount)
        AND schedule_status IN ('not_started','pending','succeeded','failed','pending_reconcile','skipped')
        AND line_link_status IN ('not_started','pending','succeeded','failed','pending_reconcile')
        AND grant_status IN ('not_started','pending','succeeded','failed','pending_reconcile')
        AND bnpl_merchant_transfer_status IN ('not_required','not_started','pending','succeeded','failed','pending_reconcile')
        AND (
            status <> 'pending_grant'
            OR (schedule_status = 'succeeded' AND line_link_status = 'succeeded')
        )
        AND (
            grant_status NOT IN ('pending','succeeded')
            OR (schedule_status = 'succeeded' AND line_link_status = 'succeeded')
        )
        AND (
            grant_status <> 'succeeded'
            OR (
                grant_ledger_journal_id IS NOT NULL
                AND grant_polaris_jrno IS NOT NULL
                AND disbursed_amount = principal_amount
                AND disbursed_at IS NOT NULL
            )
        )
        AND (
            bnpl_merchant_transfer_status <> 'succeeded'
            OR (
                bnpl_merchant_transfer_journal_id IS NOT NULL
                AND bnpl_merchant_transfer_polaris_jrno IS NOT NULL
            )
        )
        AND (
            status NOT IN ('active','closed')
            OR (
                polaris_product_config_id IS NOT NULL
                AND polaris_loan_account_id IS NOT NULL
                AND customer_deposit_account_id IS NOT NULL
                AND credit_line_account_id IS NOT NULL
                AND credit_limit_reservation_id IS NOT NULL
                AND schedule_status = 'succeeded'
                AND line_link_status = 'succeeded'
                AND grant_status = 'succeeded'
                AND bnpl_merchant_transfer_status IN ('not_required','succeeded')
            )
        )
    );

ALTER TABLE pos_payment_invoices
    ADD CONSTRAINT chk_pos_payment_invoices_amount CHECK (total_amount > 0);

ALTER TABLE pos_transactions
    ADD CONSTRAINT chk_pos_transactions_amounts CHECK (
        total_amount > 0
        AND installment_count > 0
        AND per_installment_amount > 0
        AND interest_amount >= 0
        AND merchant_transfer_status IN ('not_started','pending','succeeded','failed','pending_reconcile')
        AND (
            merchant_transfer_status <> 'succeeded'
            OR (
                merchant_passive_account_id IS NOT NULL
                AND merchant_transfer_ledger_journal_id IS NOT NULL
                AND merchant_transfer_polaris_jrno IS NOT NULL
            )
        )
        AND (
            status <> 'approved'
            OR (
                loan_id IS NOT NULL
                AND merchant_transfer_status = 'succeeded'
                AND approved_at IS NOT NULL
            )
        )
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
        AND principal_portion + interest_portion + penalty_portion <= amount
        AND (
            status <> 'completed'
            OR (
                principal_portion + interest_portion + penalty_portion = amount
                AND processed_at IS NOT NULL
                AND (
                    payment_channel = 'manual_adjustment'
                    OR (
                        inbound_ledger_journal_id IS NOT NULL
                        AND loan_payment_ledger_journal_id IS NOT NULL
                        AND inbound_polaris_jrno IS NOT NULL
                        AND loan_payment_polaris_jrno IS NOT NULL
                    )
                )
            )
        )
    );

ALTER TABLE repayment_allocations
    ADD CONSTRAINT chk_repayment_allocations_amounts CHECK (
        principal_amount >= 0
        AND interest_amount >= 0
        AND penalty_amount >= 0
        AND principal_amount + interest_amount + penalty_amount > 0
    );

ALTER TABLE repayment_cashback_configs
    ADD CONSTRAINT chk_cashback_configs_values CHECK (
        reward_value > 0
        AND (reward_type <> 'percentage' OR reward_value <= 1)
        AND (max_cashback_amount IS NULL OR max_cashback_amount > 0)
        AND (min_payment_amount IS NULL OR min_payment_amount >= 0)
        AND grace_days >= 0
        AND (applies_to_installment_number IS NULL OR applies_to_installment_number > 0)
        AND (product_id IS NULL OR product_type IS NULL)
        AND (effective_until IS NULL OR effective_until > effective_from)
    );

ALTER TABLE customer_cashback_wallets
    ADD CONSTRAINT chk_cashback_wallets_balances CHECK (
        available_balance >= 0
        AND pending_balance >= 0
        AND lifetime_earned >= 0
        AND lifetime_redeemed >= 0
        AND lifetime_earned >= lifetime_redeemed
        AND (status <> 'closed' OR closed_at IS NOT NULL)
    );

ALTER TABLE customer_cashback_wallet_transactions
    ADD CONSTRAINT chk_cashback_wallet_transactions_values CHECK (
        amount > 0
        AND (balance_before IS NULL OR balance_before >= 0)
        AND (balance_after IS NULL OR balance_after >= 0)
        AND (
            (source_table IS NULL AND source_id IS NULL)
            OR (source_table IS NOT NULL AND source_id IS NOT NULL)
        )
        AND (
            status <> 'posted'
            OR (
                posted_at IS NOT NULL
                AND balance_before IS NOT NULL
                AND balance_after IS NOT NULL
                AND ledger_journal_id IS NOT NULL
            )
        )
        AND (status <> 'failed' OR failed_at IS NOT NULL)
        AND (status <> 'reversed' OR reversed_at IS NOT NULL)
        AND (transaction_type <> 'reversal' OR reversal_of_transaction_id IS NOT NULL)
        AND (
            transaction_type NOT IN ('repayment_offset', 'redemption')
            OR authorization_id IS NOT NULL
        )
        AND (
            status <> 'posted'
            OR transaction_type = 'reversal'
            OR (
                transaction_type IN ('cashback_credit', 'adjustment_credit')
                AND balance_after >= balance_before
            )
            OR (
                transaction_type IN ('repayment_offset', 'redemption', 'adjustment_debit', 'expiry')
                AND balance_after <= balance_before
            )
        )
    );

ALTER TABLE repayment_cashback_records
    ADD CONSTRAINT chk_cashback_records_values CHECK (
        reward_value > 0
        AND (reward_type <> 'percentage' OR reward_value <= 1)
        AND calculation_base_amount > 0
        AND cashback_amount > 0
        AND grace_days_applied >= 0
        AND (
            status <> 'credited'
            OR (
                credited_at IS NOT NULL
                AND cashback_wallet_id IS NOT NULL
                AND wallet_transaction_id IS NOT NULL
                AND ledger_journal_id IS NOT NULL
            )
        )
        AND (
            status <> 'reversed'
            OR (
                credited_at IS NOT NULL
                AND cashback_wallet_id IS NOT NULL
                AND wallet_transaction_id IS NOT NULL
                AND ledger_journal_id IS NOT NULL
                AND reversed_at IS NOT NULL
                AND reversal_wallet_transaction_id IS NOT NULL
                AND reversal_ledger_journal_id IS NOT NULL
            )
        )
    );

ALTER TABLE penalty_records
    ADD CONSTRAINT chk_penalty_records_amounts CHECK (
        penalty_amount >= 0
        AND overdue_days >= 0
    );

ALTER TABLE polaris_accounts
    ADD CONSTRAINT chk_polaris_accounts_balance CHECK (current_balance >= 0);

ALTER TABLE polaris_product_configs
    ADD CONSTRAINT chk_polaris_product_configs_term CHECK (
        term_len IS NULL OR term_len > 0
    );

ALTER TABLE customer_deposit_accounts
    ADD CONSTRAINT chk_customer_deposit_accounts_open CHECK (
        status <> 'active' OR (polaris_account_id IS NOT NULL AND opened_at IS NOT NULL)
    );

ALTER TABLE credit_line_accounts
    ADD CONSTRAINT chk_credit_line_accounts_amounts CHECK (
        line_amount >= 0
        AND utilized_amount >= 0
        AND reserved_amount >= 0
        AND utilized_amount + reserved_amount <= line_amount
        AND (
            status <> 'active'
            OR (
                line_amount > 0
                AND polaris_account_id IS NOT NULL
                AND opened_at IS NOT NULL
            )
        )
    );

ALTER TABLE credit_limit_reservations
    ADD CONSTRAINT chk_credit_limit_reservations_amount CHECK (reserved_amount > 0);

ALTER TABLE credit_limit_reservations
    ADD CONSTRAINT chk_credit_limit_reservations_terminal_state CHECK (
        (status <> 'consumed' OR consumed_at IS NOT NULL)
        AND (status <> 'released' OR released_at IS NOT NULL)
        AND (status <> 'failed' OR failed_at IS NOT NULL)
    );

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
        AND (
            status <> 'completed'
            OR (
                ledger_journal_id IS NOT NULL
                AND polaris_jrno IS NOT NULL
                AND settled_at IS NOT NULL
            )
        )
    );

ALTER TABLE merchant_settlement_items
    ADD CONSTRAINT chk_merchant_settlement_items_amounts CHECK (
        gross_amount > 0
        AND refund_amount >= 0
        AND refund_amount <= gross_amount
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

ALTER TABLE customer_biometric_credentials
    ADD CONSTRAINT chk_customer_biometric_credential_hash CHECK (
        octet_length(credential_id_hash) = 32
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

ALTER TABLE polaris_operation_attempts
    ADD CONSTRAINT chk_operation_attempt_payload_hash CHECK (
        request_payload_hash IS NULL OR octet_length(request_payload_hash) = 32
    );

ALTER TABLE polaris_api_logs
    ADD CONSTRAINT chk_polaris_api_log_payload_hashes CHECK (
        (request_payload_hash IS NULL OR octet_length(request_payload_hash) = 32)
        AND (response_payload_hash IS NULL OR octet_length(response_payload_hash) = 32)
    );

ALTER TABLE loan_core_steps
    ADD CONSTRAINT chk_loan_core_steps_sync_tracking CHECK (
        status NOT IN ('processing', 'succeeded', 'pending_reconcile')
        OR (
            polaris_sync_queue_id IS NOT NULL
            AND idempotency_key IS NOT NULL
        )
    );

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

CREATE UNIQUE INDEX idx_cashback_wallet_transactions_idempotency
    ON customer_cashback_wallet_transactions(idempotency_key)
    WHERE idempotency_key IS NOT NULL;

CREATE UNIQUE INDEX idx_cashback_wallet_transactions_source_unique
    ON customer_cashback_wallet_transactions(source_table, source_id, transaction_type)
    WHERE source_table IS NOT NULL
      AND source_id IS NOT NULL
      AND status <> 'cancelled';

CREATE UNIQUE INDEX idx_cashback_records_idempotency
    ON repayment_cashback_records(idempotency_key)
    WHERE idempotency_key IS NOT NULL;

CREATE UNIQUE INDEX idx_ledger_journals_polaris_txn_ref
    ON ledger_journals(polaris_txn_ref)
    WHERE polaris_txn_ref IS NOT NULL;

CREATE UNIQUE INDEX idx_ledger_journals_polaris_jrno
    ON ledger_journals(polaris_jrno)
    WHERE polaris_jrno IS NOT NULL;

CREATE UNIQUE INDEX idx_ledger_journals_one_reversal
    ON ledger_journals(reversal_of_journal_id)
    WHERE reversal_of_journal_id IS NOT NULL;

CREATE UNIQUE INDEX idx_ledger_entries_polaris_line_ref
    ON ledger_entries(polaris_line_ref)
    WHERE polaris_line_ref IS NOT NULL;

CREATE UNIQUE INDEX idx_sync_queue_idempotency
    ON polaris_sync_queue(idempotency_key)
    WHERE idempotency_key IS NOT NULL;

CREATE UNIQUE INDEX idx_sync_queue_active_source
    ON polaris_sync_queue(source_table, source_id, operation)
    WHERE status IN ('pending', 'processing', 'pending_reconcile');

CREATE UNIQUE INDEX idx_credit_reservation_active_application
    ON credit_limit_reservations(loan_application_id)
    WHERE status = 'reserved';

CREATE UNIQUE INDEX idx_loans_grant_polaris_jrno
    ON loans(grant_polaris_jrno)
    WHERE grant_polaris_jrno IS NOT NULL;

CREATE UNIQUE INDEX idx_loans_bnpl_transfer_polaris_jrno
    ON loans(bnpl_merchant_transfer_polaris_jrno)
    WHERE bnpl_merchant_transfer_polaris_jrno IS NOT NULL;

CREATE UNIQUE INDEX idx_pos_txn_merchant_transfer_jrno
    ON pos_transactions(merchant_transfer_polaris_jrno)
    WHERE merchant_transfer_polaris_jrno IS NOT NULL;

CREATE UNIQUE INDEX idx_repay_txn_inbound_jrno
    ON repayment_transactions(inbound_polaris_jrno)
    WHERE inbound_polaris_jrno IS NOT NULL;

CREATE UNIQUE INDEX idx_repay_txn_loan_payment_jrno
    ON repayment_transactions(loan_payment_polaris_jrno)
    WHERE loan_payment_polaris_jrno IS NOT NULL;

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

CREATE UNIQUE INDEX idx_settlements_polaris_jrno
    ON merchant_settlements(polaris_jrno)
    WHERE polaris_jrno IS NOT NULL;


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

CREATE OR REPLACE FUNCTION validate_cashback_wallet_transaction_authorization()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_auth customer_transaction_authorizations%ROWTYPE;
BEGIN
    IF NEW.transaction_type IN ('repayment_offset', 'redemption')
       AND NEW.status IN ('pending', 'posted') THEN
        SELECT *
        INTO v_auth
        FROM customer_transaction_authorizations
        WHERE id = NEW.authorization_id
          AND customer_id = NEW.customer_id;

        IF NOT FOUND
           OR v_auth.status <> 'authorized'
           OR v_auth.currency <> NEW.currency
           OR (v_auth.amount IS NOT NULL AND v_auth.amount < NEW.amount)
           OR (v_auth.expires_at IS NOT NULL AND v_auth.expires_at <= NOW())
           OR v_auth.source_table <> 'customer_cashback_wallet_transactions'
           OR v_auth.source_id <> NEW.id THEN
            RAISE EXCEPTION 'Cashback wallet transaction % is not covered by a valid customer authorization', NEW.id
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_cashback_wallet_txn_authorization
BEFORE INSERT OR UPDATE OF transaction_type, authorization_id, customer_id, amount, currency, status
ON customer_cashback_wallet_transactions
FOR EACH ROW EXECUTE FUNCTION validate_cashback_wallet_transaction_authorization();

CREATE OR REPLACE FUNCTION validate_pos_invoice_parties()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_terminal RECORD;
    v_merchant RECORD;
BEGIN
    SELECT merchant_id, status
    INTO v_terminal
    FROM pos_terminals
    WHERE id = NEW.terminal_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'POS terminal % does not exist', NEW.terminal_id
            USING ERRCODE = '23503';
    END IF;

    IF v_terminal.merchant_id <> NEW.merchant_id THEN
        RAISE EXCEPTION 'POS invoice merchant % does not match terminal merchant %',
            NEW.merchant_id, v_terminal.merchant_id
            USING ERRCODE = '23514';
    END IF;

    IF v_terminal.status <> 'active' THEN
        RAISE EXCEPTION 'POS terminal % is not active', NEW.terminal_id
            USING ERRCODE = '23514';
    END IF;

    SELECT status, polaris_merchant_passive_account_id, polaris_settlement_account_id
    INTO v_merchant
    FROM merchant_profiles
    WHERE id = NEW.merchant_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Merchant % does not exist', NEW.merchant_id
            USING ERRCODE = '23503';
    END IF;

    IF v_merchant.status <> 'active' THEN
        RAISE EXCEPTION 'Merchant % is not active for POS lending', NEW.merchant_id
            USING ERRCODE = '23514';
    END IF;

    IF NEW.status IN ('qr_generated', 'processing', 'approved')
       AND (
            v_merchant.polaris_merchant_passive_account_id IS NULL
            OR v_merchant.polaris_settlement_account_id IS NULL
       ) THEN
        RAISE EXCEPTION 'Merchant % has no active Polaris passive/settlement account configured', NEW.merchant_id
            USING ERRCODE = '23514';
    END IF;

    IF NEW.status = 'approved'
       AND NOT EXISTS (
            SELECT 1
            FROM pos_transactions pt
            WHERE pt.invoice_id = NEW.id
              AND pt.status = 'approved'
              AND pt.merchant_transfer_status = 'succeeded'
       ) THEN
        RAISE EXCEPTION 'POS invoice % cannot be approved before merchant passive transfer is confirmed', NEW.id
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_pos_invoice_parties
BEFORE INSERT OR UPDATE OF terminal_id, merchant_id, status
ON pos_payment_invoices
FOR EACH ROW EXECUTE FUNCTION validate_pos_invoice_parties();

CREATE OR REPLACE FUNCTION validate_repayment_allocation_schedule_lock()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_schedule repayment_schedules%ROWTYPE;
    v_existing_amount NUMERIC(14,2);
    v_new_amount NUMERIC(14,2);
BEGIN
    SELECT *
    INTO v_schedule
    FROM repayment_schedules
    WHERE id = NEW.schedule_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Repayment schedule % does not exist', NEW.schedule_id
            USING ERRCODE = '23503';
    END IF;

    IF v_schedule.allocation_locked_at IS NULL THEN
        RAISE EXCEPTION 'Repayment schedule % must be locked before allocation', NEW.schedule_id
            USING ERRCODE = '23514';
    END IF;

    SELECT COALESCE(SUM(principal_amount + interest_amount + penalty_amount), 0)
    INTO v_existing_amount
    FROM repayment_allocations
    WHERE schedule_id = NEW.schedule_id
      AND id <> NEW.id;

    v_new_amount := NEW.principal_amount + NEW.interest_amount + NEW.penalty_amount;

    IF v_existing_amount + v_new_amount >
       v_schedule.principal_amount + v_schedule.interest_amount + v_schedule.penalty_amount THEN
        RAISE EXCEPTION 'Repayment allocation exceeds total due for schedule %', NEW.schedule_id
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_repayment_allocation_schedule_lock
BEFORE INSERT OR UPDATE OF schedule_id, principal_amount, interest_amount, penalty_amount
ON repayment_allocations
FOR EACH ROW EXECUTE FUNCTION validate_repayment_allocation_schedule_lock();

CREATE OR REPLACE FUNCTION validate_loan_application_core_refs()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_deposit RECORD;
    v_line RECORD;
    v_reservation RECORD;
BEGIN
    IF NEW.status NOT IN ('approved', 'pending_core_setup', 'pending_grant', 'pending_reconcile', 'disbursed') THEN
        RETURN NEW;
    END IF;

    SELECT customer_id, status
    INTO v_deposit
    FROM customer_deposit_accounts
    WHERE id = NEW.requested_customer_deposit_account_id;

    IF NOT FOUND
       OR v_deposit.customer_id <> NEW.customer_id
       OR v_deposit.status <> 'active' THEN
        RAISE EXCEPTION 'Loan application % requires an active customer deposit account', NEW.id
            USING ERRCODE = '23514';
    END IF;

    SELECT customer_id, customer_deposit_account_id, status
    INTO v_line
    FROM credit_line_accounts
    WHERE id = NEW.credit_line_account_id;

    IF NOT FOUND
       OR v_line.customer_id <> NEW.customer_id
       OR v_line.customer_deposit_account_id <> NEW.requested_customer_deposit_account_id
       OR v_line.status <> 'active' THEN
        RAISE EXCEPTION 'Loan application % requires an active matching credit line', NEW.id
            USING ERRCODE = '23514';
    END IF;

    SELECT customer_id, credit_line_account_id, loan_application_id, reserved_amount, status
    INTO v_reservation
    FROM credit_limit_reservations
    WHERE id = NEW.credit_limit_reservation_id
    FOR UPDATE;

    IF NOT FOUND
       OR v_reservation.customer_id <> NEW.customer_id
       OR v_reservation.credit_line_account_id <> NEW.credit_line_account_id
       OR v_reservation.loan_application_id <> NEW.id
       OR v_reservation.reserved_amount < NEW.requested_amount THEN
        RAISE EXCEPTION 'Loan application % requires a matching credit reservation', NEW.id
            USING ERRCODE = '23514';
    END IF;

    IF NEW.status = 'disbursed' AND v_reservation.status <> 'consumed' THEN
        RAISE EXCEPTION 'Loan application % cannot be disbursed until reservation is consumed', NEW.id
            USING ERRCODE = '23514';
    ELSIF NEW.status <> 'disbursed' AND v_reservation.status NOT IN ('reserved', 'consumed') THEN
        RAISE EXCEPTION 'Loan application % has no active reservation for core setup', NEW.id
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_loan_application_core_refs
BEFORE INSERT OR UPDATE OF status, requested_customer_deposit_account_id, credit_line_account_id, credit_limit_reservation_id, requested_amount
ON loan_applications
FOR EACH ROW EXECUTE FUNCTION validate_loan_application_core_refs();

CREATE OR REPLACE FUNCTION validate_loan_bnpl_transfer_policy()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_product_type product_type_enum;
BEGIN
    SELECT product_type
    INTO v_product_type
    FROM loan_products
    WHERE id = NEW.product_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan product % does not exist', NEW.product_id
            USING ERRCODE = '23503';
    END IF;

    IF v_product_type = 'bnpl' THEN
        IF NEW.status IN ('pending_bnpl_transfer', 'active', 'closed')
           AND NEW.bnpl_merchant_transfer_status = 'not_required' THEN
            RAISE EXCEPTION 'BNPL loan % requires merchant transfer tracking', NEW.id
                USING ERRCODE = '23514';
        END IF;

        IF NEW.status IN ('active', 'closed')
           AND NEW.bnpl_merchant_transfer_status <> 'succeeded' THEN
            RAISE EXCEPTION 'BNPL loan % cannot become % before merchant transfer succeeds', NEW.id, NEW.status
                USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.status IN ('active', 'closed')
          AND NEW.bnpl_merchant_transfer_status <> 'not_required' THEN
        RAISE EXCEPTION 'Non-BNPL loan % cannot require merchant transfer', NEW.id
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_loan_bnpl_transfer_policy
BEFORE INSERT OR UPDATE OF product_id, status, bnpl_merchant_transfer_status
ON loans
FOR EACH ROW EXECUTE FUNCTION validate_loan_bnpl_transfer_policy();

CREATE OR REPLACE FUNCTION enforce_loan_core_step_order()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IN ('processing', 'succeeded', 'pending_reconcile') THEN
        IF NEW.loan_id IS NOT NULL AND EXISTS (
            SELECT 1
            FROM loan_core_steps prev
            WHERE prev.loan_id = NEW.loan_id
              AND prev.id <> NEW.id
              AND prev.operation_order < NEW.operation_order
              AND prev.status NOT IN ('succeeded', 'skipped')
        ) THEN
            RAISE EXCEPTION 'Loan core step % cannot start before earlier loan steps are succeeded or skipped', NEW.step
                USING ERRCODE = '23514';
        ELSIF NEW.loan_id IS NULL
              AND NEW.loan_application_id IS NOT NULL
              AND EXISTS (
                SELECT 1
                FROM loan_core_steps prev
                WHERE prev.loan_application_id = NEW.loan_application_id
                  AND prev.id <> NEW.id
                  AND prev.operation_order < NEW.operation_order
                  AND prev.status NOT IN ('succeeded', 'skipped')
              ) THEN
            RAISE EXCEPTION 'Loan core step % cannot start before earlier application steps are succeeded or skipped', NEW.step
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_enforce_loan_core_step_order
BEFORE INSERT OR UPDATE OF loan_id, loan_application_id, operation_order, status
ON loan_core_steps
FOR EACH ROW EXECUTE FUNCTION enforce_loan_core_step_order();


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

CREATE TRIGGER trg_pause_cashback_wallet
BEFORE INSERT OR UPDATE ON customer_cashback_wallets
FOR EACH ROW EXECUTE FUNCTION prevent_when_service_paused('cashback');

CREATE TRIGGER trg_pause_cashback_wallet_transaction
BEFORE INSERT OR UPDATE ON customer_cashback_wallet_transactions
FOR EACH ROW EXECUTE FUNCTION prevent_when_service_paused('cashback');

CREATE TRIGGER trg_pause_repayment_cashback_record
BEFORE INSERT OR UPDATE ON repayment_cashback_records
FOR EACH ROW EXECUTE FUNCTION prevent_when_service_paused('cashback');

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

CREATE TRIGGER trg_pause_credit_limit_reservation
BEFORE INSERT OR UPDATE ON credit_limit_reservations
FOR EACH ROW EXECUTE FUNCTION prevent_when_service_paused('loan_disbursement');

CREATE TRIGGER trg_pause_loan_core_step
BEFORE INSERT OR UPDATE ON loan_core_steps
FOR EACH ROW EXECUTE FUNCTION prevent_when_service_paused('loan_disbursement');

CREATE TRIGGER trg_pause_customer_deposit_account
BEFORE INSERT OR UPDATE ON customer_deposit_accounts
FOR EACH ROW EXECUTE FUNCTION prevent_when_service_paused('polaris_sync');

CREATE TRIGGER trg_pause_credit_line_account
BEFORE INSERT OR UPDATE ON credit_line_accounts
FOR EACH ROW EXECUTE FUNCTION prevent_when_service_paused('polaris_sync');

CREATE TRIGGER trg_pause_ledger_journal
BEFORE INSERT OR UPDATE ON ledger_journals
FOR EACH ROW EXECUTE FUNCTION prevent_when_service_paused('polaris_sync');

CREATE TRIGGER trg_pause_ledger_entry
BEFORE INSERT OR UPDATE ON ledger_entries
FOR EACH ROW EXECUTE FUNCTION prevent_when_service_paused('polaris_sync');

CREATE TRIGGER trg_pause_polaris_sync_queue
BEFORE INSERT OR UPDATE ON polaris_sync_queue
FOR EACH ROW EXECUTE FUNCTION prevent_when_service_paused('polaris_sync');

CREATE TRIGGER trg_pause_polaris_operation_attempt
BEFORE INSERT OR UPDATE ON polaris_operation_attempts
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

CREATE OR REPLACE FUNCTION audit_status_transition()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_event_category audit_event_category_enum := TG_ARGV[0]::audit_event_category_enum;
    v_entity_type TEXT := TG_ARGV[1];
    v_source_module TEXT := TG_ARGV[2];
    v_status_col TEXT := COALESCE(NULLIF(TG_ARGV[3], ''), 'status');
    v_new JSONB := to_jsonb(NEW);
    v_old JSONB;
    v_from_status TEXT;
    v_to_status TEXT;
    v_user_id UUID := current_app_user_id();
    v_staff_id UUID;
    v_customer_actor_id UUID;
    v_merchant_actor_id UUID;
    v_actor_type audit_actor_type_enum := 'system';
    v_subject_customer_id UUID;
    v_subject_merchant_id UUID;
    v_outcome audit_outcome_enum := 'success';
    v_action VARCHAR(100);
BEGIN
    IF TG_OP = 'UPDATE' THEN
        v_old := to_jsonb(OLD);
        v_from_status := v_old ->> v_status_col;
    END IF;

    v_to_status := v_new ->> v_status_col;

    IF v_to_status IS NULL OR v_from_status IS NOT DISTINCT FROM v_to_status THEN
        RETURN NEW;
    END IF;

    IF v_user_id IS NOT NULL THEN
        SELECT id INTO v_staff_id
        FROM staff_profiles
        WHERE user_id = v_user_id
        LIMIT 1;

        SELECT id INTO v_customer_actor_id
        FROM customer_profiles
        WHERE user_id = v_user_id
        LIMIT 1;

        SELECT id INTO v_merchant_actor_id
        FROM merchant_profiles
        WHERE user_id = v_user_id
        LIMIT 1;

        IF v_staff_id IS NOT NULL THEN
            v_actor_type := 'staff';
        ELSIF v_customer_actor_id IS NOT NULL THEN
            v_actor_type := 'customer';
        ELSIF v_merchant_actor_id IS NOT NULL THEN
            v_actor_type := 'merchant';
        ELSE
            v_actor_type := 'service';
        END IF;
    END IF;

    IF TG_TABLE_NAME = 'customer_profiles' THEN
        v_subject_customer_id := (v_new ->> 'id')::UUID;
    ELSIF v_new ? 'customer_id' AND v_new ->> 'customer_id' IS NOT NULL THEN
        v_subject_customer_id := (v_new ->> 'customer_id')::UUID;
    END IF;

    IF TG_TABLE_NAME = 'merchant_profiles' THEN
        v_subject_merchant_id := (v_new ->> 'id')::UUID;
    ELSIF v_new ? 'merchant_id' AND v_new ->> 'merchant_id' IS NOT NULL THEN
        v_subject_merchant_id := (v_new ->> 'merchant_id')::UUID;
    END IF;

    IF v_to_status IN ('pending_reconcile') THEN
        v_outcome := 'pending_reconcile';
    ELSIF v_to_status IN ('failed','dead_letter','mismatched') THEN
        v_outcome := 'failure';
    ELSIF v_to_status IN ('rejected') THEN
        v_outcome := 'rejected';
    ELSIF v_to_status LIKE 'pending%' OR v_to_status IN (
        'unreconciled',
        'processing',
        'submitted',
        'approved',
        'created',
        'received',
        'reserved',
        'partial',
        'overdue',
        'qr_generated'
    ) THEN
        v_outcome := 'pending';
    END IF;

    v_action := UPPER(regexp_replace(v_entity_type || '_' || v_status_col || '_status_change', '[^a-zA-Z0-9]+', '_', 'g'));

    INSERT INTO audit_logs (
        event_category,
        operation_type,
        outcome,
        action,
        actor_type,
        user_id,
        staff_id,
        customer_id,
        merchant_id,
        subject_customer_id,
        subject_merchant_id,
        entity_type,
        entity_id,
        source_table,
        source_id,
        from_status,
        to_status,
        old_value,
        new_value,
        metadata,
        source_module
    ) VALUES (
        v_event_category,
        'status_change',
        v_outcome,
        v_action,
        v_actor_type,
        v_user_id,
        v_staff_id,
        v_customer_actor_id,
        v_merchant_actor_id,
        v_subject_customer_id,
        v_subject_merchant_id,
        v_entity_type,
        (v_new ->> 'id')::UUID,
        TG_TABLE_NAME,
        (v_new ->> 'id')::UUID,
        v_from_status,
        v_to_status,
        CASE WHEN v_from_status IS NULL THEN NULL ELSE jsonb_build_object(v_status_col, v_from_status) END,
        jsonb_build_object(v_status_col, v_to_status),
        jsonb_build_object('schema', TG_TABLE_SCHEMA, 'table', TG_TABLE_NAME, 'status_column', v_status_col),
        v_source_module
    );

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_user_status
AFTER INSERT OR UPDATE OF status ON users
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('security','user','auth','status');

CREATE TRIGGER trg_audit_merchant_status
AFTER INSERT OR UPDATE OF status ON merchant_profiles
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('merchant','merchant_profile','merchant_onboarding','status');

CREATE TRIGGER trg_audit_pin_status
AFTER INSERT OR UPDATE OF status ON customer_pin_credentials
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('security','customer_pin_credential','auth_factor','status');

CREATE TRIGGER trg_audit_biometric_status
AFTER INSERT OR UPDATE OF status ON customer_biometric_credentials
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('security','customer_biometric_credential','auth_factor','status');

CREATE TRIGGER trg_audit_txn_authorization_status
AFTER INSERT OR UPDATE OF status ON customer_transaction_authorizations
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('auth','customer_transaction_authorization','transaction_authorization','status');

CREATE TRIGGER trg_audit_customer_reg_status
AFTER INSERT OR UPDATE OF reg_status ON customer_profiles
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('kyc','customer_profile','customer_onboarding','reg_status');

CREATE TRIGGER trg_audit_customer_cif_status
AFTER INSERT OR UPDATE OF polaris_cif_status ON customer_profiles
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('polaris','customer_profile','polaris_cif','polaris_cif_status');

CREATE TRIGGER trg_audit_customer_kyc_sync_status
AFTER INSERT OR UPDATE OF polaris_kyc_sync_status ON customer_profiles
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('polaris','customer_profile','polaris_kyc','polaris_kyc_sync_status');

CREATE TRIGGER trg_audit_kyc_personal_status
AFTER INSERT OR UPDATE OF status ON kyc_personal_details
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('kyc','kyc_personal_detail','kyc','status');

CREATE TRIGGER trg_audit_customer_bank_account_status
AFTER INSERT OR UPDATE OF status ON customer_bank_accounts
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('kyc','customer_bank_account','kyc_bank_account','status');

CREATE TRIGGER trg_audit_kyc_address_status
AFTER INSERT OR UPDATE OF status ON kyc_addresses
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('kyc','kyc_address','kyc','status');

CREATE TRIGGER trg_audit_kyc_education_status
AFTER INSERT OR UPDATE OF status ON kyc_educations
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('kyc','kyc_education','kyc','status');

CREATE TRIGGER trg_audit_kyc_employment_status
AFTER INSERT OR UPDATE OF status ON kyc_employments
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('kyc','kyc_employment','kyc','status');

CREATE TRIGGER trg_audit_kyc_file_status
AFTER INSERT OR UPDATE OF status ON kyc_customer_files
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('kyc','kyc_customer_file','kyc','status');

CREATE TRIGGER trg_audit_kyc_related_customer_status
AFTER INSERT OR UPDATE OF status ON kyc_related_customers
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('kyc','kyc_related_customer','kyc','status');

CREATE TRIGGER trg_audit_kyc_signature_status
AFTER INSERT OR UPDATE OF status ON kyc_signature_images
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('kyc','kyc_signature_image','kyc','status');

CREATE TRIGGER trg_audit_dan_status
AFTER INSERT OR UPDATE OF status ON dan_verifications
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('kyc','dan_verification','dan','status');

CREATE TRIGGER trg_audit_kyc_step_status
AFTER INSERT OR UPDATE OF status ON kyc_verification_steps
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('kyc','kyc_verification_step','kyc_workflow','status');

CREATE TRIGGER trg_audit_credit_score_status
AFTER INSERT OR UPDATE OF status ON credit_score_results
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('scoring','credit_score_result','credit_scoring','status');

CREATE TRIGGER trg_audit_credit_score_polaris_sync_status
AFTER INSERT OR UPDATE OF polaris_score_sync_status ON credit_score_results
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('polaris','credit_score_result','polaris_score_sync','polaris_score_sync_status');

CREATE TRIGGER trg_audit_loan_limit_status
AFTER INSERT OR UPDATE OF status ON loan_limits
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('limit','loan_limit','credit_limit','status');

CREATE TRIGGER trg_audit_polaris_account_status
AFTER INSERT OR UPDATE OF status ON polaris_accounts
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('polaris','polaris_account','polaris_account','status');

CREATE TRIGGER trg_audit_customer_deposit_status
AFTER INSERT OR UPDATE OF status ON customer_deposit_accounts
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('polaris','customer_deposit_account','polaris_account','status');

CREATE TRIGGER trg_audit_credit_line_status
AFTER INSERT OR UPDATE OF status ON credit_line_accounts
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('limit','credit_line_account','credit_line','status');

CREATE TRIGGER trg_audit_credit_reservation_status
AFTER INSERT OR UPDATE OF status ON credit_limit_reservations
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('limit','credit_limit_reservation','credit_reservation','status');

CREATE TRIGGER trg_audit_loan_application_status
AFTER INSERT OR UPDATE OF status ON loan_applications
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('loan','loan_application','loan_application','status');

CREATE TRIGGER trg_audit_loan_status
AFTER INSERT OR UPDATE OF status ON loans
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('loan','loan','loan_core','status');

CREATE TRIGGER trg_audit_loan_schedule_status
AFTER INSERT OR UPDATE OF schedule_status ON loans
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('loan','loan','loan_core','schedule_status');

CREATE TRIGGER trg_audit_loan_line_link_status
AFTER INSERT OR UPDATE OF line_link_status ON loans
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('loan','loan','loan_core','line_link_status');

CREATE TRIGGER trg_audit_loan_grant_status
AFTER INSERT OR UPDATE OF grant_status ON loans
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('finance','loan','loan_grant','grant_status');

CREATE TRIGGER trg_audit_loan_bnpl_transfer_status
AFTER INSERT OR UPDATE OF bnpl_merchant_transfer_status ON loans
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('bnpl','loan','bnpl_transfer','bnpl_merchant_transfer_status');

CREATE TRIGGER trg_audit_pos_terminal_status
AFTER INSERT OR UPDATE OF status ON pos_terminals
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('merchant','pos_terminal','merchant_pos','status');

CREATE TRIGGER trg_audit_pos_invoice_status
AFTER INSERT OR UPDATE OF status ON pos_payment_invoices
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('bnpl','pos_payment_invoice','bnpl_pos','status');

CREATE TRIGGER trg_audit_pos_transaction_status
AFTER INSERT OR UPDATE OF status ON pos_transactions
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('bnpl','pos_transaction','bnpl_pos','status');

CREATE TRIGGER trg_audit_pos_merchant_transfer_status
AFTER INSERT OR UPDATE OF merchant_transfer_status ON pos_transactions
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('finance','pos_transaction','bnpl_merchant_transfer','merchant_transfer_status');

CREATE TRIGGER trg_audit_pos_terminal_callback_status
AFTER INSERT OR UPDATE OF status ON pos_terminal_callbacks
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('bnpl','pos_terminal_callback','bnpl_pos_callback','status');

CREATE TRIGGER trg_audit_qpay_invoice_status
AFTER INSERT OR UPDATE OF status ON qpay_repayment_invoices
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('repayment','qpay_repayment_invoice','repayment','status');

CREATE TRIGGER trg_audit_qpay_callback_status
AFTER INSERT OR UPDATE OF status ON qpay_repayment_callbacks
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('repayment','qpay_repayment_callback','repayment','status');

CREATE TRIGGER trg_audit_repayment_schedule_status
AFTER INSERT OR UPDATE OF status ON repayment_schedules
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('repayment','repayment_schedule','repayment','status');

CREATE TRIGGER trg_audit_repayment_transaction_status
AFTER INSERT OR UPDATE OF status ON repayment_transactions
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('repayment','repayment_transaction','repayment','status');

CREATE TRIGGER trg_audit_repayment_transaction_recon_status
AFTER INSERT OR UPDATE OF reconciliation_status ON repayment_transactions
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('repayment','repayment_transaction','repayment_reconciliation','reconciliation_status');

CREATE TRIGGER trg_audit_cashback_wallet_status
AFTER INSERT OR UPDATE OF status ON customer_cashback_wallets
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('repayment','customer_cashback_wallet','cashback','status');

CREATE TRIGGER trg_audit_cashback_wallet_txn_status
AFTER INSERT OR UPDATE OF status ON customer_cashback_wallet_transactions
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('repayment','customer_cashback_wallet_transaction','cashback','status');

CREATE TRIGGER trg_audit_cashback_record_status
AFTER INSERT OR UPDATE OF status ON repayment_cashback_records
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('repayment','repayment_cashback_record','cashback','status');

CREATE TRIGGER trg_audit_merchant_refund_status
AFTER INSERT OR UPDATE OF status ON merchant_refund_requests
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('merchant','merchant_refund_request','merchant_refund','status');

CREATE TRIGGER trg_audit_merchant_settlement_status
AFTER INSERT OR UPDATE OF status ON merchant_settlements
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('merchant','merchant_settlement','merchant_settlement','status');

CREATE TRIGGER trg_audit_ledger_journal_status
AFTER INSERT OR UPDATE OF status ON ledger_journals
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('finance','ledger_journal','ledger','status');

CREATE TRIGGER trg_audit_ledger_journal_recon_status
AFTER INSERT OR UPDATE OF reconciliation_status ON ledger_journals
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('finance','ledger_journal','ledger_reconciliation','reconciliation_status');

CREATE TRIGGER trg_audit_ledger_entry_recon_status
AFTER INSERT OR UPDATE OF reconciliation_status ON ledger_entries
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('finance','ledger_entry','ledger_reconciliation','reconciliation_status');

CREATE TRIGGER trg_audit_polaris_sync_status
AFTER INSERT OR UPDATE OF status ON polaris_sync_queue
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('polaris','polaris_sync_queue','polaris_sync','status');

CREATE TRIGGER trg_audit_polaris_attempt_status
AFTER INSERT OR UPDATE OF status ON polaris_operation_attempts
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('polaris','polaris_operation_attempt','polaris_sync','status');

CREATE TRIGGER trg_audit_loan_core_step_status
AFTER INSERT OR UPDATE OF status ON loan_core_steps
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('loan','loan_core_step','loan_core','status');

CREATE TRIGGER trg_audit_service_pause_status
AFTER INSERT OR UPDATE OF status ON service_pause_windows
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('system','service_pause_window','service_pause','status');

CREATE TRIGGER trg_audit_merchant_portal_user_status
AFTER INSERT OR UPDATE OF status ON merchant_portal_users
FOR EACH ROW EXECUTE FUNCTION audit_status_transition('security','merchant_portal_user','merchant_access','status');

ALTER TABLE customer_profiles   ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_pin_credentials ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_biometric_credentials ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_transaction_authorizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_personal_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_contact_infos    ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_bank_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_deposit_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE credit_line_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE credit_limit_reservations ENABLE ROW LEVEL SECURITY;
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
ALTER TABLE repayment_cashback_configs ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_cashback_wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_cashback_wallet_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE repayment_cashback_records ENABLE ROW LEVEL SECURITY;
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
        'customer_pin_credentials',
        'customer_biometric_credentials',
        'customer_transaction_authorizations',
        'kyc_personal_details',
        'kyc_contact_infos',
        'customer_bank_accounts',
        'customer_deposit_accounts',
        'credit_line_accounts',
        'credit_limit_reservations',
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

CREATE POLICY pol_repayment_cashback_configs_select ON repayment_cashback_configs
    FOR SELECT USING (is_current_staff());
CREATE POLICY pol_repayment_cashback_configs_insert ON repayment_cashback_configs
    FOR INSERT WITH CHECK (is_current_staff());
CREATE POLICY pol_repayment_cashback_configs_update ON repayment_cashback_configs
    FOR UPDATE USING (is_current_staff())
    WITH CHECK (is_current_staff());

CREATE POLICY pol_customer_cashback_wallets_select ON customer_cashback_wallets
    FOR SELECT USING (is_current_staff() OR is_current_customer(customer_id));
CREATE POLICY pol_customer_cashback_wallets_insert ON customer_cashback_wallets
    FOR INSERT WITH CHECK (is_current_staff());
CREATE POLICY pol_customer_cashback_wallets_update ON customer_cashback_wallets
    FOR UPDATE USING (is_current_staff())
    WITH CHECK (is_current_staff());

CREATE POLICY pol_customer_cashback_wallet_transactions_select ON customer_cashback_wallet_transactions
    FOR SELECT USING (is_current_staff() OR is_current_customer(customer_id));
CREATE POLICY pol_customer_cashback_wallet_transactions_insert ON customer_cashback_wallet_transactions
    FOR INSERT WITH CHECK (is_current_staff());
CREATE POLICY pol_customer_cashback_wallet_transactions_update ON customer_cashback_wallet_transactions
    FOR UPDATE USING (is_current_staff())
    WITH CHECK (is_current_staff());

CREATE POLICY pol_repayment_cashback_records_select ON repayment_cashback_records
    FOR SELECT USING (is_current_staff() OR is_current_customer(customer_id));
CREATE POLICY pol_repayment_cashback_records_insert ON repayment_cashback_records
    FOR INSERT WITH CHECK (is_current_staff());
CREATE POLICY pol_repayment_cashback_records_update ON repayment_cashback_records
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

-- Universal replacement for old per-entity status transition tables.
CREATE VIEW v_status_transition_audit AS
SELECT
    id,
    created_at,
    event_category,
    action,
    actor_type,
    user_id,
    staff_id,
    customer_id,
    merchant_id,
    subject_customer_id,
    subject_merchant_id,
    entity_type,
    entity_id,
    from_status,
    to_status,
    reason,
    correlation_id,
    idempotency_key,
    ledger_journal_id,
    polaris_jrno,
    metadata
FROM audit_logs
WHERE operation_type = 'status_change'
ORDER BY created_at DESC;

-- Finance/Core worklist for unknown or mismatched Polaris outcomes.
CREATE VIEW v_polaris_reconciliation_worklist AS
SELECT
    'polaris_sync_queue'::TEXT AS source_kind,
    psq.id,
    psq.source_table,
    psq.source_id,
    psq.operation::TEXT AS operation,
    psq.status::TEXT AS status,
    NULL::TEXT AS reconciliation_status,
    psq.idempotency_key,
    psq.correlation_id,
    psq.reconciliation_key,
    NULL::BIGINT AS polaris_jrno,
    psq.created_at,
    psq.last_attempt_at AS last_activity_at
FROM polaris_sync_queue psq
WHERE psq.status IN ('pending_reconcile', 'failed', 'dead_letter')
UNION ALL
SELECT
    'ledger_journal'::TEXT AS source_kind,
    lj.id,
    lj.source_table,
    lj.source_id,
    lj.source_operation AS operation,
    lj.status::TEXT AS status,
    lj.reconciliation_status::TEXT AS reconciliation_status,
    lj.idempotency_key,
    NULL::VARCHAR(100) AS correlation_id,
    lj.polaris_txn_ref AS reconciliation_key,
    lj.polaris_jrno,
    lj.created_at,
    COALESCE(lj.reconciled_at, lj.updated_at) AS last_activity_at
FROM ledger_journals lj
WHERE lj.status IN ('pending_reconcile', 'failed')
   OR lj.reconciliation_status IN ('mismatched', 'failed')
ORDER BY created_at DESC;

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
    cla.line_amount,
    cla.utilized_amount  AS line_utilized_amount,
    cla.reserved_amount  AS line_reserved_amount,
    cla.available_amount AS line_available_amount,
    cla.status           AS line_status,
    COUNT(l.id)          AS total_loans,
    SUM(CASE WHEN l.status = 'active' THEN 1 ELSE 0 END) AS active_loans,
    SUM(l.principal_amount) AS total_principal
FROM customer_profiles cp
LEFT JOIN loan_limits ll ON ll.customer_id = cp.id AND ll.status = 'active'
LEFT JOIN credit_line_accounts cla ON cla.id = ll.active_credit_line_account_id
LEFT JOIN loans l ON l.customer_id = cp.id
GROUP BY cp.id, cp.first_name, cp.last_name, cp.national_id_hash,
         ll.max_total_limit, ll.utilized_amount, ll.available_amount, ll.status,
         cla.line_amount, cla.utilized_amount, cla.reserved_amount, cla.available_amount, cla.status;

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
