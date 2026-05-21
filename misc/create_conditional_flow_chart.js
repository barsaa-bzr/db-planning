#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const cwd = '/Users/barsaa/Projects/planning';
const svgPath = path.join(cwd, 'app_flow_conditional_chart.svg');

const W = 6600;
const margin = 120;
const headerH = 250;
const laneTop = 300;
const laneH = 96;
const startY = 470;
const rowGap = 74;
const sectionGap = 92;

const lanes = {
  ui: { x: 150, w: 870, title: 'UI / Actors', sub: 'Customer, staff, merchant POS, scheduler', code: 'UI', color: '#2563eb' },
  app: { x: 1110, w: 1330, title: 'Application Workflow', sub: 'Validation, decisions, locks, statuses', code: 'APP', color: '#0f172a' },
  db: { x: 2570, w: 1190, title: 'Database Tables', sub: 'Rows created, updated, locked or referenced', code: 'DB', color: '#4f46e5' },
  api: { x: 3890, w: 1280, title: 'Polaris / External APIs', sub: 'Core banking and provider calls', code: 'API', color: '#0891b2' },
  control: { x: 5290, w: 1140, title: 'Response / Controls', sub: 'Success, rejection, reconcile, audit', code: 'OUT', color: '#15803d' },
};

const rows = [
  {
    section: ['Foundation', 'Configuration, merchant readiness, and service controls'],
    ui: ['Admin / back office', 'Create product, transaction, dynamic field and pause configs.'],
    app: ['Config active?', 'Every customer, account, loan, grant, repayment and settlement flow checks active config first.', 'decision'],
    db: ['Config tables', 'polaris_product_configs\npolaris_transaction_configs\npolaris_dynamic_field_mappings\nservice_pause_windows'],
    api: ['No write call', 'Config values map future prodCode, brchCode, curCode, txnDefCode and dynamicData.'],
    control: ['If missing', 'Block operation, return deterministic retry or setup error, write audit status_change when config status changes.'],
    branch: 'No: block',
    cont: 'Yes',
  },
  {
    ui: ['Merchant admin / staff', 'Register merchant, terminal and passive/settlement accounts.'],
    app: ['Merchant ready?', 'Merchant profile, POS terminal and account references must all be active before BNPL can start.', 'decision'],
    db: ['Merchant tables', 'merchant_profiles\npos_terminals\nmerchant_portal_users\npolaris_accounts'],
    api: ['Merchant / terminal APIs', 'tmm/insertMerchant\ntsd/createTsdTerminal\ntmm/insertTmmMerchantTermnl\naccount create/register if needed'],
    control: ['If not ready', 'Merchant remains pending; POS invoice creation and approvals are blocked.'],
    branch: 'No: pending',
    cont: 'Yes',
  },
  {
    section: ['Customer Onboarding', 'Registration, DAN authorization, CIF, deposit account, KYC and scoring'],
    ui: ['Customer app', 'Register phone/national ID, verify OTP, create login session, PIN or biometric credential.'],
    app: ['Duplicate or blocked user?', 'Registration resumes existing onboarding when safe; suspended or deleted users cannot log in.', 'decision'],
    db: ['Identity/session tables', 'users\ncustomer_profiles\notp_sessions\nuser_sessions\ncustomer_pin_credentials\ncustomer_biometric_credentials\nmessage_logs'],
    api: ['No Polaris call yet', 'Polaris starts only after DAN identity authorization succeeds.'],
    control: ['If duplicate / blocked', 'Reject, resume pending onboarding, or require staff review; log security event.'],
    branch: 'Yes: reject/resume',
    cont: 'No',
  },
  {
    ui: ['Customer app', 'Authorize DAN and provide consent for identity verification.'],
    app: ['DAN verified?', 'DAN result must match local customer identity and not be expired or reused incorrectly.', 'decision'],
    db: ['DAN rows', 'dan_verifications\ncustomer_profiles\naudit_logs'],
    api: ['DAN provider', 'External DAN authorization result is saved before CIF creation.'],
    control: ['If failed / expired', 'Stop onboarding, mark failed or manual_review, do not create Polaris CIF.'],
    branch: 'No: stop',
    cont: 'Yes',
  },
  {
    ui: ['System worker', 'Create or update core customer after DAN success.'],
    app: ['CIF synced?', 'Enqueue write with idempotency key. Duplicate CIF searches by register/national ID before update.', 'decision'],
    db: ['CIF state', 'customer_profiles\npolaris_sync_queue\npolaris_operation_attempts\npolaris_api_logs\naudit_logs'],
    api: ['Polaris CIF', 'cif/createPerson\nfallback search/update with cif/updatePerson'],
    control: ['Timeout / duplicate', 'Timeout becomes pending_reconcile. Duplicate becomes update/search path, not blind create.'],
    branch: 'Timeout: reconcile',
    cont: 'Synced',
  },
  {
    ui: ['System worker', 'Open customer deposit/CASA account after CIF exists.'],
    app: ['Deposit active?', 'Use stored product config. Save returned acntCode to customer and polaris account records.', 'decision'],
    db: ['Deposit account tables', 'customer_deposit_accounts\npolaris_accounts\ncustomer_profiles\npolaris_product_configs'],
    api: ['Polaris CASA', 'casa/createAccount\ncasa/openAccountStatus'],
    control: ['If unknown / failed', 'Customer cannot receive loans. Unknown result goes pending_reconcile and account detail search.'],
    branch: 'No: block loans',
    cont: 'Active',
  },
  {
    ui: ['Customer / staff', 'Submit profile, address, contact, file, employment, education and review steps.'],
    app: ['KYC complete locally and in Polaris?', 'Local KYC is verified only when required local data and required Polaris sync are both complete.', 'decision'],
    db: ['KYC tables', 'kyc_personal_details\nkyc_addresses\nkyc_contact_infos\nkyc_customer_files\nkyc_employments\nkyc_verification_steps'],
    api: ['Polaris CIF updates', 'cif/updatePerson\ncontact/address/photo/education APIs when configured\ndynamicData mappings'],
    control: ['If rejected / sync unknown', 'Reject or manual_review. Polaris sync timeout keeps polaris_kyc_sync_status pending_reconcile; no active line.'],
    branch: 'No: review/reject',
    cont: 'Complete',
  },
  {
    ui: ['Risk engine', 'Fetch external credit data and calculate score.'],
    app: ['Eligible score?', 'Combine HUR, Sain/FICO and custom model. Store explanation factors and model version.', 'decision'],
    db: ['Scoring tables', 'hur_data_snapshots\nsain_score_requests\ncredit_score_results\ncredit_scoring_factors'],
    api: ['External scoring', 'HUR service\nSain/FICO service\ncif/updatePerson dynamicData score sync'],
    control: ['If ineligible / bad data', 'No customer-facing offer. Manual review only if policy allows.'],
    branch: 'No: no offer',
    cont: 'Eligible',
  },
  {
    section: ['Limit and Line', 'Credit limit, Polaris line account, and drawdown capacity'],
    ui: ['Risk engine / staff', 'Create or refresh customer limit.'],
    app: ['Limit can be activated?', 'Requires verified KYC, synced score, active deposit account and active config.'],
    db: ['Limit tables', 'loan_limits\ncredit_score_results\ncustomer_deposit_accounts\naudit_logs'],
    api: ['No Polaris write here', 'Local limit activation triggers line account creation next.'],
    control: ['If not valid', 'Limit remains pending, suspended or rejected; no offer shown.'],
    branch: 'No: no offer',
    cont: 'Active',
  },
  {
    ui: ['System worker', 'Create line account for approved limit.'],
    app: ['Line active?', 'Use customer acntCode from deposit account and line product config. Store line acntCode.'],
    db: ['Line tables', 'credit_line_accounts\nloan_limits\npolaris_accounts\npolaris_product_configs\npolaris_sync_queue'],
    api: ['Polaris line', 'line/createAccount\nline/openAccount\nline/getAccountDetail on timeout'],
    control: ['Timeout / failure', 'No drawdown until line is confirmed active. Timeout goes pending_reconcile.'],
    branch: 'No: reconcile/block',
    cont: 'Active',
  },
  {
    ui: ['Risk engine / staff', 'Increase, decrease, suspend or expire limit.'],
    app: ['Decrease below utilized?', 'Lock line row. Available = line - utilized - reserved. Do not break existing loans.'],
    db: ['Line adjustment rows', 'loan_limits\ncredit_line_accounts\ncredit_limit_reservations\naudit_logs'],
    api: ['Polaris line adjust', 'line/adjustLineAccountLimit'],
    control: ['If below utilized', 'Suspend new drawdowns, keep existing loans, reconcile Polaris line amount.'],
    branch: 'Yes: suspend draws',
    cont: 'No / adjusted',
  },
  {
    section: ['Loan and BNPL Drawdown', 'Application, reservation, core loan setup, schedule, line link, grant and merchant transfer'],
    ui: ['Customer app / Merchant POS', 'Customer requests one-tap loan or scans BNPL QR.'],
    app: ['Which product path?', 'One-tap starts from loan amount. BNPL starts from merchant invoice and selected installment option.', 'decision'],
    db: ['Entry tables', 'loan_applications\npos_payment_invoices\npos_qr_codes\npos_transactions\nbnpl_installment_options'],
    api: ['No Polaris write yet', 'Do not touch core until local validation and reservation pass.'],
    control: ['If BNPL invoice invalid', 'Reject expired, duplicated, inactive merchant/terminal, mismatched merchant, or inactive passive account.'],
    branch: 'BNPL invalid',
    cont: 'Valid path',
  },
  {
    ui: ['System guard', 'Before reservation, child loan, grant, repayment or settlement.'],
    app: ['Service paused or duplicate operation?', 'Check EOD pause window and unique idempotency key before creating side effects.', 'decision'],
    db: ['Guard tables', 'service_pause_windows\npolaris_sync_queue\naudit_logs\nsystem_event_logs'],
    api: ['No call if paused', 'Polaris call is skipped during configured core/service pause.'],
    control: ['If paused / duplicate', 'Return retryable paused response or idempotent existing result. No duplicate operation.'],
    branch: 'Yes: stop',
    cont: 'No',
  },
  {
    ui: ['System worker', 'Reserve available line before approval and core setup.'],
    app: ['Available after row lock?', 'Lock credit_line_accounts. Reserve before approval to prevent double spend and concurrent grants.', 'decision'],
    db: ['Reservation tables', 'credit_line_accounts\ncredit_limit_reservations\nloan_applications\npos_transactions\naudit_logs'],
    api: ['No Polaris write yet', 'Line capacity is protected locally before core account setup.'],
    control: ['If not enough', 'Reject/release pending application. Duplicate submission returns existing reservation state.'],
    branch: 'No: reject',
    cont: 'Reserved',
  },
  {
    ui: ['Customer / staff / system', 'Approve terms and accept contract/PIN authorization.'],
    app: ['Contract and consent valid?', 'Approval is not enough. Amount, term, customer, product and authorization must match.'],
    db: ['Approval tables', 'loan_applications\nloan_contracts\ncustomer_transaction_authorizations\ncredit_limit_reservations\naudit_logs'],
    api: ['No Polaris write on rejection', 'Rejected/cancelled applications release reservation only if no Polaris loan exists.'],
    control: ['If rejected / consent bad', 'Release reservation, mark application rejected/cancelled, return reason.'],
    branch: 'No: release',
    cont: 'Approved',
  },
  {
    ui: ['System worker', 'Create and open child loan account.'],
    app: ['Child loan account open?', 'Create local loan row, enforce loan_core_steps order, enqueue each Polaris write.'],
    db: ['Loan core rows', 'loans\nloan_core_steps\npolaris_accounts\npolaris_sync_queue\npolaris_operation_attempts'],
    api: ['Polaris loan account', 'loan/createAccount\nloan/openAccount'],
    control: ['If timeout', 'Do not cancel blindly. Search account detail, then mark success, retry same key, or dead_letter.'],
    branch: 'Timeout: reconcile',
    cont: 'Open',
  },
  {
    ui: ['System worker', 'Calculate and create repayment schedule.'],
    app: ['Schedule confirmed and matched?', 'Local schedule is written only after Polaris schedule exists and amounts/dates match.'],
    db: ['Schedule rows', 'repayment_schedules\nloan_core_steps\nloans\naudit_logs'],
    api: ['Polaris schedule', 'loan/calculateNrsSchedule\nloan/createNrsSchedule\nloan/getNrsSchedule if needed'],
    control: ['If mismatch/fail', 'No line link and no grant. Keep reservation until retry/cancel policy resolves.'],
    branch: 'No: stop grant',
    cont: 'Matched',
  },
  {
    ui: ['System worker', 'Connect child loan to line account.'],
    app: ['Loan linked to line?', 'Grant is blocked until the child loan is linked to the active line account.'],
    db: ['Line link rows', 'loans\ncredit_line_accounts\nloan_core_steps\npolaris_sync_queue'],
    api: ['Polaris line link', 'line/linkLineAccountToLoan'],
    control: ['If unknown', 'pending_reconcile. Do not call grant until link is confirmed.'],
    branch: 'No/timeout',
    cont: 'Linked',
  },
  {
    ui: ['System worker', 'Grant loan into customer deposit account.'],
    app: ['Grant journal confirmed?', 'Create ledger journal first, then execute grant from child loan to customer deposit.'],
    db: ['Grant ledger rows', 'ledger_journals\nledger_entries\nloans\nloan_applications\ncredit_limit_reservations\npolaris_accounts'],
    api: ['Polaris grant', 'loan/grantLoanNonCash\njournal/statement lookup on timeout'],
    control: ['If unknown result', 'pending_reconcile. Never double grant; first query jrno, statements and account details.'],
    branch: 'Timeout: reconcile',
    cont: 'jrno stored',
  },
  {
    ui: ['System decision', 'After grant is confirmed.'],
    app: ['Is this BNPL?', 'One-tap becomes active immediately. BNPL must still transfer customer deposit to merchant passive.'],
    db: ['Product state', 'loans\npos_transactions\nloan_applications\ncredit_limit_reservations\naudit_logs'],
    api: ['No new call for one-tap', 'BNPL continues to internal CASA transfer.'],
    control: ['One-tap success', 'Loan active, application disbursed, reservation consumed, customer can use funds.'],
    branch: 'No: one-tap active',
    cont: 'Yes: BNPL',
  },
  {
    ui: ['System worker', 'Move BNPL money from customer deposit to merchant passive account.'],
    app: ['Merchant transfer confirmed?', 'POS is not approved until the passive transfer jrno is confirmed.'],
    db: ['BNPL transfer rows', 'pos_transactions\nmerchant_settlement_items\nledger_journals\nledger_entries\nloans\naudit_logs'],
    api: ['Polaris internal CASA', 'tllrcasa/internalCasaTransaction\ncustomer deposit -> merchant passive'],
    control: ['If timeout/fail', 'Loan may exist, but POS stays pending_merchant_transfer/pending_reconcile. No approved callback.'],
    branch: 'No: pending',
    cont: 'Confirmed',
  },
  {
    ui: ['Merchant POS', 'Receive final approved/rejected/timeout callback.'],
    app: ['Callback delivered?', 'Retry callback delivery idempotently. Financial operations are never repeated by callback retry.'],
    db: ['Callback rows', 'pos_terminal_callbacks\npos_payment_invoices\npos_transactions\naudit_logs'],
    api: ['Merchant POS callback', 'External merchant terminal callback endpoint.'],
    control: ['If delivery fails', 'Retry callback only. Loan grant and merchant transfer stay single-execution.'],
    branch: 'No: retry callback',
    cont: 'Delivered',
  },
  {
    section: ['Repayment and Closing', 'QPay callback, inbound money, loan payment, allocation, overdue and final close'],
    ui: ['Customer app', 'Create repayment invoice for schedule, loan or manual amount.'],
    app: ['Active payable target?', 'Invoice amount must be positive and target loan/schedule must be active.'],
    db: ['QPay invoice rows', 'qpay_repayment_invoices\nrepayment_schedules\nloans\naudit_logs'],
    api: ['QPay invoice', 'External QPay invoice creation if provider is used.'],
    control: ['If duplicate/invalid', 'Reject or return existing active invoice according to policy.'],
    branch: 'No: reject/reuse',
    cont: 'Created',
  },
  {
    ui: ['QPay / system', 'Receive payment callback.'],
    app: ['Callback valid and new?', 'Validate signature, amount, invoice, qpay_payment_id and idempotency key.'],
    db: ['Callback rows', 'qpay_repayment_callbacks\nrepayment_transactions\naudit_logs'],
    api: ['QPay callback', 'External QPay payment notification.'],
    control: ['Duplicate / invalid', 'Duplicate payment id is ignored. Invalid callback is failed with no loan payment.'],
    branch: 'No: ignored/failed',
    cont: 'Valid',
  },
  {
    ui: ['System worker', 'Stage real incoming money to customer deposit.'],
    app: ['Inbound money confirmed?', 'Do not pay loan until bank/QPay/repayment pool transfer is confirmed.'],
    db: ['Inbound ledger rows', 'repayment_transactions\nledger_journals\nledger_entries\npolaris_accounts'],
    api: ['Inbound transfer', 'tllrbac/transactionBacToCasa or configured inbound transfer'],
    control: ['If unknown', 'Funds are not allocated to loan. Mark pending_reconcile and query statements first.'],
    branch: 'No/timeout',
    cont: 'Confirmed',
  },
  {
    ui: ['System worker', 'Pay loan from customer deposit account.'],
    app: ['Loan payment confirmed?', 'Use same repayment transaction idempotency key. Staged funds are not double-applied.'],
    db: ['Loan payment rows', 'repayment_transactions\nledger_journals\nledger_entries\nloan_core_steps\npolaris_accounts'],
    api: ['Polaris loan payment', 'loan/nonCashLoanPayment\nloan/loanPaymentTxnNonCash'],
    control: ['If payment fails after inbound', 'Keep funds staged, retry/reconcile same transaction only.'],
    branch: 'No: staged',
    cont: 'Confirmed',
  },
  {
    ui: ['System worker', 'Allocate confirmed payment to schedules.'],
    app: ['Schedule lock acquired?', 'Lock schedules before allocation; principal, interest and penalty order follows policy.'],
    db: ['Allocation rows', 'repayment_schedules\nrepayment_allocations\nrepayment_transactions\naudit_logs'],
    api: ['No extra write', 'Polaris payment is already confirmed unless adjustment is required.'],
    control: ['If lock conflict', 'Retry allocation idempotently. Never allocate above total due.'],
    branch: 'No: retry',
    cont: 'Locked',
  },
  {
    ui: ['System decision', 'Classify repayment result.'],
    app: ['Overpayment or final payment?', 'Partial updates schedule. Overpayment follows hold/refund policy. Final payment checks closing details.'],
    db: ['Repayment state', 'repayment_schedules\nrepayment_transactions\nrepayment_allocations\nledger_journals\nloans'],
    api: ['Polaris closing detail', 'loan/getLoanClosingAccountDetail for final close candidate'],
    control: ['If overpaid', 'Reject before movement or hold/refund once after statement check. No paid amount above total due.'],
    branch: 'Overpaid: hold/refund',
    cont: 'Partial/final',
  },
  {
    ui: ['System worker', 'Close loan when fully paid.'],
    app: ['Close confirmed?', 'Close only when all schedules are paid and Polaris closing detail confirms payable amount.'],
    db: ['Closing rows', 'loans\nrepayment_schedules\ncredit_line_accounts\nledger_journals\naudit_logs'],
    api: ['Polaris close', 'loan/nonCashCloseAccount\nstatement/account detail on timeout'],
    control: ['If timeout', 'pending_reconcile. Reduce line utilized amount only after confirmed close.'],
    branch: 'No/timeout',
    cont: 'Closed',
  },
  {
    ui: ['Scheduler', 'Run daily overdue, penalty and notification jobs.'],
    app: ['Due unpaid schedules?', 'Mark overdue, add penalty only once, notify customer and expose collection state.'],
    db: ['Collection rows', 'repayment_schedules\npenalty_records\nnotification_logs\naudit_logs'],
    api: ['Optional penalty sync', 'No Polaris call unless configured penalty posting is required.'],
    control: ['If job retries', 'Idempotent retry; no duplicate penalty or notification side effect where uniqueness applies.'],
    branch: 'No: skip',
    cont: 'Processed',
  },
  {
    ui: ['Scheduler', 'Apply cashback or repayment reward when eligible.'],
    app: ['Reward eligible and not paid?', 'Check repayment timing and product policy before writing wallet/reward rows.'],
    db: ['Reward rows', 'repayment_cashback_records\ncustomer_cashback_wallets\ncustomer_cashback_wallet_transactions'],
    api: ['Optional transfer', 'Configured Polaris transfer if reward money moves to customer account.'],
    control: ['If duplicate/ineligible', 'Skip or mark failed pending retry. Reward is credited once.'],
    branch: 'No: skip',
    cont: 'Credited',
  },
  {
    section: ['Settlement, Refund and Reversal', 'Merchant payout, BNPL refund logic, and one-reversal-per-jrno control'],
    ui: ['Finance scheduler', 'Build merchant settlement from approved BNPL transactions.'],
    app: ['Settlement items unique?', 'Include approved BNPL minus refunds. One POS transaction belongs to one settlement item.'],
    db: ['Settlement rows', 'merchant_settlements\nmerchant_settlement_items\npos_transactions\nmerchant_refund_requests'],
    api: ['Optional settlement read', 'tmm/selectSettleFintxn or configured settlement preparation call.'],
    control: ['If mismatch', 'Keep settlement pending and require finance review before money movement.'],
    branch: 'No: review',
    cont: 'Ready',
  },
  {
    ui: ['Finance scheduler / ops', 'Transfer merchant payable amount.'],
    app: ['Settlement transfer confirmed?', 'Use settlement idempotency key and ledger journal.'],
    db: ['Settlement ledger', 'merchant_settlements\nledger_journals\nledger_entries\npolaris_accounts\naudit_logs'],
    api: ['Settlement transfer', 'merchant passive -> settlement/bank account configured transfer'],
    control: ['Timeout', 'pending_reconcile. Do not create duplicate settlement item or second payout.'],
    branch: 'No/timeout',
    cont: 'Completed',
  },
  {
    ui: ['Merchant / staff', 'Request full or partial refund.'],
    app: ['Refund valid?', 'Validate POS, loan, settlement state, amount, product policy and idempotency key.'],
    db: ['Refund rows', 'merchant_refund_requests\nmerchant_return_items\npos_transactions\nloans\nledger_journals'],
    api: ['No write until approved', 'No Polaris reversal before refund approval.'],
    control: ['If invalid/duplicate', 'Reject duplicate, over-amount or policy-invalid request.'],
    branch: 'No: reject',
    cont: 'Approved',
  },
  {
    ui: ['Finance / system', 'Execute refund depending on settlement state.'],
    app: ['Already settled?', 'Before settlement: reverse merchant passive transfer then loan policy. After settlement: offset or reverse settlement first.'],
    db: ['Reversal rows', 'ledger_journals\nmerchant_refund_requests\nmerchant_settlements\nmerchant_settlement_items\nloans\npos_transactions'],
    api: ['Polaris reversal', 'gen/doReverseTxn\ngen/undoTransaction\nonly once per original jrno'],
    control: ['If ambiguous', 'pending_reconcile/dead_letter. Never issue a second reversal until first result is proven.'],
    branch: 'Ambiguous: manual',
    cont: 'Reversed/offset',
  },
  {
    section: ['Reconciliation and Governance', 'Timeout resolution, daily matching, audit, ledger, API logs and reporting'],
    ui: ['Any Polaris writer', 'A connection drop, timeout, 5xx, client crash or unknown response occurs.'],
    app: ['Was result proven?', 'Unknown write result is pending_reconcile, not failed. First search journal/account truth before retry.'],
    db: ['Reconcile queues', 'polaris_sync_queue\npolaris_operation_attempts\npolaris_api_logs\nledger_journals\npolaris_accounts'],
    api: ['Truth search', 'gen/getTmwJournalList\ngen/getAccountStatement\naccount detail APIs\nloan/detail APIs'],
    control: ['Resolution', 'Match -> mark success. No match and safe -> retry same key. Multiple matches -> dead_letter manual review.'],
    branch: 'Unknown',
    cont: 'Resolved',
  },
  {
    ui: ['Daily scheduler / finance ops', 'Run full reconciliation.'],
    app: ['All balances and journals match?', 'Compare app ledger, Polaris jrno, account statements, loan status, schedules and settlement totals.'],
    db: ['Reconcile sources', 'ledger_journals\nledger_entries\npolaris_accounts\nloans\nrepayment_schedules\nmerchant_settlements'],
    api: ['Polaris reporting', 'gen/getTmwJournalList\ngen/getAccountStatement\naccount detail APIs'],
    control: ['If mismatch', 'Mark mismatched/dead_letter, create audit log for business impact, send finance work item.'],
    branch: 'No: investigate',
    cont: 'Matched',
  },
  {
    ui: ['All services', 'Write observability records around business events and integrations.'],
    app: ['Which log type?', 'Business/security/financial status change -> audit. Runtime event -> system log. Polaris call -> API/attempt. Money -> ledger.'],
    db: ['Universal logging', 'audit_logs\nsystem_event_logs\npolaris_api_logs\npolaris_operation_attempts\nledger_journals\nledger_entries'],
    api: ['No extra call', 'Logs reference request id, correlation id, idempotency key, jrno, account and source entity.'],
    control: ['Audit evidence', 'Every status transition has audit_logs.operation_type = status_change; every money movement has ledger journal.'],
    branch: 'N/A',
    cont: 'Logged',
  },
  {
    ui: ['Staff / auditor', 'Read reports, export statements or inspect sensitive customer/merchant data.'],
    app: ['Sensitive read/export?', 'Use reporting views and permission checks; record business-level read_sensitive/export audit event.'],
    db: ['Reporting views', 'v_status_transition_audit\nv_polaris_reconciliation_worklist\naudit_logs\nledger_journals\nrepayment and settlement views'],
    api: ['Optional validation query', 'Polaris statement query for finance report verification when required.'],
    control: ['Compliance result', 'Export is traceable by actor, filter, reason, correlation id and generated artifact metadata.'],
    branch: 'Denied: audit',
    cont: 'Exported',
  },
];

function esc(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function wrap(text, maxChars) {
  const out = [];
  for (const raw of String(text || '').split('\n')) {
    let line = '';
    for (const word of raw.split(/\s+/)) {
      if (!word) continue;
      const next = line ? `${line} ${word}` : word;
      if (next.length > maxChars && line) {
        out.push(line);
        line = word;
      } else {
        line = next;
      }
    }
    if (line) out.push(line);
  }
  return out.length ? out : [''];
}

function nodeHeight(node, maxChars, base = 72) {
  if (!node) return 0;
  const body = wrap(node[1], maxChars);
  return Math.max(126, base + body.length * 23);
}

function rowHeight(row) {
  return Math.max(
    nodeHeight(row.ui, 28),
    row.app?.[2] === 'decision' ? Math.max(174, nodeHeight(row.app, 33, 88)) : nodeHeight(row.app, 35),
    nodeHeight(row.db, 31),
    nodeHeight(row.api, 34),
    nodeHeight(row.control, 32),
  );
}

let y = startY;
let currentSection = null;
const models = rows.map((row, idx) => {
  if (row.section && row.section[0] !== currentSection) {
    y += currentSection ? sectionGap : 0;
    row.sectionY = y;
    y += 78;
    currentSection = row.section[0];
  }
  const h = rowHeight(row);
  const model = { row, idx, y, h };
  y += h + rowGap;
  return model;
});
const H = y + 170;

function textBlock(lines, x, y, cls, lineH = 23, anchor = 'start') {
  return lines.map((line, i) => `<text x="${x}" y="${y + i * lineH}" class="${cls}" text-anchor="${anchor}">${esc(line)}</text>`).join('\n');
}

function titleBodyNode(lane, y, h, node, opts = {}) {
  if (!node) return '';
  const [title, body] = node;
  const tx = lane.x;
  const tw = lane.w;
  const fill = opts.fill || '#ffffff';
  const stroke = opts.stroke || lane.color;
  const lines = wrap(body, opts.maxChars || 32);
  return `<g filter="url(#shadow)">
    <rect x="${tx}" y="${y}" width="${tw}" height="${h}" rx="22" ry="22" fill="${fill}" stroke="${stroke}" stroke-width="${opts.strong ? 3 : 1.8}"/>
    <rect x="${tx}" y="${y}" width="${tw}" height="42" rx="22" ry="22" fill="${stroke}" opacity="0.12"/>
    <text x="${tx + 24}" y="${y + 29}" class="nodeTitle">${esc(title)}</text>
    ${textBlock(lines, tx + 24, y + 67, 'nodeBody')}
  </g>`;
}

function dbNode(lane, y, h, node) {
  const [title, body] = node;
  const tx = lane.x;
  const tw = lane.w;
  const lines = wrap(body, 31);
  const topY = y + 18;
  const bottomY = y + h - 18;
  return `<g filter="url(#shadow)">
    <path d="M${tx},${topY} C${tx},${y - 2} ${tx + tw},${y - 2} ${tx + tw},${topY} L${tx + tw},${bottomY} C${tx + tw},${y + h + 4} ${tx},${y + h + 4} ${tx},${bottomY} Z" fill="#eef2ff" stroke="#4f46e5" stroke-width="1.9"/>
    <ellipse cx="${tx + tw / 2}" cy="${topY}" rx="${tw / 2}" ry="20" fill="#f8faff" stroke="#4f46e5" stroke-width="1.9"/>
    <path d="M${tx},${bottomY} C${tx},${y + h + 4} ${tx + tw},${y + h + 4} ${tx + tw},${bottomY}" fill="none" stroke="#4f46e5" stroke-width="1.5"/>
    <text x="${tx + tw / 2}" y="${y + 32}" class="dbTitle" text-anchor="middle">${esc(title)}</text>
    ${textBlock(lines, tx + 28, y + 70, 'nodeBody')}
  </g>`;
}

function apiNode(lane, y, h, node) {
  const [title, body] = node;
  const tx = lane.x;
  const tw = lane.w;
  const cut = 44;
  const lines = wrap(body, 34);
  return `<g filter="url(#shadow)">
    <polygon points="${tx + cut},${y} ${tx + tw - cut},${y} ${tx + tw},${y + h / 2} ${tx + tw - cut},${y + h} ${tx + cut},${y + h} ${tx},${y + h / 2}" fill="#ecfeff" stroke="#0891b2" stroke-width="1.9"/>
    <text x="${tx + 56}" y="${y + 34}" class="nodeTitle">${esc(title)}</text>
    ${textBlock(lines, tx + 56, y + 72, 'nodeBody')}
  </g>`;
}

function decisionNode(lane, y, h, node) {
  const [title, body] = node;
  const tx = lane.x + 28;
  const tw = lane.w - 56;
  const cx = tx + tw / 2;
  const cy = y + h / 2;
  const lines = wrap(body, 33).slice(0, 5);
  return `<g filter="url(#shadow)">
    <polygon points="${cx},${y} ${tx + tw},${cy} ${cx},${y + h} ${tx},${cy}" fill="#fffbeb" stroke="#d97706" stroke-width="2.4"/>
    <text x="${cx}" y="${cy - 29}" class="decisionTitle" text-anchor="middle">${esc(title)}</text>
    ${textBlock(lines, cx, cy + 5, 'decisionBody', 22, 'middle')}
  </g>`;
}

function arrow(x1, y1, x2, y2, opts = {}) {
  const color = opts.color || '#64748b';
  const sw = opts.width || 2.4;
  const dash = opts.dash ? ` stroke-dasharray="${opts.dash}"` : '';
  const marker = opts.noMarker ? '' : ' marker-end="url(#arrow)"';
  const midX = (x1 + x2) / 2;
  const path = Math.abs(y1 - y2) < 8
    ? `M${x1},${y1} L${x2},${y2}`
    : `M${x1},${y1} C${midX},${y1} ${midX},${y2} ${x2},${y2}`;
  const label = opts.label
    ? `<rect x="${(x1 + x2) / 2 - 92}" y="${(y1 + y2) / 2 - 24}" width="184" height="28" rx="14" fill="#ffffff" stroke="${color}" stroke-width="1"/>
       <text x="${(x1 + x2) / 2}" y="${(y1 + y2) / 2 - 5}" class="edgeLabel" text-anchor="middle" fill="${color}">${esc(opts.label)}</text>`
    : '';
  return `<path d="${path}" fill="none" stroke="${color}" stroke-width="${sw}"${dash}${marker}/>${label}`;
}

function verticalArrow(x, y1, y2, label) {
  const labelSvg = label
    ? `<rect x="${x + 22}" y="${(y1 + y2) / 2 - 20}" width="156" height="28" rx="14" fill="#ffffff" stroke="#94a3b8" stroke-width="1"/>
       <text x="${x + 100}" y="${(y1 + y2) / 2 - 1}" class="edgeLabel" text-anchor="middle" fill="#64748b">${esc(label)}</text>`
    : '';
  return `<path d="M${x},${y1} L${x},${y2}" fill="none" stroke="#94a3b8" stroke-width="3.2" marker-end="url(#arrow)"/>${labelSvg}`;
}

function sectionBand(section, y) {
  const colors = {
    Foundation: ['#0f172a', '#164e63'],
    'Customer Onboarding': ['#1d4ed8', '#2563eb'],
    'Limit and Line': ['#047857', '#059669'],
    'Loan and BNPL Drawdown': ['#c2410c', '#ea580c'],
    'Repayment and Closing': ['#059669', '#10b981'],
    'Settlement, Refund and Reversal': ['#92400e', '#a16207'],
    'Reconciliation and Governance': ['#334155', '#475569'],
  };
  const [c1, c2] = colors[section[0]] || ['#334155', '#475569'];
  return `<g filter="url(#softShadow)">
    <linearGradient id="sec_${section[0].replace(/[^a-zA-Z0-9]/g, '_')}" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0%" stop-color="${c1}"/>
      <stop offset="100%" stop-color="${c2}"/>
    </linearGradient>
    <rect x="${margin}" y="${y}" width="${W - margin * 2}" height="58" rx="20" ry="20" fill="url(#sec_${section[0].replace(/[^a-zA-Z0-9]/g, '_')})"/>
    <text x="${margin + 28}" y="${y + 37}" class="sectionTitle">${esc(section[0])}</text>
    <text x="${margin + 470}" y="${y + 37}" class="sectionSub">${esc(section[1])}</text>
  </g>`;
}

const out = [];
out.push(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0%" stop-color="#eef6ff"/>
    <stop offset="48%" stop-color="#f8fafc"/>
    <stop offset="100%" stop-color="#ecfdf5"/>
  </linearGradient>
  <linearGradient id="hero" x1="0" y1="0" x2="1" y2="0">
    <stop offset="0%" stop-color="#020617"/>
    <stop offset="50%" stop-color="#164e63"/>
    <stop offset="100%" stop-color="#14532d"/>
  </linearGradient>
  <pattern id="grid" width="52" height="52" patternUnits="userSpaceOnUse">
    <path d="M52 0H0V52" fill="none" stroke="#cbd5e1" stroke-width="1" opacity="0.28"/>
  </pattern>
  <marker id="arrow" markerWidth="14" markerHeight="14" refX="11" refY="7" orient="auto" markerUnits="strokeWidth">
    <path d="M2,2 L12,7 L2,12 Z" fill="#64748b"/>
  </marker>
  <filter id="shadow" x="-5%" y="-12%" width="112%" height="136%">
    <feDropShadow dx="0" dy="7" stdDeviation="8" flood-color="#0f172a" flood-opacity="0.13"/>
  </filter>
  <filter id="softShadow" x="-3%" y="-16%" width="106%" height="144%">
    <feDropShadow dx="0" dy="5" stdDeviation="5" flood-color="#0f172a" flood-opacity="0.12"/>
  </filter>
  <style>
    text { font-family: Arial, Helvetica, sans-serif; letter-spacing: 0; }
    .heroTitle { font-size: 56px; font-weight: 800; fill: #ffffff; }
    .heroSub { font-size: 22px; fill: #dbeafe; }
    .heroTag { font-size: 18px; font-weight: 800; fill: #bbf7d0; }
    .laneTitle { font-size: 24px; font-weight: 800; fill: #0f172a; }
    .laneSub { font-size: 16px; fill: #475569; }
    .laneCode { font-size: 20px; font-weight: 800; fill: #ffffff; }
    .sectionTitle { font-size: 27px; font-weight: 800; fill: #ffffff; }
    .sectionSub { font-size: 18px; fill: #e2e8f0; }
    .nodeTitle { font-size: 20px; font-weight: 800; fill: #0f172a; }
    .dbTitle { font-size: 20px; font-weight: 800; fill: #312e81; }
    .nodeBody { font-size: 18px; fill: #334155; }
    .decisionTitle { font-size: 21px; font-weight: 800; fill: #92400e; }
    .decisionBody { font-size: 17px; fill: #78350f; }
    .edgeLabel { font-size: 15px; font-weight: 800; }
    .legendTitle { font-size: 20px; font-weight: 800; fill: #0f172a; }
    .legendText { font-size: 17px; fill: #475569; }
    .stepNo { font-size: 24px; font-weight: 800; fill: #ffffff; }
  </style>
</defs>
<rect width="${W}" height="${H}" fill="url(#bg)"/>
<rect width="${W}" height="${H}" fill="url(#grid)"/>
<rect x="56" y="48" width="${W - 112}" height="${H - 96}" rx="42" fill="#ffffff" opacity="0.9" stroke="#dbe3ee" stroke-width="2"/>
<g filter="url(#shadow)">
  <rect x="${margin}" y="86" width="${W - margin * 2}" height="${headerH - 80}" rx="34" fill="url(#hero)"/>
  <text x="${margin + 44}" y="150" class="heroTitle">Polaris Lending Conditional Flow Chart</text>
  <text x="${margin + 46}" y="196" class="heroSub">Direct-core flow with no LOS: UI triggers, app decisions, database state, Polaris/external calls, and failure/reconciliation branches.</text>
  <text x="${W - margin - 44}" y="150" class="heroTag" text-anchor="end">Double-spend aware | Idempotent | Pending reconcile on timeout | One reversal per jrno</text>
  <text x="${W - margin - 44}" y="196" class="heroSub" text-anchor="end">${rows.length} conditional operations</text>
</g>`);

Object.values(lanes).forEach((lane) => {
  out.push(`<g filter="url(#softShadow)">
    <rect x="${lane.x}" y="${laneTop}" width="${lane.w}" height="${laneH}" rx="24" fill="#ffffff" stroke="#dbe3ee" stroke-width="1.8"/>
    <circle cx="${lane.x + 52}" cy="${laneTop + 48}" r="30" fill="${lane.color}"/>
    <text x="${lane.x + 52}" y="${laneTop + 56}" text-anchor="middle" class="laneCode">${esc(lane.code)}</text>
    <text x="${lane.x + 96}" y="${laneTop + 40}" class="laneTitle">${esc(lane.title)}</text>
    <text x="${lane.x + 96}" y="${laneTop + 67}" class="laneSub">${esc(lane.sub)}</text>
  </g>`);
});

models.forEach((model, i) => {
  const { row } = model;
  if (row.section) out.push(sectionBand(row.section, row.sectionY));

  const y0 = model.y;
  const h = model.h;
  const centerY = y0 + h / 2;

  out.push(`<g filter="url(#softShadow)">
    <rect x="${margin}" y="${y0 - 16}" width="${W - margin * 2}" height="${h + 32}" rx="30" fill="#f8fafc" stroke="#e2e8f0" stroke-width="1.2"/>
    <circle cx="${margin + 42}" cy="${centerY}" r="34" fill="${row.section ? '#0f172a' : '#334155'}" opacity="0.92"/>
    <text x="${margin + 42}" y="${centerY + 9}" text-anchor="middle" class="stepNo">${String(i + 1).padStart(2, '0')}</text>
  </g>`);

  const uiH = Math.min(h, nodeHeight(row.ui, 28));
  const appH = row.app?.[2] === 'decision' ? Math.max(174, Math.min(h, nodeHeight(row.app, 33, 90))) : Math.min(h, nodeHeight(row.app, 35));
  const dbH = Math.min(h, nodeHeight(row.db, 31));
  const apiH = Math.min(h, nodeHeight(row.api, 34));
  const ctlH = Math.min(h, nodeHeight(row.control, 32));
  const uiY = y0 + (h - uiH) / 2;
  const appY = y0 + (h - appH) / 2;
  const dbY = y0 + (h - dbH) / 2;
  const apiY = y0 + (h - apiH) / 2;
  const ctlY = y0 + (h - ctlH) / 2;

  out.push(titleBodyNode(lanes.ui, uiY, uiH, row.ui, { maxChars: 28, fill: '#eff6ff', stroke: '#2563eb' }));
  out.push(row.app?.[2] === 'decision'
    ? decisionNode(lanes.app, appY, appH, row.app)
    : titleBodyNode(lanes.app, appY, appH, row.app, { maxChars: 35, fill: '#ffffff', stroke: '#0f172a', strong: true }));
  out.push(dbNode(lanes.db, dbY, dbH, row.db));
  out.push(apiNode(lanes.api, apiY, apiH, row.api));
  out.push(titleBodyNode(lanes.control, ctlY, ctlH, row.control, {
    maxChars: 32,
    fill: row.branch?.toLowerCase().includes('timeout') || row.branch?.toLowerCase().includes('ambiguous') ? '#fffbeb' : '#f0fdf4',
    stroke: row.branch?.toLowerCase().includes('timeout') || row.branch?.toLowerCase().includes('ambiguous') ? '#d97706' : '#15803d',
  }));

  out.push(arrow(lanes.ui.x + lanes.ui.w, centerY, lanes.app.x - 18, centerY, { color: '#94a3b8' }));
  out.push(arrow(lanes.app.x + lanes.app.w, centerY, lanes.db.x - 18, centerY, { color: '#94a3b8', label: row.cont || 'OK' }));
  out.push(arrow(lanes.db.x + lanes.db.w, centerY, lanes.api.x - 18, centerY, { color: '#818cf8' }));
  out.push(arrow(lanes.api.x + lanes.api.w, centerY, lanes.control.x - 18, centerY, { color: '#0891b2', label: row.branch || '' }));

  const next = models[i + 1];
  if (next) {
    const spineX = lanes.app.x + lanes.app.w / 2;
    out.push(verticalArrow(spineX, y0 + h + 6, next.y - 24, row.cont && row.app?.[2] === 'decision' ? row.cont : 'next'));
  }
});

const legendY = H - 108;
out.push(`<g filter="url(#softShadow)">
  <rect x="${margin}" y="${legendY - 18}" width="${W - margin * 2}" height="58" rx="20" fill="#ffffff" stroke="#cbd5e1" stroke-width="1.4"/>
  <text x="${margin + 28}" y="${legendY + 17}" class="legendTitle">Legend:</text>
  <text x="${margin + 142}" y="${legendY + 17}" class="legendText">Rounded box = process/response, diamond = decision, cylinder = database state, hexagon = Polaris/external integration. Timeout means pending_reconcile, not failed. Retrying a write reuses the same idempotency key after statement/journal search.</text>
</g>`);

out.push('</svg>\n');

fs.writeFileSync(svgPath, out.join('\n'));
console.log(svgPath);
