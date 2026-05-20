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

const W = 4300;
const margin = 80;
const top = 270;
const headerH = 64;
const rowGap = 18;
const x = {
  no: margin,
  action: margin + 90,
  our: margin + 90 + 610,
  polaris: margin + 90 + 610 + 1140,
  response: margin + 90 + 610 + 1140 + 1140,
};
const w = {
  no: 66,
  action: 580,
  our: 1110,
  polaris: 1110,
  response: 1080,
};

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

function sectionFor(action, idx) {
  if (idx <= 2) return ['Foundation', '#0ea5e9'];
  if (idx <= 13) return ['Customer onboarding', '#2563eb'];
  if (idx <= 18) return ['Risk, limit and line', '#16a34a'];
  if (idx <= 33) return ['Loan drawdown and BNPL', '#ea580c'];
  if (idx <= 44) return ['Repayment and closing', '#16a34a'];
  if (idx <= 49) return ['Settlement and refunds', '#a16207'];
  return ['Reconciliation and governance', '#475569'];
}

const maxChars = {
  action: 34,
  our: 70,
  polaris: 70,
  response: 68,
};

const rowModels = data.map((cols, idx) => {
  const [action, our, polaris, response] = cols;
  const lines = {
    action: wrap(action, maxChars.action),
    our: wrap(our, maxChars.our),
    polaris: wrap(polaris, maxChars.polaris),
    response: wrap(response, maxChars.response),
  };
  const lineCount = Math.max(lines.action.length, lines.our.length, lines.polaris.length, lines.response.length);
  const h = Math.max(92, 28 + lineCount * 23);
  const [section, color] = sectionFor(action, idx);
  return { idx, cols, lines, h, section, color };
});

let y = top + headerH + 34;
let currentSection = null;
for (const model of rowModels) {
  if (model.section !== currentSection) {
    model.sectionBreak = true;
    y += currentSection ? 44 : 0;
    currentSection = model.section;
  }
  model.y = y;
  y += model.h + rowGap;
}
const H = y + 210;

function textLines(lines, tx, ty, cls, anchor = 'start', lineH = 23) {
  return lines.map((line, i) => (
    `<text x="${tx}" y="${ty + i * lineH}" text-anchor="${anchor}" class="${cls}">${esc(line)}</text>`
  )).join('\n');
}

function card(tx, ty, tw, th, fill, stroke, content, cls = 'cellText') {
  return `<rect x="${tx}" y="${ty}" width="${tw}" height="${th}" rx="16" ry="16" fill="${fill}" stroke="${stroke}" stroke-width="1.8"/>
${textLines(content, tx + 22, ty + 34, cls)}`;
}

const parts = [];
parts.push(`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
  <defs>
    <marker id="arrow" markerWidth="14" markerHeight="14" refX="11" refY="7" orient="auto" markerUnits="strokeWidth">
      <path d="M2,2 L12,7 L2,12 Z" fill="#334155"/>
    </marker>
    <filter id="shadow" x="-5%" y="-10%" width="112%" height="130%">
      <feDropShadow dx="0" dy="7" stdDeviation="7" flood-color="#0f172a" flood-opacity="0.11"/>
    </filter>
    <style>
      .title { font: 800 42px Arial, sans-serif; fill: #0f172a; }
      .subtitle { font: 18px Arial, sans-serif; fill: #475569; }
      .headerText { font: 800 20px Arial, sans-serif; fill: #0f172a; }
      .sectionText { font: 800 17px Arial, sans-serif; fill: #ffffff; letter-spacing: .3px; }
      .cellText { font: 18px Arial, sans-serif; fill: #243244; }
      .actionText { font: 800 18px Arial, sans-serif; fill: #0f172a; }
      .numberText { font: 800 20px Arial, sans-serif; fill: #ffffff; }
      .legend { font: 16px Arial, sans-serif; fill: #475569; }
    </style>
  </defs>
  <rect width="${W}" height="${H}" fill="#f8fafc"/>
  <rect x="42" y="42" width="${W - 84}" height="${H - 84}" rx="32" ry="32" fill="#ffffff" stroke="#e2e8f0" stroke-width="2"/>
  <text x="${W / 2}" y="96" text-anchor="middle" class="title">Application Flow: Our System, Polaris, and Response Actions</text>
  <text x="${W / 2}" y="132" text-anchor="middle" class="subtitle">Generated from app_flow.mmd. Each row shows the user/system action, local database/process work, Polaris or external integration work, and final response state.</text>
`);

const headerY = top;
const headerFill = '#e2e8f0';
[
  ['#', x.no, w.no],
  [headers[0], x.action, w.action],
  [headers[1], x.our, w.our],
  [headers[2], x.polaris, w.polaris],
  [headers[3], x.response, w.response],
].forEach(([label, tx, tw]) => {
  parts.push(`<rect x="${tx}" y="${headerY}" width="${tw}" height="${headerH}" rx="14" ry="14" fill="${headerFill}" stroke="#cbd5e1" stroke-width="1.6"/>`);
  parts.push(`<text x="${tx + tw / 2}" y="${headerY + 40}" text-anchor="middle" class="headerText">${esc(label)}</text>`);
});

let lastSection = null;
for (const model of rowModels) {
  const rowY = model.y;
  if (model.sectionBreak) {
    parts.push(`<rect x="${margin}" y="${rowY - 36}" width="${W - margin * 2}" height="28" rx="10" ry="10" fill="${model.color}"/>`);
    parts.push(`<text x="${W / 2}" y="${rowY - 16}" text-anchor="middle" class="sectionText">${esc(model.section.toUpperCase())}</text>`);
    lastSection = model.section;
  }

  parts.push(`<g filter="url(#shadow)">`);
  parts.push(`<rect x="${margin}" y="${rowY - 8}" width="${W - margin * 2}" height="${model.h + 16}" rx="22" ry="22" fill="#f8fafc" stroke="#e2e8f0" stroke-width="1.2"/>`);
  parts.push(`<rect x="${x.no}" y="${rowY}" width="${w.no}" height="${model.h}" rx="16" ry="16" fill="${model.color}" stroke="${model.color}" stroke-width="1.8"/>`);
  parts.push(`<text x="${x.no + w.no / 2}" y="${rowY + model.h / 2 + 7}" text-anchor="middle" class="numberText">${String(model.idx + 1).padStart(2, '0')}</text>`);
  parts.push(card(x.action, rowY, w.action, model.h, '#ffffff', model.color, model.lines.action, 'actionText'));
  parts.push(card(x.our, rowY, w.our, model.h, '#ffffff', '#64748b', model.lines.our));
  parts.push(card(x.polaris, rowY, w.polaris, model.h, '#ecfeff', '#0891b2', model.lines.polaris));
  parts.push(card(x.response, rowY, w.response, model.h, '#f0fdf4', '#16a34a', model.lines.response));
  parts.push(`</g>`);

  if (model.idx < rowModels.length - 1) {
    const next = rowModels[model.idx + 1];
    const startX = x.no + w.no / 2;
    const startY = rowY + model.h + 8;
    const endY = next.y - 10;
    if (endY > startY + 8) {
      parts.push(`<path d="M${startX},${startY} C${startX},${(startY + endY) / 2} ${startX},${(startY + endY) / 2} ${startX},${endY}" fill="none" stroke="#334155" stroke-width="2.2" marker-end="url(#arrow)"/>`);
    }
  }
}

parts.push(`<text x="${W / 2}" y="${H - 76}" text-anchor="middle" class="legend">Status rule: failed = confirmed failure; pending_reconcile = unknown Polaris result; dead_letter = unresolved after automated reconciliation.</text>`);
parts.push('</svg>\n');

fs.writeFileSync(svgPath, parts.join('\n'));
console.log(svgPath);
