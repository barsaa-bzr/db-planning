#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const outDir = '/Users/barsaa/Projects/planning';
const drawioPath = path.join(outDir, 'lending_polaris_node_flow.drawio');
const svgPath = path.join(outDir, 'lending_polaris_node_flow.svg');

const W = 2700;
const H = 2500;

function esc(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function lines(s) {
  return esc(s).replace(/\n/g, '&#xa;');
}

const styles = {
  ui: 'rounded=1;whiteSpace=wrap;html=0;arcSize=8;fillColor=#dbeafe;strokeColor=#2563eb;fontColor=#0f172a;fontSize=12;fontStyle=1;spacing=8;',
  process: 'rounded=1;whiteSpace=wrap;html=0;arcSize=8;fillColor=#fff7ed;strokeColor=#ea580c;fontColor=#0f172a;fontSize=12;fontStyle=1;spacing=8;',
  db: 'shape=datastore;whiteSpace=wrap;html=0;fillColor=#f8fafc;strokeColor=#64748b;fontColor=#0f172a;fontSize=11;fontStyle=1;spacing=8;',
  ext: 'rounded=1;whiteSpace=wrap;html=0;arcSize=8;fillColor=#ecfeff;strokeColor=#0891b2;fontColor=#0f172a;fontSize=11;fontStyle=1;spacing=8;',
  control: 'rounded=1;whiteSpace=wrap;html=0;arcSize=8;fillColor=#fee2e2;strokeColor=#dc2626;fontColor=#7f1d1d;fontSize=11;fontStyle=1;spacing=8;',
  note: 'rounded=1;whiteSpace=wrap;html=0;arcSize=8;fillColor=#f1f5f9;strokeColor=#94a3b8;fontColor=#334155;fontSize=11;fontStyle=1;spacing=8;',
  title: 'text;html=0;strokeColor=none;fillColor=none;align=center;verticalAlign=middle;whiteSpace=wrap;fontSize=28;fontStyle=1;fontColor=#0f172a;',
  subtitle: 'text;html=0;strokeColor=none;fillColor=none;align=center;verticalAlign=middle;whiteSpace=wrap;fontSize=13;fontColor=#475569;',
  header: 'text;html=0;strokeColor=none;fillColor=none;align=center;verticalAlign=middle;whiteSpace=wrap;fontSize=17;fontStyle=1;fontColor=#0f172a;',
};

const cells = [];
const edges = [];

function addNode(id, value, kind, x, y, w, h) {
  const style = styles[kind];
  cells.push({ id, value, kind, x, y, w, h, style });
}

function addEdge(id, source, target, color = '#334155', label = '', dashed = false, width = 2) {
  const dash = dashed ? 'dashed=1;' : '';
  edges.push({ id, source, target, color, label, dashed, width, style: `edgeStyle=orthogonalEdgeStyle;rounded=1;orthogonalLoop=1;jettySize=auto;html=0;endArrow=block;endFill=1;strokeColor=${color};strokeWidth=${width};${dash}` });
}

function node(id) {
  const n = cells.find(c => c.id === id);
  if (!n) throw new Error(`Unknown node ${id}`);
  return n;
}

function center(n) {
  return { x: n.x + n.w / 2, y: n.y + n.h / 2 };
}

function right(n) {
  return { x: n.x + n.w, y: n.y + n.h / 2 };
}

function left(n) {
  return { x: n.x, y: n.y + n.h / 2 };
}

function bottom(n) {
  return { x: n.x + n.w / 2, y: n.y + n.h };
}

function top(n) {
  return { x: n.x + n.w / 2, y: n.y };
}

addNode('title', 'Direct Polaris Lending Node Flow: UI, Process, Database, External APIs, Controls', 'title', 80, 22, 2540, 38);
addNode('subtitle', 'No LOS. Each central process is connected to its database tables and external integration calls. Red control nodes show double-spend, timeout, audit and reconciliation safeguards.', 'subtitle', 180, 66, 2340, 42);
addNode('h_ui', 'UI ENTRY POINTS', 'header', 850, 118, 980, 26);
addNode('h_db', 'DATABASE TABLE NODES', 'header', 70, 215, 650, 30);
addNode('h_proc', 'PROCESS FLOW NODES', 'header', 895, 215, 620, 30);
addNode('h_ext', 'EXTERNAL INTEGRATION NODES', 'header', 1710, 215, 900, 30);

addNode('ui_admin', 'Admin / Back-office UI\nconfigs, approvals, service pause', 'ui', 640, 150, 260, 70);
addNode('ui_customer', 'Customer Mobile App\nregister, KYC, loan, repayment', 'ui', 930, 150, 280, 70);
addNode('ui_merchant', 'Merchant POS / Portal\nBNPL invoice, QR, settlement', 'ui', 1240, 150, 280, 70);
addNode('ui_finance', 'Finance Ops / Audit UI\nreconciliation, reports, exports', 'ui', 1550, 150, 280, 70);

const procX = 920;
const procW = 620;
const procH = 88;
const y0 = 270;
const gap = 135;
const processes = [
  ['p_config', '01 System Configuration\nLoad productCode, brchCode, curCode, txnDefCode, dynamicData mappings'],
  ['p_merchant', '02 Merchant Onboarding\nCreate merchant, terminal, passive account and settlement account'],
  ['p_register', '03 Customer Registration and Login\nOTP, session, PIN/biometric, customer profile starts pending'],
  ['p_kyc', '04 DAN Authorization and KYC Capture\nDAN consent, HUR fetch, contact/address/files, manual review if needed'],
  ['p_cif_deposit', '05 Polaris CIF and Deposit Account\nCreate/update CIF, create/open customer deposit CASA, store acntCode'],
  ['p_score', '06 Credit Scoring\nSain/FICO + custom score, factors, grade, model version, sync risk fields'],
  ['p_limit_line', '07 Limit and Polaris Line Account\nCreate local limit, create/open line account tied to customer deposit'],
  ['p_application', '08 Loan or BNPL Initiation\nOne-tap application or POS invoice/QR transaction starts'],
  ['p_reserve_approve', '09 Reservation and Approval\nLock line, reserve amount, approve/reject, release on rejection'],
  ['p_core_setup', '10 Child Loan Core Setup\nCreate/open child loan, calculate/create schedule, link child loan to line'],
  ['p_grant', '11 Grant Loan\nloan/grantLoanNonCash: child loan account to customer deposit account'],
  ['p_bnpl_transfer', '12 BNPL Merchant Transfer\nCustomer deposit to merchant passive account, then POS approved callback'],
  ['p_repayment', '13 Repayment Processing\nQPay callback, inbound money to deposit, pay loan from deposit'],
  ['p_allocate_close', '14 Allocation and Closing\nLock schedules, allocate, final payment close detail, close account'],
  ['p_recon', '15 Reconciliation, Reversal, Reporting\nDaily match, pending_reconcile worklist, one reversal per jrno, audit/export'],
];
processes.forEach(([id, label], i) => addNode(id, label, 'process', procX, y0 + i * gap, procW, procH));

const dbX = 70;
const dbW = 700;
[
  ['db_config', 'Config tables\npolaris_product_configs\npolaris_transaction_configs\npolaris_dynamic_field_mappings', 0],
  ['db_merchant', 'Merchant / POS tables\nmerchant_profiles\npos_terminals\npolaris_accounts', 1],
  ['db_user', 'User / auth tables\nusers, customer_profiles\notp_sessions, user_sessions\nPIN and biometric credentials', 2],
  ['db_kyc', 'KYC and identity tables\ndan_verifications, kyc_*\nhur_data_snapshots\ncustomer_bank_accounts', 3],
  ['db_deposit', 'Customer Polaris account tables\ncustomer_profiles.polaris_cust_code\ncustomer_deposit_accounts\npolaris_accounts', 4],
  ['db_score', 'Scoring and limit tables\nsain_score_requests\ncredit_score_results\ncredit_scoring_factors\nloan_limits', 5],
  ['db_line', 'Line and reservation tables\ncredit_line_accounts\ncredit_limit_reservations\nloan_limits.active_credit_line_account_id', 6],
  ['db_app_pos', 'Application / POS tables\nloan_applications\npos_payment_invoices\npos_qr_codes\npos_transactions', 7],
  ['db_reserve', 'Approval state tables\nloan_applications status\ncredit_limit_reservations\noptional loan_contracts', 8],
  ['db_loan_core', 'Loan core tables\nloans\nrepayment_schedules\nloan_core_steps\npolaris_sync_queue', 9],
  ['db_ledger_grant', 'Financial journal tables\nledger_journals\nledger_entries\nloans grant jrno fields', 10],
  ['db_bnpl', 'BNPL settlement tables\npos_transactions transfer fields\nmerchant_settlement_items\npos_terminal_callbacks', 11],
  ['db_repay', 'Repayment tables\nqpay_repayment_invoices\nqpay_repayment_callbacks\nrepayment_transactions\nrepayment_allocations', 12],
  ['db_close', 'Close / balance tables\nloans status\nrepayment_schedules\ncredit_line_accounts utilized amount\nledger_journals', 13],
  ['db_audit', 'Audit / API / reconciliation tables\naudit_logs, system_event_logs\npolaris_api_logs\npolaris_operation_attempts\nv_polaris_reconciliation_worklist', 14],
].forEach(([id, label, i]) => addNode(id, label, 'db', dbX, y0 + i * gap - 8, dbW, 104));

const ext1X = 1710;
const ext2X = 2150;
const extW = 390;
[
  ['ext_merchant', 'Merchant setup APIs\ntmm/insertMerchant\ntsd/createTsdTerminal\ntmm/insertTmmMerchantTermnl', ext1X, 1],
  ['ext_dan', 'DAN identity authority\nidentity authorization\nregister validation', ext1X, 3],
  ['ext_hur', 'HUR data services\nincome, employment,\nsocial/health snapshots', ext2X, 3],
  ['ext_cif', 'Polaris CIF APIs\ncif/createPerson\ncif/updatePerson', ext1X, 4],
  ['ext_casa', 'Polaris CASA APIs\ncasa/createAccount\ncasa/openAccountStatus', ext2X, 4],
  ['ext_sain', 'Sain / FICO scoring\nexternal risk score\nraw response snapshot', ext1X, 5],
  ['ext_line', 'Polaris LINE APIs\nline/createAccount\nline/openAccount\nline/adjustLineAccountLimit', ext2X, 6],
  ['ext_pos', 'Merchant POS terminal\ninvoice display\nQR scan\napproved/rejected callback', ext1X, 7],
  ['ext_loan_acct', 'Polaris loan account APIs\nloan/createAccount\nloan/openAccount\nloan/getAccountDetail', ext1X, 9],
  ['ext_schedule', 'Polaris schedule + link APIs\nloan/calculateNrsSchedule\nloan/createNrsSchedule\nline/linkLineAccountToLoan', ext2X, 9],
  ['ext_grant', 'Polaris grant API\nloan/grantLoanNonCash\nloan account -> customer deposit\nreturns jrno', ext1X, 10],
  ['ext_internal_txn', 'Internal CASA transaction\ntllrcasa/internalCasaTransaction\ncustomer deposit -> merchant passive', ext2X, 11],
  ['ext_qpay', 'QPay integration\nrepayment invoice\npayment callback\nunique qpay_payment_id', ext1X, 12],
  ['ext_repay', 'Polaris repayment APIs\ninbound transfer to deposit\nloan/nonCashLoanPayment\nloanPaymentTxnNonCash', ext2X, 12],
  ['ext_close', 'Polaris close APIs\nloan/getLoanClosingAccountDetail\nloan/nonCashCloseAccount', ext1X, 13],
  ['ext_gen', 'Polaris GEN / reversal APIs\ngen/getTmwJournalList\ngen/getAccountStatement\ngen/doReverseTxn\ngen/undoTransaction', ext2X, 14],
].forEach(([id, label, x, i]) => addNode(id, label, 'ext', x, y0 + i * gap - 8, extW, 104));

addNode('ctrl_idemp', 'Idempotency\none stable key per operation\nreuse same key after timeout', 'control', 90, 2280, 360, 84);
addNode('ctrl_outbox', 'Outbox/Saga\nall Polaris writes through\npolaris_sync_queue + attempts', 'control', 490, 2280, 390, 84);
addNode('ctrl_unknown', 'Unknown result handling\nPolaris timeout => pending_reconcile\nquery journals/statements before retry', 'control', 920, 2280, 430, 84);
addNode('ctrl_double', 'Double-spend controls\nline reservation, POS invoice lock,\nQPay duplicate guard, schedule lock', 'control', 1390, 2280, 460, 84);
addNode('ctrl_audit', 'Audit and financial truth\naudit status changes only\nledger_journals for money facts\none reversal per original jrno', 'control', 1890, 2280, 520, 84);

addEdge('ui_admin_config', 'ui_admin', 'p_config', '#2563eb');
addEdge('ui_admin_merchant', 'ui_admin', 'p_merchant', '#2563eb');
addEdge('ui_customer_reg', 'ui_customer', 'p_register', '#2563eb');
addEdge('ui_customer_kyc', 'ui_customer', 'p_kyc', '#2563eb');
addEdge('ui_customer_app', 'ui_customer', 'p_application', '#2563eb');
addEdge('ui_customer_repay', 'ui_customer', 'p_repayment', '#2563eb');
addEdge('ui_merchant_bnpl', 'ui_merchant', 'p_application', '#2563eb');
addEdge('ui_merchant_transfer', 'ui_merchant', 'p_bnpl_transfer', '#2563eb');
addEdge('ui_finance_recon', 'ui_finance', 'p_recon', '#2563eb');

for (let i = 0; i < processes.length - 1; i++) {
  addEdge(`flow_${i}`, processes[i][0], processes[i + 1][0], '#0f172a', '', false, 3);
}

[
  ['p_config', 'db_config'],
  ['p_merchant', 'db_merchant'],
  ['p_register', 'db_user'],
  ['p_kyc', 'db_kyc'],
  ['p_cif_deposit', 'db_deposit'],
  ['p_score', 'db_score'],
  ['p_limit_line', 'db_line'],
  ['p_application', 'db_app_pos'],
  ['p_reserve_approve', 'db_reserve'],
  ['p_core_setup', 'db_loan_core'],
  ['p_grant', 'db_ledger_grant'],
  ['p_bnpl_transfer', 'db_bnpl'],
  ['p_repayment', 'db_repay'],
  ['p_allocate_close', 'db_close'],
  ['p_recon', 'db_audit'],
  ['p_recon', 'db_ledger_grant'],
  ['p_recon', 'db_repay'],
].forEach(([p, d], idx) => addEdge(`db_${idx}`, d, p, '#64748b', 'read/write', true, 2));

[
  ['p_merchant', 'ext_merchant'],
  ['p_kyc', 'ext_dan'],
  ['p_kyc', 'ext_hur'],
  ['p_cif_deposit', 'ext_cif'],
  ['p_cif_deposit', 'ext_casa'],
  ['p_score', 'ext_sain'],
  ['p_score', 'ext_cif'],
  ['p_limit_line', 'ext_line'],
  ['p_application', 'ext_pos'],
  ['p_core_setup', 'ext_loan_acct'],
  ['p_core_setup', 'ext_schedule'],
  ['p_grant', 'ext_grant'],
  ['p_bnpl_transfer', 'ext_internal_txn'],
  ['p_bnpl_transfer', 'ext_pos'],
  ['p_repayment', 'ext_qpay'],
  ['p_repayment', 'ext_repay'],
  ['p_allocate_close', 'ext_close'],
  ['p_recon', 'ext_gen'],
  ['p_recon', 'ext_close'],
  ['p_recon', 'ext_loan_acct'],
].forEach(([p, e], idx) => addEdge(`ext_${idx}`, p, e, '#0891b2', 'API call', false, 2));

[
  ['ctrl_idemp', 'p_grant'],
  ['ctrl_idemp', 'p_repayment'],
  ['ctrl_outbox', 'p_core_setup'],
  ['ctrl_unknown', 'p_recon'],
  ['ctrl_double', 'p_reserve_approve'],
  ['ctrl_double', 'p_bnpl_transfer'],
  ['ctrl_double', 'p_repayment'],
  ['ctrl_audit', 'p_recon'],
].forEach(([c, p], idx) => addEdge(`ctrl_${idx}`, c, p, '#dc2626', '', true, 2));

const mxCells = [];
mxCells.push('<mxCell id="0"/>');
mxCells.push('<mxCell id="1" parent="0"/>');
for (const c of cells) {
  mxCells.push(`<mxCell id="${esc(c.id)}" value="${lines(c.value)}" style="${esc(c.style)}" vertex="1" parent="1"><mxGeometry x="${c.x}" y="${c.y}" width="${c.w}" height="${c.h}" as="geometry"/></mxCell>`);
}
for (const e of edges) {
  mxCells.push(`<mxCell id="${esc(e.id)}" value="${lines(e.label)}" style="${esc(e.style)}" edge="1" parent="1" source="${esc(e.source)}" target="${esc(e.target)}"><mxGeometry relative="1" as="geometry"/></mxCell>`);
}

const drawio = `<mxfile host="app.diagrams.net" modified="2026-05-20T00:00:00.000Z" agent="Codex" version="24.7.17" type="device">
  <diagram id="lending-polaris-node-flow" name="Detailed Node Flow">
    <mxGraphModel dx="2600" dy="1800" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="${W}" pageHeight="${H}" math="0" shadow="0">
      <root>
        ${mxCells.join('\n        ')}
      </root>
    </mxGraphModel>
  </diagram>
</mxfile>
`;

function svgText(value, x, y, width, cls, maxChars = 44, lineHeight = 17) {
  const rawLines = String(value).split('\n');
  const out = [];
  let lineNo = 0;
  for (const raw of rawLines) {
    const words = raw.split(/\s+/);
    let line = '';
    for (const word of words) {
      if (!word) continue;
      const next = line ? `${line} ${word}` : word;
      if (next.length > maxChars && line) {
        out.push(`<text x="${x + width / 2}" y="${y + lineNo * lineHeight}" text-anchor="middle" class="${cls}">${esc(line)}</text>`);
        lineNo += 1;
        line = word;
      } else {
        line = next;
      }
    }
    if (line) {
      out.push(`<text x="${x + width / 2}" y="${y + lineNo * lineHeight}" text-anchor="middle" class="${cls}">${esc(line)}</text>`);
      lineNo += 1;
    }
  }
  return out.join('\n');
}

function svgNode(c) {
  if (c.kind === 'title' || c.kind === 'subtitle' || c.kind === 'header') {
    const cls = c.kind === 'title' ? 'title' : (c.kind === 'subtitle' ? 'subtitle' : 'section');
    return `<text x="${c.x + c.w / 2}" y="${c.y + c.h / 2 + 5}" text-anchor="middle" class="${cls}">${esc(c.value)}</text>`;
  }
  const fill = {
    ui: '#dbeafe',
    process: '#fff7ed',
    db: '#f8fafc',
    ext: '#ecfeff',
    control: '#fee2e2',
    note: '#f1f5f9',
  }[c.kind] || '#ffffff';
  const stroke = {
    ui: '#2563eb',
    process: '#ea580c',
    db: '#64748b',
    ext: '#0891b2',
    control: '#dc2626',
    note: '#94a3b8',
  }[c.kind] || '#334155';
  const shape = c.kind === 'db'
    ? `<path d="M${c.x},${c.y + 14} C${c.x},${c.y - 2} ${c.x + c.w},${c.y - 2} ${c.x + c.w},${c.y + 14} L${c.x + c.w},${c.y + c.h - 14} C${c.x + c.w},${c.y + c.h + 2} ${c.x},${c.y + c.h + 2} ${c.x},${c.y + c.h - 14} Z M${c.x},${c.y + 14} C${c.x},${c.y + 30} ${c.x + c.w},${c.y + 30} ${c.x + c.w},${c.y + 14}" fill="${fill}" stroke="${stroke}" stroke-width="2"/>`
    : `<rect x="${c.x}" y="${c.y}" width="${c.w}" height="${c.h}" rx="10" ry="10" fill="${fill}" stroke="${stroke}" stroke-width="2"/>`;
  return `<g filter="url(#shadow)">
    ${shape}
    ${svgText(c.value, c.x + 14, c.y + 24, c.w - 28, c.kind === 'control' ? 'controlText' : 'nodeText', c.kind === 'db' ? 40 : 48, 16)}
  </g>`;
}

function svgEdge(e) {
  const s = node(e.source);
  const t = node(e.target);
  let a;
  let b;
  if (s.x < t.x) {
    a = right(s);
    b = left(t);
  } else if (s.x > t.x) {
    a = left(s);
    b = right(t);
  } else if (s.y < t.y) {
    a = bottom(s);
    b = top(t);
  } else {
    a = top(s);
    b = bottom(t);
  }
  const cls = e.color === '#dc2626' ? 'edgeRed' : (e.color === '#0891b2' ? 'edgeApi' : (e.color === '#64748b' ? 'edgeDb' : 'edgeFlow'));
  const dash = e.dashed ? ' stroke-dasharray="8 6"' : '';
  const mx = (a.x + b.x) / 2;
  const pathData = s.x === t.x
    ? `M${a.x},${a.y} C${a.x},${(a.y + b.y) / 2} ${b.x},${(a.y + b.y) / 2} ${b.x},${b.y}`
    : `M${a.x},${a.y} C${mx},${a.y} ${mx},${b.y} ${b.x},${b.y}`;
  return `<path d="${pathData}" class="${cls}"${dash}/>`;
}

const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
  <defs>
    <marker id="arrow" markerWidth="12" markerHeight="12" refX="10" refY="6" orient="auto" markerUnits="strokeWidth"><path d="M2,2 L10,6 L2,10 Z" fill="#334155"/></marker>
    <marker id="blueArrow" markerWidth="12" markerHeight="12" refX="10" refY="6" orient="auto" markerUnits="strokeWidth"><path d="M2,2 L10,6 L2,10 Z" fill="#0891b2"/></marker>
    <marker id="redArrow" markerWidth="12" markerHeight="12" refX="10" refY="6" orient="auto" markerUnits="strokeWidth"><path d="M2,2 L10,6 L2,10 Z" fill="#dc2626"/></marker>
    <filter id="shadow" x="-8%" y="-8%" width="116%" height="122%"><feDropShadow dx="0" dy="5" stdDeviation="5" flood-color="#0f172a" flood-opacity="0.11"/></filter>
    <style>
      .title { font: 800 28px Arial, sans-serif; fill: #0f172a; }
      .subtitle { font: 13px Arial, sans-serif; fill: #475569; }
      .section { font: 800 17px Arial, sans-serif; fill: #0f172a; }
      .nodeText { font: 700 12px Arial, sans-serif; fill: #0f172a; }
      .controlText { font: 700 11px Arial, sans-serif; fill: #7f1d1d; }
      .edgeFlow { fill: none; stroke: #334155; stroke-width: 2.6; marker-end: url(#arrow); }
      .edgeApi { fill: none; stroke: #0891b2; stroke-width: 2; marker-end: url(#blueArrow); }
      .edgeDb { fill: none; stroke: #64748b; stroke-width: 1.9; marker-end: url(#arrow); }
      .edgeRed { fill: none; stroke: #dc2626; stroke-width: 2; marker-end: url(#redArrow); }
    </style>
  </defs>
  <rect x="0" y="0" width="${W}" height="${H}" fill="#ffffff"/>
  <rect x="40" y="110" width="2670" height="2150" rx="22" ry="22" fill="#f8fafc" stroke="#e2e8f0"/>
  <rect x="52" y="240" width="760" height="1970" rx="18" ry="18" fill="#f8fafc" stroke="#cbd5e1"/>
  <rect x="860" y="240" width="740" height="1970" rx="18" ry="18" fill="#fff7ed" stroke="#fed7aa"/>
  <rect x="1660" y="240" width="950" height="1970" rx="18" ry="18" fill="#ecfeff" stroke="#a5f3fc"/>
  ${edges.map(svgEdge).join('\n  ')}
  ${cells.map(svgNode).join('\n  ')}
</svg>
`;

fs.writeFileSync(drawioPath, drawio);
fs.writeFileSync(svgPath, svg);
console.log(drawioPath);
console.log(svgPath);
