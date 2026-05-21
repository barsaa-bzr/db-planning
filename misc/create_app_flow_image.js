#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const cwd = '/Users/barsaa/Projects/planning';
const inputPath = path.join(cwd, 'app_flow.mmd');
const svgPath = path.join(cwd, 'app_flow_visual.svg');

const rows = fs.readFileSync(inputPath, 'utf8')
  .split(/\r?\n/)
  .map((line) => line.trim())
  .filter(Boolean)
  .map((line, index) => {
    const cols = line.split(',');
    if (cols.length !== 4) {
      throw new Error(`Line ${index + 1} must have 4 comma-separated columns, got ${cols.length}: ${line}`);
    }
    return cols.map((c) => c.trim());
  });

const [headers, ...data] = rows;

const W = 5200;
const margin = 110;
const top = 430;
const laneGap = 30;
const rowGap = 22;
const footerH = 130;
const laneY = 262;
const laneH = 86;
const railW = 118;

const widths = {
  action: 760,
  our: 1370,
  polaris: 1370,
  response: 1220,
};

const x = {
  rail: margin,
  action: margin + railW + 26,
};
x.our = x.action + widths.action + laneGap;
x.polaris = x.our + widths.our + laneGap;
x.response = x.polaris + widths.polaris + laneGap;

const laneTotalW = x.response + widths.response - margin;

function esc(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function wrap(text, max) {
  const out = [];
  for (const part of String(text).split('\n')) {
    let line = '';
    for (const word of part.split(/\s+/)) {
      if (!word) continue;
      const next = line ? `${line} ${word}` : word;
      if (next.length > max && line) {
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

function sectionFor(idx) {
  if (idx <= 2) return {
    title: 'Foundation',
    subtitle: 'Configuration and merchant readiness',
    color: '#0284c7',
    tint: '#e0f2fe',
  };
  if (idx <= 13) return {
    title: 'Customer Onboarding',
    subtitle: 'Registration, DAN, CIF, deposit, KYC and scoring',
    color: '#2563eb',
    tint: '#eff6ff',
  };
  if (idx <= 18) return {
    title: 'Risk, Limit and Line',
    subtitle: 'Limit creation, line account and line adjustment',
    color: '#059669',
    tint: '#ecfdf5',
  };
  if (idx <= 33) return {
    title: 'Loan Drawdown and BNPL',
    subtitle: 'Reservation, contract, child loan, schedule, link and grant',
    color: '#ea580c',
    tint: '#fff7ed',
  };
  if (idx <= 44) return {
    title: 'Repayment and Closing',
    subtitle: 'QPay, inbound money, loan payment, allocation and close',
    color: '#10b981',
    tint: '#ecfdf5',
  };
  if (idx <= 49) return {
    title: 'Settlement and Refunds',
    subtitle: 'Merchant settlement, refund, reversal and offsets',
    color: '#a16207',
    tint: '#fefce8',
  };
  return {
    title: 'Reconciliation and Governance',
    subtitle: 'Timeout recovery, daily reconcile, audit, ledger and API logging',
    color: '#475569',
    tint: '#f1f5f9',
  };
}

function classifyPolaris(text) {
  const lower = text.toLowerCase();
  if (lower.includes('no polaris call')) return { label: 'LOCAL ONLY', color: '#64748b', fill: '#f8fafc' };
  if (lower.includes('external qpay')) return { label: 'QPAY', color: '#7c3aed', fill: '#f5f3ff' };
  if (lower.includes('external hur')) return { label: 'HUR', color: '#0891b2', fill: '#ecfeff' };
  if (lower.includes('external sain') || lower.includes('fico')) return { label: 'SAIN / FICO', color: '#0891b2', fill: '#ecfeff' };
  if (lower.includes('callback')) return { label: 'EXTERNAL CALLBACK', color: '#7c3aed', fill: '#f5f3ff' };
  if (lower.includes('call ') || lower.includes('/')) return { label: 'POLARIS API', color: '#0e7490', fill: '#ecfeff' };
  return { label: 'INTEGRATION', color: '#0e7490', fill: '#ecfeff' };
}

function classifyOur(text) {
  const lower = text.toLowerCase();
  if (lower.includes('lock')) return { label: 'LOCKED DB WRITE', color: '#be123c', fill: '#fff1f2' };
  if (lower.includes('create') || lower.includes('update') || lower.includes('save') || lower.includes('insert') || lower.includes('set ')) {
    return { label: 'DB WRITE', color: '#1d4ed8', fill: '#eff6ff' };
  }
  if (lower.includes('read') || lower.includes('check') || lower.includes('query')) return { label: 'DB READ', color: '#0369a1', fill: '#f0f9ff' };
  return { label: 'LOCAL PROCESS', color: '#334155', fill: '#f8fafc' };
}

function classifyResponse(text) {
  const lower = text.toLowerCase();
  if (lower.includes('pending_reconcile') || lower.includes('dead_letter') || lower.includes('timeout') || lower.includes('manual review')) {
    return { label: 'CONTROLLED EXCEPTION', color: '#b45309', fill: '#fffbeb' };
  }
  if (lower.includes('reject') || lower.includes('failed') || lower.includes('failure') || lower.includes('blocked')) {
    return { label: 'REJECT / BLOCK', color: '#be123c', fill: '#fff1f2' };
  }
  if (lower.includes('ignore')) return { label: 'IDEMPOTENT IGNORE', color: '#7c3aed', fill: '#f5f3ff' };
  return { label: 'SUCCESS PATH', color: '#15803d', fill: '#f0fdf4' };
}

const maxChars = {
  action: 31,
  our: 62,
  polaris: 62,
  response: 56,
};

const rowModels = data.map((cols, idx) => {
  const [action, our, polaris, response] = cols;
  const lines = {
    action: wrap(action, maxChars.action),
    our: wrap(our, maxChars.our),
    polaris: wrap(polaris, maxChars.polaris),
    response: wrap(response, maxChars.response),
  };
  const section = sectionFor(idx);
  const ourType = classifyOur(our);
  const polarisType = classifyPolaris(polaris);
  const responseType = classifyResponse(response);
  const lineCount = Math.max(lines.action.length, lines.our.length, lines.polaris.length, lines.response.length);
  const h = Math.max(124, 58 + lineCount * 24);
  return { idx, cols, lines, section, ourType, polarisType, responseType, h };
});

let y = top;
let currentSection = null;
for (const model of rowModels) {
  if (!currentSection || model.section.title !== currentSection) {
    model.sectionBreak = true;
    y += currentSection ? 64 : 0;
    model.sectionY = y;
    y += 76;
    currentSection = model.section.title;
  }
  model.y = y;
  y += model.h + rowGap;
}
const H = y + footerH;

function textLines(lines, tx, ty, cls, lineH = 24, anchor = 'start') {
  return lines.map((line, i) => (
    `<text x="${tx}" y="${ty + i * lineH}" text-anchor="${anchor}" class="${cls}">${esc(line)}</text>`
  )).join('\n');
}

function pill(tx, ty, label, stroke, fill) {
  const tw = Math.max(114, label.length * 9.8 + 36);
  return `<rect x="${tx}" y="${ty}" width="${tw}" height="30" rx="15" ry="15" fill="${fill}" stroke="${stroke}" stroke-width="1.4"/>
<text x="${tx + tw / 2}" y="${ty + 20}" text-anchor="middle" class="pillText" fill="${stroke}">${esc(label)}</text>`;
}

function node({ tx, ty, tw, th, header, lines, border, fill, badge, iconText, strong = false }) {
  const badgeSvg = badge ? pill(tx + 24, ty + 18, badge.label, badge.color, badge.fill) : '';
  const headingY = badge ? ty + 69 : ty + 42;
  const textY = headingY + 35;
  return `<g class="node">
  <rect x="${tx}" y="${ty}" width="${tw}" height="${th}" rx="20" ry="20" fill="${fill}" stroke="${border}" stroke-width="${strong ? 2.8 : 1.7}"/>
  <circle cx="${tx + tw - 42}" cy="${ty + 39}" r="19" fill="${border}" opacity="0.12"/>
  <text x="${tx + tw - 42}" y="${ty + 46}" text-anchor="middle" class="iconText" fill="${border}">${esc(iconText)}</text>
  ${badgeSvg}
  <text x="${tx + 24}" y="${headingY}" class="${strong ? 'nodeTitleStrong' : 'nodeTitle'}">${esc(header)}</text>
  ${textLines(lines, tx + 24, textY, 'nodeBody')}
</g>`;
}

function hArrow(x1, y1, x2, y2, color = '#64748b') {
  const mid = (x1 + x2) / 2;
  return `<path d="M${x1},${y1} C${mid},${y1} ${mid},${y2} ${x2},${y2}" fill="none" stroke="${color}" stroke-width="2.6" marker-end="url(#arrow)"/>`;
}

const parts = [];

parts.push(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
  <defs>
    <linearGradient id="pageBg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#eef6ff"/>
      <stop offset="45%" stop-color="#f8fafc"/>
      <stop offset="100%" stop-color="#f1f5f9"/>
    </linearGradient>
    <linearGradient id="heroBg" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0%" stop-color="#0f172a"/>
      <stop offset="48%" stop-color="#164e63"/>
      <stop offset="100%" stop-color="#14532d"/>
    </linearGradient>
    <linearGradient id="laneBg" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0%" stop-color="#ffffff"/>
      <stop offset="100%" stop-color="#f8fafc"/>
    </linearGradient>
    <pattern id="grid" width="48" height="48" patternUnits="userSpaceOnUse">
      <path d="M48 0H0V48" fill="none" stroke="#cbd5e1" stroke-width="1" opacity="0.24"/>
    </pattern>
    <marker id="arrow" markerWidth="14" markerHeight="14" refX="11" refY="7" orient="auto" markerUnits="strokeWidth">
      <path d="M2,2 L12,7 L2,12 Z" fill="#64748b"/>
    </marker>
    <filter id="cardShadow" x="-4%" y="-12%" width="110%" height="132%">
      <feDropShadow dx="0" dy="10" stdDeviation="11" flood-color="#0f172a" flood-opacity="0.12"/>
    </filter>
    <filter id="softShadow" x="-3%" y="-15%" width="106%" height="140%">
      <feDropShadow dx="0" dy="4" stdDeviation="5" flood-color="#0f172a" flood-opacity="0.10"/>
    </filter>
    <style>
      text { font-family: Arial, Helvetica, sans-serif; letter-spacing: 0; }
      .heroTitle { font-size: 54px; font-weight: 800; fill: #ffffff; }
      .heroSub { font-size: 21px; fill: #dbeafe; }
      .heroMeta { font-size: 18px; font-weight: 700; fill: #bbf7d0; }
      .laneTitle { font-size: 23px; font-weight: 800; fill: #0f172a; }
      .laneSub { font-size: 15px; fill: #64748b; }
      .laneCode { font-size: 19px; font-weight: 800; fill: #ffffff; }
      .sectionTitle { font-size: 26px; font-weight: 800; fill: #ffffff; }
      .sectionSub { font-size: 17px; fill: #e2e8f0; }
      .nodeTitle { font-size: 20px; font-weight: 800; fill: #0f172a; }
      .nodeTitleStrong { font-size: 21px; font-weight: 800; fill: #0f172a; }
      .nodeBody { font-size: 18px; fill: #334155; }
      .pillText { font-size: 13px; font-weight: 800; }
      .iconText { font-size: 16px; font-weight: 800; }
      .railText { font-size: 23px; font-weight: 800; fill: #ffffff; }
      .smallNote { font-size: 17px; fill: #475569; }
      .legendTitle { font-size: 18px; font-weight: 800; fill: #0f172a; }
      .legendText { font-size: 16px; fill: #475569; }
    </style>
  </defs>
  <rect width="${W}" height="${H}" fill="url(#pageBg)"/>
  <rect width="${W}" height="${H}" fill="url(#grid)"/>
  <rect x="54" y="48" width="${W - 108}" height="${H - 96}" rx="38" ry="38" fill="#ffffff" opacity="0.88" stroke="#dbe3ee" stroke-width="2"/>
  <g filter="url(#cardShadow)">
    <rect x="${margin}" y="82" width="${laneTotalW}" height="142" rx="34" ry="34" fill="url(#heroBg)"/>
    <text x="${margin + 44}" y="142" class="heroTitle">Polaris Direct Lending Lifecycle</text>
    <text x="${margin + 46}" y="184" class="heroSub">A generated flow chart from app_flow.mmd showing UI actions, local database/process work, Polaris/external calls, and final response states.</text>
    <text x="${margin + laneTotalW - 44}" y="143" text-anchor="end" class="heroMeta">No LOS | Idempotent write queue | Reconcile before retry | One reversal per jrno</text>
    <text x="${margin + laneTotalW - 44}" y="184" text-anchor="end" class="heroSub">${data.length} lifecycle operations</text>
  </g>
`);

const lanes = [
  { key: 'action', label: headers[0], sub: 'User, staff, scheduler, POS or provider trigger', code: 'UI', color: '#2563eb', tx: x.action, tw: widths.action },
  { key: 'our', label: headers[1], sub: 'Local workflow, locking, tables, ledger and audit', code: 'DB', color: '#1d4ed8', tx: x.our, tw: widths.our },
  { key: 'polaris', label: headers[2], sub: 'Polaris core banking and external integrations', code: 'API', color: '#0e7490', tx: x.polaris, tw: widths.polaris },
  { key: 'response', label: headers[3], sub: 'Customer/POS/system outcome and status', code: 'OK', color: '#15803d', tx: x.response, tw: widths.response },
];

for (const lane of lanes) {
  parts.push(`<g filter="url(#softShadow)">
  <rect x="${lane.tx}" y="${laneY}" width="${lane.tw}" height="${laneH}" rx="24" ry="24" fill="url(#laneBg)" stroke="#dbe3ee" stroke-width="1.7"/>
  <circle cx="${lane.tx + 48}" cy="${laneY + 43}" r="27" fill="${lane.color}"/>
  <text x="${lane.tx + 48}" y="${laneY + 50}" text-anchor="middle" class="laneCode">${esc(lane.code)}</text>
  <text x="${lane.tx + 92}" y="${laneY + 35}" class="laneTitle">${esc(lane.label)}</text>
  <text x="${lane.tx + 92}" y="${laneY + 61}" class="laneSub">${esc(lane.sub)}</text>
</g>`);
}

let activeSectionColor = null;
for (const model of rowModels) {
  if (model.sectionBreak) {
    activeSectionColor = model.section.color;
    const sy = model.sectionY;
    parts.push(`<g filter="url(#softShadow)">
  <rect x="${margin}" y="${sy}" width="${laneTotalW}" height="54" rx="22" ry="22" fill="${model.section.color}"/>
  <text x="${margin + 30}" y="${sy + 35}" class="sectionTitle">${esc(model.section.title)}</text>
  <text x="${margin + 370}" y="${sy + 35}" class="sectionSub">${esc(model.section.subtitle)}</text>
</g>`);
  }

  const cy = model.y + model.h / 2;
  const railX = x.rail;
  const rowBgY = model.y - 10;
  const rowBgH = model.h + 20;

  parts.push(`<g filter="url(#softShadow)">
  <rect x="${margin}" y="${rowBgY}" width="${laneTotalW}" height="${rowBgH}" rx="28" ry="28" fill="${model.section.tint}" stroke="${model.section.color}" stroke-width="1.3" opacity="0.72"/>
  <rect x="${railX}" y="${model.y}" width="${railW}" height="${model.h}" rx="22" ry="22" fill="${model.section.color}"/>
  <text x="${railX + railW / 2}" y="${cy + 8}" text-anchor="middle" class="railText">${String(model.idx + 1).padStart(2, '0')}</text>
</g>`);

  parts.push(hArrow(x.action + widths.action + 3, cy, x.our - 3, cy, '#94a3b8'));
  parts.push(hArrow(x.our + widths.our + 3, cy, x.polaris - 3, cy, '#94a3b8'));
  parts.push(hArrow(x.polaris + widths.polaris + 3, cy, x.response - 3, cy, '#94a3b8'));

  parts.push(`<g filter="url(#cardShadow)">`);
  parts.push(node({
    tx: x.action,
    ty: model.y,
    tw: widths.action,
    th: model.h,
    header: `Action ${String(model.idx + 1).padStart(2, '0')}`,
    lines: model.lines.action,
    border: model.section.color,
    fill: '#ffffff',
    badge: { label: model.section.title.toUpperCase(), color: model.section.color, fill: '#ffffff' },
    iconText: 'UI',
    strong: true,
  }));
  parts.push(node({
    tx: x.our,
    ty: model.y,
    tw: widths.our,
    th: model.h,
    header: 'Our application, DB and controls',
    lines: model.lines.our,
    border: model.ourType.color,
    fill: model.ourType.fill,
    badge: model.ourType,
    iconText: 'DB',
  }));
  parts.push(node({
    tx: x.polaris,
    ty: model.y,
    tw: widths.polaris,
    th: model.h,
    header: 'Polaris / external integration',
    lines: model.lines.polaris,
    border: model.polarisType.color,
    fill: model.polarisType.fill,
    badge: model.polarisType,
    iconText: 'API',
  }));
  parts.push(node({
    tx: x.response,
    ty: model.y,
    tw: widths.response,
    th: model.h,
    header: 'Response and status',
    lines: model.lines.response,
    border: model.responseType.color,
    fill: model.responseType.fill,
    badge: model.responseType,
    iconText: 'OK',
  }));
  parts.push('</g>');

  const next = rowModels[model.idx + 1];
  if (next) {
    const spineX = railX + railW / 2;
    const startY = model.y + model.h + 2;
    const endY = next.y - 12;
    if (endY > startY + 14) {
      parts.push(`<path d="M${spineX},${startY} C${spineX},${(startY + endY) / 2} ${spineX},${(startY + endY) / 2} ${spineX},${endY}" fill="none" stroke="${activeSectionColor}" stroke-width="4" opacity="0.72" marker-end="url(#arrow)"/>`);
    }
  }
}

const footerY = H - 86;
parts.push(`<g>
  <rect x="${margin}" y="${footerY - 26}" width="${laneTotalW}" height="54" rx="18" ry="18" fill="#f8fafc" stroke="#cbd5e1" stroke-width="1.4"/>
  <text x="${margin + 26}" y="${footerY + 6}" class="legendTitle">Operational rule:</text>
  <text x="${margin + 210}" y="${footerY + 6}" class="legendText">failed = confirmed failure; pending_reconcile = unknown Polaris result; dead_letter = unresolved after automated reconciliation; retries reuse the same idempotency key after journal/statement search.</text>
</g>`);
parts.push('</svg>\n');

fs.writeFileSync(svgPath, parts.join('\n'));
console.log(svgPath);
