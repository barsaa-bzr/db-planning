#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const outDir = '/Users/barsaa/Projects/planning';
const svgPath = path.join(outDir, 'lending_polaris_clear_process_map.svg');

const W = 3000;
const H = 3000;
const bg = '#f8fafc';

const stages = [
  {
    n: '01',
    title: 'Configuration + Merchant Setup',
    text: 'Admin configures product/transaction codes and merchant/POS accounts before any customer operation.',
    db: 'polaris_product_configs\npolaris_transaction_configs\npolaris_dynamic_field_mappings\nmerchant_profiles, pos_terminals\npolaris_accounts',
    api: 'Merchant APIs\ntmm/insertMerchant\ntsd/createTsdTerminal\ntmm/insertTmmMerchantTermnl',
    color: '#0ea5e9',
    section: 'Foundation',
  },
  {
    n: '02',
    title: 'Customer Registration + Authentication',
    text: 'Customer registers, verifies OTP, logs in, and creates transaction authorization factors.',
    db: 'users\ncustomer_profiles\notp_sessions, user_sessions\ncustomer_pin_credentials\ncustomer_biometric_credentials',
    api: 'OTP / message provider\nSMS or push delivery\nlogin / transaction auth',
    color: '#2563eb',
    section: 'Customer onboarding',
  },
  {
    n: '03',
    title: 'DAN Authorization + KYC Capture',
    text: 'Customer authorizes identity lookup; app stores structured KYC, files, contacts, and review state.',
    db: 'dan_verifications\nkyc_personal_details\nkyc_addresses, kyc_contact_infos\nkyc_customer_files\nhur_data_snapshots',
    api: 'DAN identity authority\nHUR government data services\nidentity, income, employment snapshots',
    color: '#7c3aed',
    section: 'Customer onboarding',
  },
  {
    n: '04',
    title: 'Polaris CIF + Customer Deposit Account',
    text: 'System creates/updates customer in Polaris and creates the customer CASA/deposit account used for grants and repayments.',
    db: 'customer_profiles.polaris_cust_code\ncustomer_deposit_accounts\npolaris_accounts\npolaris_sync_queue\npolaris_operation_attempts',
    api: 'cif/createPerson\ncif/updatePerson\ncasa/createAccount\ncasa/openAccountStatus',
    color: '#0891b2',
    section: 'Customer onboarding',
  },
  {
    n: '05',
    title: 'Credit Scoring + Polaris Risk Field Sync',
    text: 'Risk engine stores FICO, custom score, model version, factors, final grade, and syncs score fields to Polaris.',
    db: 'sain_score_requests\ncredit_score_results\ncredit_scoring_factors\nloan_limits draft inputs\naudit_logs',
    api: 'Sain / FICO scoring\ncif/updatePerson dynamicData\nrisk field mappings from config',
    color: '#a16207',
    section: 'Risk and limit',
  },
  {
    n: '06',
    title: 'Loan Limit + Polaris Line Account',
    text: 'Local limit becomes active, then a Polaris line account is created/opened using custCode, deposit acntCode, and product config.',
    db: 'loan_limits\ncredit_line_accounts\ncustomer_deposit_accounts\npolaris_accounts\ncredit_limit_reservations',
    api: 'line/createAccount\nline/openAccount\nline/adjustLineAccountLimit\nline/getAccountDetail on timeout',
    color: '#16a34a',
    section: 'Risk and limit',
  },
  {
    n: '07',
    title: 'Loan Start: One-tap Application or BNPL Invoice',
    text: 'Customer starts a one-tap loan or scans a merchant BNPL QR. The app validates KYC, active deposit, active line, and product terms.',
    db: 'loan_applications\npos_payment_invoices\npos_qr_codes\npos_transactions\nloan_products',
    api: 'Merchant POS terminal\nQR display and scan\nPOS invoice lifecycle',
    color: '#0284c7',
    section: 'Loan drawdown',
  },
  {
    n: '08',
    title: 'Reserve Limit + Approve or Reject',
    text: 'Line row is locked; requested amount is reserved before approval. Rejection/cancel releases reservation.',
    db: 'credit_line_accounts\ncredit_limit_reservations\nloan_applications status\noptional loan_contracts\naudit_logs',
    api: 'No Polaris money movement yet\nlocal validation and staff/system decision',
    color: '#dc2626',
    section: 'Loan drawdown',
  },
  {
    n: '09',
    title: 'Create/Open Child Loan Account',
    text: 'Loan core starts only after reservation. Child loan account is created/opened in Polaris and stored locally.',
    db: 'loans\nloan_core_steps\npolaris_accounts\npolaris_sync_queue\npolaris_api_logs',
    api: 'loan/createAccount\nloan/openAccount\nloan/getAccountDetail before retry',
    color: '#ea580c',
    section: 'Loan drawdown',
  },
  {
    n: '10',
    title: 'Calculate/Create Schedule + Link to Line',
    text: 'Repayment schedule is calculated and created in Polaris; child loan is linked to the line before any grant.',
    db: 'repayment_schedules\nloans.schedule_status\nloans.line_link_status\nloan_core_steps\naudit_logs',
    api: 'loan/calculateNrsSchedule\nloan/createNrsSchedule\nline/linkLineAccountToLoan',
    color: '#ea580c',
    section: 'Loan drawdown',
  },
  {
    n: '11',
    title: 'Grant Loan to Customer Deposit',
    text: 'Money movement is posted in Polaris: child loan account to the customer deposit account. Local ledger stores jrno.',
    db: 'loans.grant_status\nloans.grant_polaris_jrno\nledger_journals\nledger_entries\ncredit_limit_reservations consumed',
    api: 'loan/grantLoanNonCash\nchild loan account -> customer deposit\nreturns Polaris jrno',
    color: '#ea580c',
    section: 'Loan drawdown',
  },
  {
    n: '12',
    title: 'BNPL Merchant Transfer (BNPL only)',
    text: 'For BNPL, customer deposit is transferred to merchant passive account. POS approval is sent only after confirmed transfer.',
    db: 'pos_transactions\nmerchant_settlement_items\npos_terminal_callbacks\nledger_journals\nloans.bnpl_merchant_transfer_status',
    api: 'tllrcasa/internalCasaTransaction\ncustomer deposit -> merchant passive\nPOS approved/rejected callback',
    color: '#65a30d',
    section: 'BNPL settlement',
  },
  {
    n: '13',
    title: 'Repayment Inbound + Loan Payment',
    text: 'Real repayment money arrives first to customer deposit, then customer deposit pays the loan account.',
    db: 'qpay_repayment_invoices\nqpay_repayment_callbacks\nrepayment_transactions\nledger_journals\npolaris_accounts',
    api: 'QPay invoice + callback\ntllrbac/transactionBacToCasa or configured inbound\nloan/nonCashLoanPayment',
    color: '#16a34a',
    section: 'Repayment and close',
  },
  {
    n: '14',
    title: 'Allocate Repayment + Close Loan',
    text: 'Schedules are locked before allocation. Final payment checks closing details, closes loan account, and reduces line utilization.',
    db: 'repayment_schedules\nrepayment_allocations\nloans status\ncredit_line_accounts utilized\nledger_journals',
    api: 'loan/getLoanClosingAccountDetail\nloan/nonCashCloseAccount\naccount detail verification',
    color: '#16a34a',
    section: 'Repayment and close',
  },
  {
    n: '15',
    title: 'Reconciliation, Reversal, Audit + Reporting',
    text: 'Daily reconciliation proves Polaris truth, resolves pending_reconcile, handles reversals, reports and sensitive exports.',
    db: 'audit_logs\nsystem_event_logs\npolaris_api_logs\npolaris_operation_attempts\nv_polaris_reconciliation_worklist',
    api: 'gen/getTmwJournalList\ngen/getAccountStatement\ngen/doReverseTxn\ngen/undoTransaction',
    color: '#475569',
    section: 'Reconciliation',
  },
];

function esc(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function wrap(text, max) {
  const result = [];
  for (const part of String(text).split('\n')) {
    let line = '';
    for (const word of part.split(/\s+/)) {
      if (!word) continue;
      const next = line ? `${line} ${word}` : word;
      if (next.length > max && line) {
        result.push(line);
        line = word;
      } else {
        line = next;
      }
    }
    if (line) result.push(line);
  }
  return result;
}

function textBlock(text, x, y, w, cls, max, lineH, anchor = 'middle') {
  return wrap(text, max).map((l, i) => {
    const tx = anchor === 'middle' ? x + w / 2 : x;
    return `<text x="${tx}" y="${y + i * lineH}" text-anchor="${anchor}" class="${cls}">${esc(l)}</text>`;
  }).join('\n');
}

function card({ x, y, w, h, fill, stroke, title, body, cls = 'smallText', titleCls = 'cardTitle', radius = 18 }) {
  return `<g filter="url(#shadow)">
    <rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${radius}" ry="${radius}" fill="${fill}" stroke="${stroke}" stroke-width="2"/>
    ${textBlock(title, x + 18, y + 30, w - 36, titleCls, 42, 18)}
    ${textBlock(body, x + 22, y + 62, w - 44, cls, 42, 16)}
  </g>`;
}

function dbCard(stage, x, y) {
  return `<g filter="url(#shadow)">
    <path d="M${x},${y + 18} C${x},${y - 4} ${x + 710},${y - 4} ${x + 710},${y + 18} L${x + 710},${y + 120} C${x + 710},${y + 142} ${x},${y + 142} ${x},${y + 120} Z M${x},${y + 18} C${x},${y + 40} ${x + 710},${y + 40} ${x + 710},${y + 18}" fill="#ffffff" stroke="#64748b" stroke-width="2"/>
    <circle cx="${x + 34}" cy="${y + 23}" r="14" fill="#e2e8f0" stroke="#64748b"/>
    <text x="${x + 34}" y="${y + 28}" text-anchor="middle" class="miniNumber">${stage.n}</text>
    <text x="${x + 70}" y="${y + 32}" class="dbTitle">${esc(stage.title)}</text>
    ${textBlock(stage.db, x + 36, y + 62, 650, 'dbText', 45, 15, 'start')}
  </g>`;
}

function apiCard(stage, x, y) {
  return `<g filter="url(#shadow)">
    <rect x="${x}" y="${y}" width="710" height="140" rx="18" ry="18" fill="#ecfeff" stroke="#0891b2" stroke-width="2"/>
    <circle cx="${x + 34}" cy="${y + 32}" r="14" fill="#cffafe" stroke="#0891b2"/>
    <text x="${x + 34}" y="${y + 37}" text-anchor="middle" class="miniNumber">${stage.n}</text>
    <text x="${x + 70}" y="${y + 36}" class="apiTitle">${esc(stage.title)}</text>
    ${textBlock(stage.api, x + 36, y + 66, 650, 'apiText', 48, 15, 'start')}
  </g>`;
}

function processCard(stage, x, y) {
  const sectionLabel = stage.section.toUpperCase();
  return `<g filter="url(#shadow)">
    <rect x="${x}" y="${y}" width="820" height="140" rx="22" ry="22" fill="#ffffff" stroke="${stage.color}" stroke-width="2.8"/>
    <rect x="${x}" y="${y}" width="82" height="140" rx="22" ry="22" fill="${stage.color}" stroke="${stage.color}" stroke-width="2.8"/>
    <text x="${x + 41}" y="${y + 62}" text-anchor="middle" class="stepNumber">${stage.n}</text>
    <text x="${x + 41}" y="${y + 88}" text-anchor="middle" class="stepWord">STEP</text>
    <text x="${x + 112}" y="${y + 35}" class="processTitle">${esc(stage.title)}</text>
    <rect x="${x + 112}" y="${y + 50}" width="190" height="24" rx="8" ry="8" fill="${stage.color}" opacity="0.12"/>
    <text x="${x + 126}" y="${y + 67}" class="sectionText" fill="${stage.color}">${esc(sectionLabel)}</text>
    ${textBlock(stage.text, x + 112, y + 94, 670, 'processText', 76, 17, 'start')}
  </g>`;
}

function edge(x1, y1, x2, y2, color = '#334155', dashed = false, marker = 'arrow') {
  const dx = Math.abs(x2 - x1);
  const my = (y1 + y2) / 2;
  const mx = (x1 + x2) / 2;
  const d = dx < 30
    ? `M${x1},${y1} C${x1},${my} ${x2},${my} ${x2},${y2}`
    : `M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}`;
  return `<path d="${d}" fill="none" stroke="${color}" stroke-width="2.2" ${dashed ? 'stroke-dasharray="9 7"' : ''} marker-end="url(#${marker})"/>`;
}

const processX = 1090;
const dbX = 80;
const apiX = 2210;
const startY = 380;
const gap = 153;
const pH = 140;
const pW = 820;

const parts = [];

parts.push(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
  <defs>
    <marker id="arrow" markerWidth="14" markerHeight="14" refX="11" refY="7" orient="auto" markerUnits="strokeWidth">
      <path d="M2,2 L12,7 L2,12 Z" fill="#334155"/>
    </marker>
    <marker id="blueArrow" markerWidth="14" markerHeight="14" refX="11" refY="7" orient="auto" markerUnits="strokeWidth">
      <path d="M2,2 L12,7 L2,12 Z" fill="#0891b2"/>
    </marker>
    <marker id="redArrow" markerWidth="14" markerHeight="14" refX="11" refY="7" orient="auto" markerUnits="strokeWidth">
      <path d="M2,2 L12,7 L2,12 Z" fill="#dc2626"/>
    </marker>
    <filter id="shadow" x="-8%" y="-8%" width="116%" height="122%">
      <feDropShadow dx="0" dy="8" stdDeviation="8" flood-color="#0f172a" flood-opacity="0.11"/>
    </filter>
    <style>
      .title { font: 800 36px Arial, sans-serif; fill: #0f172a; }
      .subtitle { font: 16px Arial, sans-serif; fill: #475569; }
      .columnTitle { font: 800 18px Arial, sans-serif; fill: #0f172a; }
      .cardTitle { font: 800 15px Arial, sans-serif; fill: #0f172a; }
      .smallText { font: 13px Arial, sans-serif; fill: #334155; }
      .dbTitle { font: 800 13px Arial, sans-serif; fill: #334155; }
      .dbText { font: 12px Arial, sans-serif; fill: #475569; }
      .apiTitle { font: 800 13px Arial, sans-serif; fill: #0e7490; }
      .apiText { font: 12px Arial, sans-serif; fill: #155e75; }
      .miniNumber { font: 800 11px Arial, sans-serif; fill: #0f172a; }
      .stepNumber { font: 800 31px Arial, sans-serif; fill: #ffffff; }
      .stepWord { font: 800 10px Arial, sans-serif; fill: #ffffff; opacity: 0.88; }
      .processTitle { font: 800 19px Arial, sans-serif; fill: #0f172a; }
      .processText { font: 14px Arial, sans-serif; fill: #334155; }
      .sectionText { font: 800 10px Arial, sans-serif; }
      .controlTitle { font: 800 15px Arial, sans-serif; fill: #7f1d1d; }
      .controlText { font: 12.5px Arial, sans-serif; fill: #7f1d1d; }
      .legend { font: 13px Arial, sans-serif; fill: #475569; }
    </style>
  </defs>
  <rect width="${W}" height="${H}" fill="${bg}"/>
  <rect x="44" y="44" width="${W - 88}" height="${H - 88}" rx="30" ry="30" fill="#ffffff" stroke="#e2e8f0" stroke-width="2"/>
  <text x="${W / 2}" y="92" text-anchor="middle" class="title">Direct Polaris Lending Flow: Process + Database + External Integrations</text>
  <text x="${W / 2}" y="124" text-anchor="middle" class="subtitle">Clear lifecycle map for no-LOS lending and BNPL. Center is the operation flow; left shows tables written/read; right shows API calls; bottom shows failure and double-spend controls.</text>
`);

parts.push(card({
  x: 120,
  y: 160,
  w: 620,
  h: 104,
  fill: '#dbeafe',
  stroke: '#2563eb',
  title: 'UI actors',
  body: 'Admin / Back-office  |  Customer Mobile App  |  Merchant POS / Portal  |  Finance Ops / Audit UI',
  cls: 'smallText',
}));
parts.push(card({
  x: 820,
  y: 160,
  w: 620,
  h: 104,
  fill: '#fff7ed',
  stroke: '#ea580c',
  title: 'Backend process layer',
  body: 'Auth, KYC orchestration, scoring, limit/line manager, loan core orchestrator, BNPL processor, repayment processor, reconciliation scheduler',
}));
parts.push(card({
  x: 1520,
  y: 160,
  w: 620,
  h: 104,
  fill: '#ecfeff',
  stroke: '#0891b2',
  title: 'External systems',
  body: 'DAN, HUR, Sain/FICO, QPay, Merchant POS, Polaris CIF/CASA/LINE/LOAN/TXN/GEN APIs',
}));
parts.push(card({
  x: 2220,
  y: 160,
  w: 620,
  h: 104,
  fill: '#fee2e2',
  stroke: '#dc2626',
  title: 'Control policy',
  body: 'Idempotency, outbox, pending_reconcile, ledger journals, audit_logs, duplicate callback guard, schedule locks, one reversal per jrno',
  cls: 'controlText',
  titleCls: 'controlTitle',
}));

parts.push(`<text x="${dbX + 355}" y="342" text-anchor="middle" class="columnTitle">DATABASE TABLE NODES</text>`);
parts.push(`<text x="${processX + 410}" y="342" text-anchor="middle" class="columnTitle">PROCESS FLOW</text>`);
parts.push(`<text x="${apiX + 355}" y="342" text-anchor="middle" class="columnTitle">EXTERNAL INTEGRATION / API NODES</text>`);
parts.push(`<rect x="58" y="360" width="764" height="2530" rx="22" ry="22" fill="#f8fafc" stroke="#e2e8f0"/>`);
parts.push(`<rect x="1030" y="360" width="940" height="2530" rx="22" ry="22" fill="#fff7ed" stroke="#fed7aa"/>`);
parts.push(`<rect x="2188" y="360" width="764" height="2530" rx="22" ry="22" fill="#ecfeff" stroke="#a5f3fc"/>`);

for (let i = 0; i < stages.length; i++) {
  const y = startY + i * gap;
  parts.push(edge(processX + pW / 2, y + pH, processX + pW / 2, y + gap, '#334155', false, 'arrow'));
}

for (let i = 0; i < stages.length - 1; i++) {
  const y = startY + i * gap + pH + 14;
  parts.push(`<circle cx="${processX + pW / 2}" cy="${y}" r="8" fill="#ffffff" stroke="#334155" stroke-width="2"/>`);
}

stages.forEach((stage, i) => {
  const y = startY + i * gap;
  const cy = y + pH / 2;
  parts.push(dbCard(stage, dbX, y));
  parts.push(processCard(stage, processX, y));
  parts.push(apiCard(stage, apiX, y));
  parts.push(edge(dbX + 710, cy, processX, cy, '#64748b', true, 'arrow'));
  parts.push(edge(processX + pW, cy, apiX, cy, '#0891b2', false, 'blueArrow'));
});

const grantY = startY + 10 * gap;
const repayY = startY + 12 * gap;
parts.push(`<path d="M${processX + pW - 18},${grantY + 126} C${processX + pW + 170},${grantY + 250} ${processX + pW + 170},${repayY - 70} ${processX + pW - 18},${repayY + 14}" fill="none" stroke="#16a34a" stroke-width="2.5" stroke-dasharray="10 8" marker-end="url(#arrow)"/>`);
parts.push(`<text x="${processX + pW + 210}" y="${grantY + 236}" text-anchor="middle" class="legend">one-tap skips BNPL transfer</text>`);

const controlY = 2735;
parts.push(`<text x="${W / 2}" y="${controlY - 45}" text-anchor="middle" class="columnTitle">SAFETY CONTROLS USED ACROSS THE FLOW</text>`);
const controls = [
  ['Idempotency', 'Stable key per operation. Retry after timeout must reuse the same key.', '#fee2e2'],
  ['Outbox / saga', 'Every Polaris write call goes through polaris_sync_queue and operation attempts.', '#fee2e2'],
  ['Unknown result', 'Timeout means pending_reconcile. Query journals/statements before retry.', '#fee2e2'],
  ['Double-spend prevention', 'Line reservation, POS invoice lock, QPay duplicate guard, schedule allocation lock.', '#fee2e2'],
  ['Audit and ledger truth', 'Status changes in audit_logs; runtime events in system_event_logs; money facts in ledger_journals.', '#fee2e2'],
];
controls.forEach(([title, body, fill], i) => {
  parts.push(card({
    x: 100 + i * 560,
    y: controlY,
    w: 500,
    h: 138,
    fill,
    stroke: '#dc2626',
    title,
    body,
    cls: 'controlText',
    titleCls: 'controlTitle',
    radius: 18,
  }));
});

parts.push(`<text x="${W / 2}" y="${H - 70}" text-anchor="middle" class="legend">Status rules: failed = confirmed failure | pending_reconcile = unknown Polaris result | dead_letter = unresolved automatically and needs finance/manual review.</text>`);
parts.push('</svg>\n');

fs.writeFileSync(svgPath, parts.join('\n'));
console.log(svgPath);
