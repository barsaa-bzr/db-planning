#!/usr/bin/env node
/**
 * generate-erd.js
 * Usage: node generate-erd.js <schema.sql> [output.html]
 * Parses a PostgreSQL schema and emits a standalone interactive ERD.
 */

const fs = require('fs');
const path = require('path');

// ─── CLI ───────────────────────────────────────────────────────────────────
const sqlFile  = process.argv[2];
const outFile  = process.argv[3] || 'erd_output.html';

if (!sqlFile) {
  console.error('Usage: node generate-erd.js <schema.sql> [output.html]');
  process.exit(1);
}

const sql = fs.readFileSync(sqlFile, 'utf8');

// ─── PARSER ────────────────────────────────────────────────────────────────

function parseSchema(sql) {
  const clean = stripSqlComments(sql);
  const enums = parseEnums(clean);
  const tables = parseTables(clean, enums);
  const indexes = parseIndexes(clean);
  const views = parseViews(clean, Object.keys(tables));

  for (const [tableName, table] of Object.entries(tables)) {
    table.indexes = indexes[tableName] || [];
    table.views = Object.values(views).filter(v => v.referencedTables.includes(tableName));
  }

  return { tables, enums, indexes, views };
}

function parseTables(sql, enums = {}) {
  const tables = {};

  // Match CREATE TABLE blocks (non-partitioned child tables excluded)
  const tableRe = /CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)\s*\(([^;]+?)\)\s*(?:PARTITION\s+BY[^;]+)?;/gis;
  let m;
  while ((m = tableRe.exec(sql)) !== null) {
    const tableName = m[1];
    // Skip partition child tables (they inherit from parent)
    if (/PARTITION\s+OF/i.test(m[0])) continue;

    const body = m[2];
    const columns = [];
    const foreignKeys = [];
    const constraints = [];

    // Split body into top-level comma-separated clauses
    const clauses = splitTopLevel(body);

    for (const clause of clauses) {
      const c = clause.trim();
      if (!c) continue;

      const constraintName = /^\s*CONSTRAINT\s+(\w+)\s+/i.exec(c)?.[1] || null;
      const normalizedConstraint = c.replace(/^\s*CONSTRAINT\s+\w+\s+/i, '');

      // Table-level FOREIGN KEY
      const fkInline = /FOREIGN\s+KEY\s*\(([^)]+)\)\s*REFERENCES\s+(\w+)\s*(?:\(([^)]+)\))?/i.exec(normalizedConstraint);
      if (fkInline) {
        const columnsInFk = csvNames(fkInline[1]);
        const refColumns = fkInline[3] ? csvNames(fkInline[3]) : ['id'];
        const actions = parseReferentialActions(normalizedConstraint);
        const fk = {
          name: constraintName,
          columns: columnsInFk,
          refTable: fkInline[2],
          refColumns,
          onDelete: actions.onDelete,
          onUpdate: actions.onUpdate,
        };
        foreignKeys.push(fk);
        constraints.push({ type: 'FOREIGN KEY', name: constraintName, columns: columnsInFk, refTable: fk.refTable, refColumns, onDelete: fk.onDelete, onUpdate: fk.onUpdate });
        continue;
      }

      // Table-level PRIMARY KEY / UNIQUE / CHECK constraints
      const pkConstraint = /^PRIMARY\s+KEY\s*\(([^)]+)\)/i.exec(normalizedConstraint);
      if (pkConstraint) {
        constraints.push({ type: 'PRIMARY KEY', name: constraintName, columns: csvNames(pkConstraint[1]) });
        continue;
      }
      const uqConstraint = /^UNIQUE\s*\(([^)]+)\)/i.exec(normalizedConstraint);
      if (uqConstraint) {
        constraints.push({ type: 'UNIQUE', name: constraintName, columns: csvNames(uqConstraint[1]) });
        continue;
      }
      const checkConstraint = /^CHECK\s*\(([\s\S]+)\)$/i.exec(normalizedConstraint);
      if (checkConstraint) {
        constraints.push({ type: 'CHECK', name: constraintName, expression: checkConstraint[1].trim() });
        continue;
      }
      if (/^\s*CONSTRAINT\b/i.test(c)) continue;

      // Column definition
      const colMatch = /^(\w+)\s+(.+)$/s.exec(c);
      if (!colMatch) continue;

      const colName = colMatch[1];
      const rest    = colMatch[2];

      // Extract type (up to first constraint keyword)
      const typeMatch = rest.match(/^([A-Z][\w(),.'"\s]*?)(?:\s+(?:NOT\s+NULL|NULL|DEFAULT|PRIMARY|UNIQUE|REFERENCES|GENERATED|CHECK|COLLATE)\b|$)/i);
      const colType   = typeMatch ? typeMatch[1].trim() : rest.split(/\s+/)[0];
      const normalizedType = normalizeType(colType);

      const isPK      = /PRIMARY\s+KEY/i.test(rest);
      const isNotNull = /NOT\s+NULL/i.test(rest);
      const isUnique  = /UNIQUE/i.test(rest);
      const defaultValue = parseDefault(rest);
      const generated = parseGenerated(rest);
      const checks = Array.from(rest.matchAll(/CHECK\s*\(([^)]+)\)/gi)).map(x => x[1].trim());
      const enumName = Object.prototype.hasOwnProperty.call(enums, normalizedType) ? normalizedType : null;

      // Inline REFERENCES
      const refMatch = /REFERENCES\s+(\w+)\s*(?:\(([^)]+)\))?/i.exec(rest);
      let fk = null;
      if (refMatch) {
        const actions = parseReferentialActions(rest);
        fk = {
          refTable: refMatch[1],
          refColumn: refMatch[2] ? refMatch[2].trim() : 'id',
          onDelete: actions.onDelete,
          onUpdate: actions.onUpdate,
        };
        const fkRecord = {
          columns: [colName],
          refTable: refMatch[1],
          refColumns: [refMatch[2] ? refMatch[2].trim() : 'id'],
          onDelete: actions.onDelete,
          onUpdate: actions.onUpdate,
        };
        foreignKeys.push(fkRecord);
        constraints.push({ type: 'FOREIGN KEY', name: null, columns: [colName], refTable: fkRecord.refTable, refColumns: fkRecord.refColumns, onDelete: fkRecord.onDelete, onUpdate: fkRecord.onUpdate });
      }

      columns.push({
        name: colName,
        type: normalizedType,
        rawDefinition: rest.replace(/\s+/g, ' ').trim(),
        isPK,
        isNotNull,
        isUnique,
        fk,
        defaultValue,
        isGenerated: Boolean(generated),
        generatedExpression: generated?.expression || null,
        generatedStorage: generated?.storage || null,
        enumName,
        enumValues: enumName ? enums[enumName] : null,
        checks,
      });
    }

    for (const constraint of constraints) {
      if (!constraint.columns) continue;
      for (const columnName of constraint.columns) {
        const col = columns.find(x => x.name === columnName);
        if (!col) continue;
        if (constraint.type === 'PRIMARY KEY') col.isPK = true;
        if (constraint.type === 'UNIQUE') col.uniqueGroup = constraint.columns;
      }
    }

    tables[tableName] = { columns, foreignKeys, constraints, indexes: [], views: [] };
  }

  return tables;
}

function splitTopLevel(str) {
  const parts = [];
  let depth = 0, current = '';
  let quote = null;
  for (let i = 0; i < str.length; i++) {
    const ch = str[i];
    const next = str[i + 1];

    if (quote) {
      current += ch;
      if (ch === quote && next === quote) {
        current += next;
        i++;
        continue;
      }
      if (ch === quote) quote = null;
      continue;
    }

    if (ch === '\'' || ch === '"') {
      quote = ch;
      current += ch;
      continue;
    }

    if (ch === '(') depth++;
    else if (ch === ')') depth--;
    else if (ch === ',' && depth === 0) {
      parts.push(current);
      current = '';
      continue;
    }
    current += ch;
  }
  if (current.trim()) parts.push(current);
  return parts;
}

function stripSqlComments(input) {
  return input
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/--[^\n]*/g, '');
}

function csvNames(str) {
  return splitTopLevel(str).map(s => s.trim().replace(/^"|"$/g, '')).filter(Boolean);
}

function unquoteSqlString(value) {
  const trimmed = value.trim();
  if (trimmed.startsWith("'") && trimmed.endsWith("'")) {
    return trimmed.slice(1, -1).replace(/''/g, "'");
  }
  return trimmed;
}

function parseEnums(sql) {
  const enums = {};
  const enumRe = /CREATE\s+TYPE\s+(\w+)\s+AS\s+ENUM\s*\(([\s\S]*?)\)\s*;/gi;
  let m;
  while ((m = enumRe.exec(sql)) !== null) {
    enums[m[1]] = splitTopLevel(m[2]).map(unquoteSqlString);
  }
  return enums;
}

function parseDefault(rest) {
  const m = /\bDEFAULT\s+([\s\S]+?)(?=\s+(?:NOT\s+NULL|NULL|PRIMARY\s+KEY|UNIQUE|REFERENCES|CHECK|GENERATED|COLLATE)\b|$)/i.exec(rest);
  return m ? m[1].replace(/\s+/g, ' ').trim() : null;
}

function parseGenerated(rest) {
  const m = /\bGENERATED\s+ALWAYS\s+AS\s*\(([\s\S]+?)\)\s*(STORED|VIRTUAL)?/i.exec(rest);
  if (!m) return null;
  return { expression: m[1].replace(/\s+/g, ' ').trim(), storage: (m[2] || '').toUpperCase() || null };
}

function parseReferentialActions(rest) {
  return {
    onDelete: /\bON\s+DELETE\s+(CASCADE|RESTRICT|SET\s+NULL|SET\s+DEFAULT|NO\s+ACTION)\b/i.exec(rest)?.[1].toUpperCase().replace(/\s+/g, ' ') || null,
    onUpdate: /\bON\s+UPDATE\s+(CASCADE|RESTRICT|SET\s+NULL|SET\s+DEFAULT|NO\s+ACTION)\b/i.exec(rest)?.[1].toUpperCase().replace(/\s+/g, ' ') || null,
  };
}

function parseIndexes(sql) {
  const byTable = {};
  const indexRe = /CREATE\s+(UNIQUE\s+)?INDEX\s+(?:CONCURRENTLY\s+)?(?:IF\s+NOT\s+EXISTS\s+)?(\w+)\s+ON\s+(\w+)(?:\s+USING\s+(\w+))?\s*\(([\s\S]*?)\)\s*(?:WHERE\s+([\s\S]*?))?\s*;/gi;
  let m;
  while ((m = indexRe.exec(sql)) !== null) {
    const idx = {
      name: m[2],
      table: m[3],
      unique: Boolean(m[1]),
      method: (m[4] || 'btree').toLowerCase(),
      columns: splitTopLevel(m[5]).map(s => s.trim()),
      where: m[6] ? m[6].replace(/\s+/g, ' ').trim() : null,
    };
    if (!byTable[idx.table]) byTable[idx.table] = [];
    byTable[idx.table].push(idx);
  }
  return byTable;
}

function parseViews(sql, tableNames) {
  const views = {};
  const viewRe = /CREATE\s+(?:OR\s+REPLACE\s+)?VIEW\s+(\w+)\s+AS\s+([\s\S]*?)\s*;/gi;
  let m;
  while ((m = viewRe.exec(sql)) !== null) {
    const definition = m[2].replace(/\s+/g, ' ').trim();
    const referencedTables = tableNames.filter(name => new RegExp(`\\b${escapeRegex(name)}\\b`, 'i').test(definition));
    views[m[1]] = { name: m[1], definition, referencedTables };
  }
  return views;
}

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function normalizeType(t) {
  return t.replace(/\s+/g, ' ').trim()
    .replace(/CHARACTER VARYING/i, 'VARCHAR')
    .replace(/TIMESTAMP WITH TIME ZONE/i, 'TIMESTAMPTZ')
    .replace(/TIMESTAMP WITHOUT TIME ZONE/i, 'TIMESTAMP');
}

// ─── DOMAIN DETECTION ──────────────────────────────────────────────────────

const DOMAINS = [
  { id: 'auth',     label: 'Users & Auth',        color: '#4f8ef7', tables: ['users','customer_profiles','merchant_profiles','staff_profiles','customer_pin_credentials','customer_biometric_credentials','otp_sessions','user_sessions','customer_transaction_authorizations'], prefixes: ['user_','otp_','staff_'] },
  { id: 'kyc',      label: 'KYC & 3rd-Party',     color: '#a78bfa', tables: ['nationalities','customer_bank_accounts','dan_verifications','hur_data_snapshots','sain_score_requests','kyc_verification_steps'], prefixes: ['kyc_','dan_','hur_','sain_','customer_bank_'] },
  { id: 'credit',   label: 'Credit & Limits',      color: '#34d399', tables: ['credit_score_results','credit_scoring_factors','loan_limits'], prefixes: ['credit_','loan_limit'] },
  { id: 'loans',    label: 'Loans & Products',     color: '#f59e0b', tables: ['loan_products','loan_product_duration_options','bnpl_installment_options','loan_applications','loans','loan_account_mappings','loan_application_status_history','loan_status_history'], prefixes: ['loan_','bnpl_installment_'] },
  { id: 'pos',      label: 'POS Flow',             color: '#f97316', tables: ['pos_terminals','pos_payment_invoices','pos_qr_codes','pos_transactions','pos_terminal_callbacks'], prefixes: ['pos_'] },
  { id: 'repay',    label: 'Repayment, QPay & Cashback', color: '#ec4899', tables: ['repayment_cashback_configs','repayment_schedules','qpay_repayment_invoices','qpay_repayment_callbacks','repayment_transactions','penalty_records','customer_cashback_wallets','customer_cashback_wallet_transactions','repayment_cashback_records','repayment_schedule_status_history','repayment_transaction_status_history'], prefixes: ['repayment_','qpay_','penalty_','customer_cashback_'] },
  { id: 'polaris',  label: 'Polaris & Ledger',     color: '#06b6d4', tables: ['polaris_accounts','ledger_journals','ledger_entries','polaris_api_logs','polaris_sync_queue'], prefixes: ['polaris_','ledger_'] },
  { id: 'merchant', label: 'Merchant Portal',      color: '#84cc16', tables: ['merchant_portal_users','merchant_refund_requests','merchant_return_items','merchant_settlements','merchant_refund_status_history','merchant_settlement_status_history'], prefixes: ['merchant_'] },
  { id: 'audit',    label: 'Audit & Notifications',color: '#94a3b8', tables: ['message_logs','audit_logs','staff_action_reviews','service_pause_windows','notification_templates','notification_logs','system_event_logs'], prefixes: ['audit_','notification_','system_','service_pause_','message_'] },
];

function getDomain(tableName) {
  for (const d of DOMAINS) {
    if (d.tables.includes(tableName)) return d;
  }
  for (const d of DOMAINS) {
    if ((d.prefixes || []).some(prefix => tableName.startsWith(prefix))) return d;
  }
  return { id: 'other', label: 'Other', color: '#64748b' };
}

// ─── LAYOUT ────────────────────────────────────────────────────────────────
// Place tables in a grid grouped by domain, with some spacing

function layoutTables(tables) {
  const positions = {};
  const CARD_W = 260, CARD_H_BASE = 74, ROW_H = 26;
  const HEADER_H = 44, COL_GAP = 44, ROW_GAP = 36;
  const GROUP_GAP_X = 120, GROUP_GAP_Y = 120;
  const GROUPS_PER_ROW = 3;

  // Group by domain
  const groups = {};
  for (const name of Object.keys(tables)) {
    const d = getDomain(name);
    if (!groups[d.id]) groups[d.id] = { domain: d, tables: [] };
    groups[d.id].tables.push(name);
  }

  let rowX = 60, rowY = 90, rowHeight = 0, groupIndexInRow = 0;
  const orderedGroupIds = [
    ...DOMAINS.map(d => d.id).filter(id => groups[id]),
    ...Object.keys(groups).filter(id => !DOMAINS.some(d => d.id === id)).sort(),
  ];

  for (const gid of orderedGroupIds) {
    const grp = groups[gid];
    const colCount = Math.min(grp.tables.length, grp.tables.length >= 9 ? 3 : 2);
    const colHeights = Array(colCount).fill(0);

    for (const name of grp.tables) {
      const col = colHeights.indexOf(Math.min(...colHeights));
      const h = CARD_H_BASE + tables[name].columns.length * ROW_H;
      const x = rowX + col * (CARD_W + COL_GAP);
      const y = rowY + HEADER_H + colHeights[col];
      positions[name] = { x, y, w: CARD_W, h };
      colHeights[col] += h + ROW_GAP;
    }

    const groupWidth = colCount * CARD_W + (colCount - 1) * COL_GAP;
    const groupHeight = HEADER_H + Math.max(...colHeights, 0);
    rowHeight = Math.max(rowHeight, groupHeight);
    groupIndexInRow++;

    if (groupIndexInRow >= GROUPS_PER_ROW) {
      rowX = 60;
      rowY += rowHeight + GROUP_GAP_Y;
      rowHeight = 0;
      groupIndexInRow = 0;
    } else {
      rowX += groupWidth + GROUP_GAP_X;
    }
  }

  return positions;
}

// ─── MAIN ──────────────────────────────────────────────────────────────────

const schema = parseSchema(sql);
const { tables, enums, indexes, views } = schema;
const tableNames = Object.keys(tables);
console.log(`Parsed ${tableNames.length} tables.`);
console.log(`Found ${Object.keys(enums).length} enum types, ${Object.values(indexes).reduce((sum, list) => sum + list.length, 0)} indexes, ${Object.keys(views).length} views.`);

// Build FK edge list
const edges = [];
for (const [tname, tdata] of Object.entries(tables)) {
  for (const fk of tdata.foreignKeys) {
    if (tables[fk.refTable]) {
      edges.push({ from: tname, to: fk.refTable, cols: fk.columns, refCols: fk.refColumns, onDelete: fk.onDelete || null, onUpdate: fk.onUpdate || null });
    }
  }
}
console.log(`Found ${edges.length} foreign key relationships.`);

const positions = layoutTables(tables);

// ─── HTML GENERATION ───────────────────────────────────────────────────────

const tableData   = JSON.stringify(tables);
const enumData    = JSON.stringify(enums);
const indexData   = JSON.stringify(indexes);
const viewData    = JSON.stringify(views);
const posData     = JSON.stringify(positions);
const edgeData    = JSON.stringify(edges);
const domainData  = JSON.stringify(DOMAINS);
const originalSqlData = JSON.stringify(sql);

const html = /* html */`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1.0"/>
<title>ERD — BZR App Schema</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600&family=Syne:wght@700;800&display=swap');

  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  :root {
    --bg: #0b0f1a;
    --surface: #111827;
    --surface2: #1a2235;
    --border: #1e2d42;
    --text: #e2e8f0;
    --text-muted: #64748b;
    --accent: #4f8ef7;
    --header-h: 52px;
  }

  body {
    background: var(--bg);
    color: var(--text);
    font-family: 'JetBrains Mono', monospace;
    overflow: hidden;
    height: 100vh;
    width: 100vw;
    user-select: none;
  }

  /* ── HEADER ── */
  #header {
    position: fixed; top: 0; left: 0; right: 0; height: var(--header-h);
    background: rgba(11,15,26,0.92); backdrop-filter: blur(12px);
    border-bottom: 1px solid var(--border);
    display: flex; align-items: center; gap: 24px;
    padding: 0 20px; z-index: 100;
  }
	  #header h1 { font-family: 'Syne', sans-serif; font-size: 17px; font-weight: 800; letter-spacing: 0.04em; color: #fff; white-space: nowrap; }
	  #header h1 span { color: var(--accent); }
	  .stat-pill { background: var(--surface2); border: 1px solid var(--border); border-radius: 6px; padding: 3px 10px; font-size: 11px; color: var(--text-muted); }
	  .stat-pill b { color: var(--text); }

  /* ── TOOLBAR ── */
  #toolbar {
    position: fixed; bottom: 20px; left: 50%; transform: translateX(-50%);
    background: rgba(17,24,39,0.95); backdrop-filter: blur(16px);
    border: 1px solid var(--border); border-radius: 14px;
    display: flex; align-items: center; gap: 4px; padding: 6px;
    z-index: 100; box-shadow: 0 8px 32px rgba(0,0,0,0.5);
  }
  .tool-btn {
    background: none; border: none; cursor: pointer;
    color: var(--text-muted); border-radius: 8px;
    padding: 7px 12px; font-size: 12px; font-family: inherit;
    transition: all 0.15s; display: flex; align-items: center; gap: 6px;
  }
  .tool-btn:hover { background: var(--surface2); color: var(--text); }
  .tool-btn.active { background: var(--accent); color: #fff; }
  .tool-divider { width: 1px; height: 24px; background: var(--border); margin: 0 4px; }

  /* ── LEGEND ── */
  #legend {
    position: fixed; top: calc(var(--header-h) + 12px); right: 14px;
    background: rgba(17,24,39,0.95); backdrop-filter: blur(12px);
    border: 1px solid var(--border); border-radius: 10px;
    padding: 12px 14px; z-index: 100; max-height: calc(100vh - 100px); overflow-y: auto;
  }
  #legend h3 { font-size: 10px; font-weight: 600; letter-spacing: 0.1em; color: var(--text-muted); margin-bottom: 8px; text-transform: uppercase; }
  .legend-item { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; cursor: pointer; padding: 3px 6px; border-radius: 5px; transition: background 0.1s; }
  .legend-item:hover { background: var(--surface2); }
  .legend-dot { width: 10px; height: 10px; border-radius: 3px; flex-shrink: 0; }
  .legend-label { font-size: 11px; color: var(--text-muted); white-space: nowrap; transition: color 0.1s; }
  .legend-item:hover .legend-label { color: var(--text); }
  .legend-item.active-filter .legend-label { color: var(--text); }

  /* ── CANVAS AREA ── */
  #canvas-wrap {
    position: fixed; top: var(--header-h); left: 0; right: 0; bottom: 0;
    overflow: hidden; cursor: grab;
  }
  #canvas-wrap.panning { cursor: grabbing; }

  #canvas {
    position: absolute;
    transform-origin: 0 0;
  }

  /* SVG edges */
  #edge-layer { position: absolute; top: 0; left: 0; pointer-events: none; overflow: visible; }

  .edge-path { fill: none; stroke-width: 1.5px; opacity: 0.35; transition: opacity 0.2s, stroke-width 0.2s; }
  .edge-path:hover { opacity: 1; stroke-width: 2.5px; }
  .edge-path.highlighted { opacity: 0.9; stroke-width: 2px; }
  .edge-path.dimmed { opacity: 0.05; }

  .domain-label {
    position: absolute;
    height: 28px;
    display: flex; align-items: center; gap: 8px;
    color: var(--text); font-size: 12px; font-weight: 600;
    letter-spacing: 0.02em; pointer-events: none;
    text-shadow: 0 2px 12px rgba(0,0,0,0.8);
  }
  .domain-label::before {
    content: ''; width: 12px; height: 12px; border-radius: 4px;
    background: currentColor; box-shadow: 0 0 0 4px rgba(255,255,255,0.03);
  }
  .domain-label span { color: var(--text-muted); font-size: 10px; font-weight: 400; }

  /* ── TABLE CARDS ── */
  .table-card {
    position: absolute;
    background: var(--surface);
    border: 1.5px solid var(--border);
    border-radius: 10px;
    overflow: hidden;
    width: 260px;
    box-shadow: 0 4px 24px rgba(0,0,0,0.4);
    cursor: default;
    transition: box-shadow 0.2s, border-color 0.2s, opacity 0.2s;
    will-change: transform;
  }
  .table-card:hover { box-shadow: 0 8px 40px rgba(0,0,0,0.6); }
  .table-card.selected { border-color: var(--accent); box-shadow: 0 0 0 2px rgba(79,142,247,0.35), 0 8px 40px rgba(0,0,0,0.6); }
  .table-card.dimmed { opacity: 0.12; }
  .table-card.highlighted { border-color: currentColor; opacity: 1; }

  .card-header {
    display: flex; align-items: center; justify-content: space-between;
    padding: 9px 12px 8px;
    border-bottom: 1px solid var(--border);
    cursor: move;
  }
  .card-title { font-size: 12px; font-weight: 600; color: #fff; letter-spacing: 0.02em; }
  .card-domain-dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
  .col-count { font-size: 10px; color: var(--text-muted); }

  .card-columns { padding: 4px 0; }
  .col-row {
    display: flex; align-items: center; gap: 6px;
    padding: 3px 12px;
    font-size: 10.5px;
    border-bottom: 1px solid rgba(255,255,255,0.03);
    transition: background 0.1s;
  }
  .col-row:last-child { border-bottom: none; }
  .col-row:hover { background: var(--surface2); }
  .col-name { color: var(--text); flex: 1; }
  .col-type { color: var(--text-muted); font-size: 9.5px; text-align: right; max-width: 110px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
	  .badge { font-size: 8.5px; padding: 1px 4px; border-radius: 3px; font-weight: 600; flex-shrink: 0; }
	  .badge-pk { background: rgba(79,142,247,0.25); color: #93c5fd; }
	  .badge-fk { background: rgba(249,115,22,0.2); color: #fb923c; }
	  .badge-nn { background: rgba(52,211,153,0.15); color: #6ee7b7; }
	  .badge-uq { background: rgba(167,139,250,0.2); color: #c4b5fd; }
	  .badge-en { background: rgba(236,72,153,0.18); color: #f9a8d4; }
	  .badge-def { background: rgba(234,179,8,0.16); color: #fde68a; }
	  .badge-gen { background: rgba(6,182,212,0.18); color: #67e8f9; }
	  .badge-idx { background: rgba(148,163,184,0.16); color: #cbd5e1; }
	  .badge-del { background: rgba(248,113,113,0.16); color: #fca5a5; }

  /* ── SEARCH ── */
  #search-wrap {
    position: fixed; top: calc(var(--header-h) + 12px); left: 14px;
    z-index: 100;
  }
  #search {
    background: rgba(17,24,39,0.95); border: 1px solid var(--border);
    border-radius: 8px; padding: 8px 12px;
    color: var(--text); font-family: inherit; font-size: 12px;
    width: 200px; outline: none;
    transition: border-color 0.15s;
  }
  #search::placeholder { color: var(--text-muted); }
  #search:focus { border-color: var(--accent); }

  /* ── DETAIL PANEL ── */
	  #detail-panel {
	    position: fixed; top: var(--header-h); left: -500px;
	    width: 480px; bottom: 0;
	    background: rgba(17,24,39,0.97); backdrop-filter: blur(16px);
	    border-right: 1px solid var(--border);
	    padding: 16px; z-index: 99;
	    transition: left 0.25s cubic-bezier(0.4,0,0.2,1);
	    overflow-y: auto;
	  }
	  #detail-panel.open { left: 0; }
	  #detail-panel h2 { font-family: 'Syne', sans-serif; font-size: 15px; margin-bottom: 4px; }
	  #detail-panel .dp-domain { font-size: 10px; color: var(--text-muted); margin-bottom: 12px; }
	  #detail-panel h3 { font-size: 10px; letter-spacing: 0.1em; text-transform: uppercase; color: var(--text-muted); margin: 12px 0 6px; }
	  .dp-summary { display: grid; grid-template-columns: repeat(3, 1fr); gap: 6px; margin-bottom: 12px; }
	  .dp-stat { background: rgba(26,34,53,0.75); border: 1px solid var(--border); border-radius: 7px; padding: 7px 8px; }
	  .dp-stat b { display: block; color: var(--text); font-size: 13px; }
	  .dp-stat span { color: var(--text-muted); font-size: 9px; text-transform: uppercase; letter-spacing: 0.08em; }
	  .dp-col { padding: 8px 0; border-bottom: 1px solid var(--border); display: flex; align-items: flex-start; gap: 6px; flex-wrap: wrap; }
	  .dp-col:last-child { border-bottom: none; }
	  .dp-col-name { font-size: 11px; flex: 1; }
	  .dp-col-type { font-size: 10px; color: var(--text-muted); width: 100%; padding-left: 0; }
	  .dp-meta { width: 100%; display: grid; gap: 4px; margin-top: 2px; }
	  .dp-meta-line { color: var(--text-muted); font-size: 10px; line-height: 1.45; word-break: break-word; }
	  .dp-meta-line b { color: var(--text); font-weight: 600; }
	  .dp-enum-values { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 4px; }
	  .dp-enum-value { background: rgba(236,72,153,0.14); color: #f9a8d4; border: 1px solid rgba(236,72,153,0.22); border-radius: 999px; padding: 1px 6px; font-size: 9px; }
	  .dp-fk-list { margin-top: 4px; }
	  .dp-fk { font-size: 10px; color: var(--accent); padding: 5px 0; cursor: pointer; border-bottom: 1px solid rgba(255,255,255,0.04); }
	  .dp-fk:hover { text-decoration: underline; }
	  .dp-card { background: rgba(26,34,53,0.55); border: 1px solid var(--border); border-radius: 7px; padding: 8px; margin-bottom: 6px; font-size: 10px; color: var(--text-muted); line-height: 1.45; word-break: break-word; }
	  .dp-card-title { color: var(--text); font-weight: 600; margin-bottom: 3px; }
	  .dp-empty { color: var(--text-muted); font-size: 10px; }
	  #close-detail { position: absolute; top: 12px; right: 12px; background: none; border: none; color: var(--text-muted); cursor: pointer; font-size: 16px; }
	  #close-detail:hover { color: var(--text); }

  /* mini map */
  #minimap {
    position: fixed; bottom: 70px; right: 14px;
    width: 160px; height: 100px;
    background: rgba(17,24,39,0.9); border: 1px solid var(--border);
    border-radius: 8px; overflow: hidden; z-index: 100;
  }
  #minimap canvas { width: 100%; height: 100%; }

  /* ── EDITOR ── */
  #editor-panel {
    position: fixed; top: var(--header-h); right: -560px;
    width: 540px; bottom: 0;
    background: rgba(17,24,39,0.98); backdrop-filter: blur(16px);
    border-left: 1px solid var(--border);
    z-index: 101; transition: right 0.25s cubic-bezier(0.4,0,0.2,1);
    display: grid; grid-template-rows: auto auto 1fr auto;
    box-shadow: -12px 0 40px rgba(0,0,0,0.35);
  }
  #editor-panel.open { right: 0; }
  .editor-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 14px 16px; border-bottom: 1px solid var(--border); }
  .editor-title { font-family: 'Syne', sans-serif; font-size: 15px; font-weight: 800; color: #fff; }
  .editor-note { color: var(--text-muted); font-size: 10px; line-height: 1.45; padding: 10px 16px; border-bottom: 1px solid var(--border); }
  .editor-tabs { display: flex; gap: 4px; padding: 10px 16px 0; }
  .editor-tab { border: 1px solid var(--border); background: var(--surface2); color: var(--text-muted); border-radius: 7px; padding: 6px 10px; font: inherit; font-size: 11px; cursor: pointer; }
  .editor-tab.active { background: var(--accent); color: #fff; border-color: var(--accent); }
  .editor-body { min-height: 0; overflow: auto; padding: 10px 16px 16px; }
  .editor-pane { display: none; height: 100%; }
  .editor-pane.active { display: block; }
  #sql-editor {
    width: 100%; height: calc(100vh - 255px); min-height: 360px; resize: none;
    background: #070b13; color: var(--text); border: 1px solid var(--border);
    border-radius: 8px; padding: 12px; font: 11px/1.55 'JetBrains Mono', monospace;
    outline: none; user-select: text;
  }
  #sql-editor:focus { border-color: var(--accent); }
  .editor-status { min-height: 18px; margin-top: 8px; font-size: 10px; color: var(--text-muted); }
  .editor-status.error { color: #fca5a5; }
  .editor-status.ok { color: #6ee7b7; }
  .form-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; align-items: end; }
  .form-grid .full { grid-column: 1 / -1; }
  .form-field { display: grid; gap: 5px; }
  .form-field.full { grid-column: 1 / -1; }
  .form-field label { font-size: 9px; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.08em; }
  .form-field input, .form-field select {
    width: 100%; background: #070b13; color: var(--text); border: 1px solid var(--border);
    border-radius: 7px; padding: 8px 9px; font: 11px 'JetBrains Mono', monospace; outline: none;
  }
  .form-field input:focus, .form-field select:focus { border-color: var(--accent); }
  .check-row { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; padding: 10px 0; }
  .check-row label { display: flex; align-items: center; gap: 6px; color: var(--text-muted); font-size: 10px; }
  .check-row input { accent-color: var(--accent); }
  .editor-actions { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 12px 16px; border-top: 1px solid var(--border); }
  .editor-actions-group { display: flex; gap: 8px; flex-wrap: wrap; }
  .editor-btn {
    border: 1px solid var(--border); background: var(--surface2); color: var(--text);
    border-radius: 7px; padding: 7px 10px; font: inherit; font-size: 11px; cursor: pointer;
  }
  .editor-btn:hover { border-color: var(--accent); }
  .editor-btn.primary { background: var(--accent); border-color: var(--accent); color: #fff; }
  .editor-empty { color: var(--text-muted); font-size: 11px; line-height: 1.5; padding: 12px; border: 1px dashed var(--border); border-radius: 8px; }
</style>
</head>
<body>

<div id="header">
  <h1>ERD <span>//</span> BZR App</h1>
  <div class="stat-pill">Tables: <b id="stat-tables">0</b></div>
  <div class="stat-pill">Relationships: <b id="stat-edges">0</b></div>
  <div class="stat-pill">Columns: <b id="stat-cols">0</b></div>
  <div class="stat-pill">Enums: <b id="stat-enums">0</b></div>
  <div class="stat-pill">Indexes: <b id="stat-indexes">0</b></div>
  <div class="stat-pill">Views: <b id="stat-views">0</b></div>
</div>

<div id="search-wrap">
  <input id="search" type="text" placeholder="🔍  Search tables…" autocomplete="off"/>
</div>

<div id="legend">
  <h3>Domains</h3>
  <div id="legend-items"></div>
</div>

<div id="canvas-wrap">
  <div id="canvas">
    <svg id="edge-layer"></svg>
  </div>
</div>

<div id="detail-panel">
  <button id="close-detail">✕</button>
  <h2 id="dp-title">—</h2>
  <div class="dp-domain" id="dp-domain">—</div>
  <div id="dp-summary" class="dp-summary"></div>
  <h3>Columns</h3>
  <div id="dp-cols"></div>
  <h3>Table constraints</h3>
  <div id="dp-constraints"></div>
  <h3>Indexes</h3>
  <div id="dp-indexes"></div>
  <h3>References</h3>
  <div id="dp-fks" class="dp-fk-list"></div>
  <h3>Referenced by</h3>
  <div id="dp-ref-by" class="dp-fk-list"></div>
  <h3>Views using this table</h3>
  <div id="dp-views"></div>
</div>

<div id="editor-panel">
  <div class="editor-head">
    <div class="editor-title">Schema Editor</div>
    <button class="editor-btn" id="close-editor">Close</button>
  </div>
  <div class="editor-note" id="editor-note">
    Static mode cannot overwrite the source SQL file directly. Use Download SQL to export the edited schema as <b>lending_app_schema.updated.sql</b>.
  </div>
  <div class="editor-tabs">
    <button class="editor-tab active" data-editor-tab="sql">SQL</button>
    <button class="editor-tab" data-editor-tab="form">Table Form</button>
  </div>
  <div class="editor-body">
    <div class="editor-pane active" id="editor-pane-sql">
      <textarea id="sql-editor" spellcheck="false"></textarea>
      <div class="editor-status" id="editor-status"></div>
    </div>
    <div class="editor-pane" id="editor-pane-form">
      <div id="form-empty" class="editor-empty">Choose a table and column to edit common column-level SQL fields. Use the SQL tab for advanced PostgreSQL definitions.</div>
      <div id="schema-form" class="form-grid" style="display:none;">
        <div class="form-field">
          <label for="form-table">Table</label>
          <select id="form-table"></select>
        </div>
        <div class="form-field">
          <label for="form-table-name">Table name</label>
          <input id="form-table-name" autocomplete="off"/>
        </div>
        <div class="form-field">
          <label for="form-column">Column</label>
          <select id="form-column"></select>
        </div>
        <div class="form-field">
          <label for="form-column-name">Column name</label>
          <input id="form-column-name" autocomplete="off"/>
        </div>
        <div class="form-field">
          <label for="form-column-type">Type</label>
          <input id="form-column-type" autocomplete="off"/>
        </div>
        <div class="form-field">
          <label for="form-default">Default</label>
          <input id="form-default" autocomplete="off" placeholder="NULL / empty for none"/>
        </div>
        <div class="form-field">
          <label for="form-ref-table">References table</label>
          <select id="form-ref-table"></select>
        </div>
        <div class="form-field">
          <label for="form-ref-column">References column</label>
          <input id="form-ref-column" autocomplete="off" placeholder="id"/>
        </div>
        <div class="form-field">
          <label for="form-on-delete">On delete</label>
          <select id="form-on-delete">
            <option value="">None</option>
            <option>CASCADE</option>
            <option>RESTRICT</option>
            <option>SET NULL</option>
            <option>SET DEFAULT</option>
            <option>NO ACTION</option>
          </select>
        </div>
        <div class="check-row full">
          <label><input id="form-pk" type="checkbox"/> Primary key</label>
          <label><input id="form-not-null" type="checkbox"/> Not null</label>
          <label><input id="form-unique" type="checkbox"/> Unique</label>
        </div>
      </div>
    </div>
  </div>
  <div class="editor-actions">
    <div class="editor-actions-group">
      <button class="editor-btn primary" id="btn-download-sql">Download SQL</button>
      <button class="editor-btn" id="btn-download-html">Download HTML</button>
    </div>
    <button class="editor-btn" id="btn-reparse">Re-parse SQL</button>
  </div>
</div>

<div id="toolbar">
  <button class="tool-btn" id="btn-fit" title="Fit to screen">⊞ Fit</button>
  <div class="tool-divider"></div>
  <button class="tool-btn" id="btn-zoom-in">＋</button>
  <button class="tool-btn" id="btn-zoom-out">－</button>
  <div class="tool-divider"></div>
  <button class="tool-btn" id="btn-editor" title="Edit schema">✎ Editor</button>
  <div class="tool-divider"></div>
  <button class="tool-btn" id="btn-edges" title="Toggle FK lines">⇢ Edges</button>
  <button class="tool-btn" id="btn-reset" title="Reset selection">⟳ Reset</button>
</div>

<canvas id="minimap"></canvas>

<script>
// ── BROWSER SQL PARSER ────────────────────────────────────────────────────
${parseSchema.toString()}
${parseTables.toString()}
${splitTopLevel.toString()}
${stripSqlComments.toString()}
${csvNames.toString()}
${unquoteSqlString.toString()}
${parseEnums.toString()}
${parseDefault.toString()}
${parseGenerated.toString()}
${parseReferentialActions.toString()}
${parseIndexes.toString()}
${parseViews.toString()}
${escapeRegex.toString()}
${normalizeType.toString()}
${layoutTables.toString()}

// ── DATA ──────────────────────────────────────────────────────────────────
let TABLES  = ${tableData};
let ENUMS   = ${enumData};
let INDEXES = ${indexData};
let VIEWS   = ${viewData};
let POSITIONS = ${posData};
let EDGES   = ${edgeData};
const DOMAINS = ${domainData};
const ORIGINAL_SQL = ${originalSqlData};
let currentSql = ORIGINAL_SQL;
let lastValidSql = ORIGINAL_SQL;

// ── STATE ─────────────────────────────────────────────────────────────────
let scale = 0.55, tx = 40, ty = 40;
let isPanning = false, startX = 0, startY = 0, startTX = 0, startTY = 0;
let selectedTable = null;
let showEdges = true;
let filterDomain = null;
let draggingCard = null, dragOffX = 0, dragOffY = 0;
const cardEls = {}; // name → DOM element
const cardPos = {}; // name → {x,y,w,h} (live)

// Copy initial positions
for (const [k,v] of Object.entries(POSITIONS)) cardPos[k] = {...v};

// ── DOM HELPERS ───────────────────────────────────────────────────────────
const canvas    = document.getElementById('canvas');
const wrap      = document.getElementById('canvas-wrap');
const edgeLayer = document.getElementById('edge-layer');
const search    = document.getElementById('search');
const panel     = document.getElementById('detail-panel');
const editorPanel = document.getElementById('editor-panel');
const sqlEditor = document.getElementById('sql-editor');
const editorStatus = document.getElementById('editor-status');

function setTransform() {
  canvas.style.transform = \`translate(\${tx}px,\${ty}px) scale(\${scale})\`;
}

function buildEdgesFromTables(tables) {
  const edges = [];
  for (const [tname, tdata] of Object.entries(tables)) {
    for (const fk of tdata.foreignKeys || []) {
      if (tables[fk.refTable]) {
        edges.push({ from: tname, to: fk.refTable, cols: fk.columns, refCols: fk.refColumns, onDelete: fk.onDelete || null, onUpdate: fk.onUpdate || null });
      }
    }
  }
  return edges;
}

function validateParsedSql(sqlText, parsed) {
  const createTableCount = (stripSqlComments(sqlText).match(/CREATE\\s+TABLE\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?\\w+\\s*\\(/gi) || []).length;
  const parsedCount = Object.keys(parsed.tables || {}).length;
  if (createTableCount && parsedCount === 0) throw new Error('No complete CREATE TABLE blocks could be parsed.');
  if (createTableCount > parsedCount) throw new Error(\`Parsed \${parsedCount} of \${createTableCount} CREATE TABLE blocks. Check for an incomplete table definition.\`);
}

function replaceObjectContents(target, source) {
  for (const key of Object.keys(target)) delete target[key];
  for (const [key, value] of Object.entries(source)) target[key] = value;
}

function removeTableCards() {
  document.querySelectorAll('.table-card').forEach(el => el.remove());
  document.querySelectorAll('.domain-label').forEach(el => el.remove());
  for (const key of Object.keys(cardEls)) delete cardEls[key];
}

function refreshSchema(schema, options = {}) {
  const nextPositions = layoutTables(schema.tables);
  const mergedPositions = {};
  for (const [name, pos] of Object.entries(nextPositions)) mergedPositions[name] = cardPos[name] ? { ...cardPos[name] } : { ...pos };

  TABLES = schema.tables;
  ENUMS = schema.enums;
  INDEXES = schema.indexes;
  VIEWS = schema.views;
  EDGES = buildEdgesFromTables(TABLES);
  POSITIONS = mergedPositions;

  replaceObjectContents(cardPos, mergedPositions);
  removeTableCards();
  buildCards();
  updateStats();
  applyFilters();

  if (selectedTable && TABLES[selectedTable]) {
    highlightRelated(selectedTable);
    openPanel(selectedTable);
  } else if (selectedTable) {
    clearHighlight();
    closePanel();
  }
  populateSchemaForm();
  if (options.fit) setTimeout(fitScreen, 60);
}

function tryParseCurrentSql(options = {}) {
  const nextSql = sqlEditor.value;
  try {
    const nextSchema = parseSchema(nextSql);
    validateParsedSql(nextSql, nextSchema);
    currentSql = nextSql;
    lastValidSql = nextSql;
    refreshSchema(nextSchema, options);
    if (!options.silentSave) {
      setEditorStatus(liveServiceAvailable ? 'Live preview updated. Saving...' : 'Live preview updated.', 'ok');
      scheduleServerSave();
    }
    return true;
  } catch (err) {
    currentSql = nextSql;
    setEditorStatus(err.message || String(err), 'error');
    return false;
  }
}

function setEditorStatus(message, kind = '') {
  editorStatus.textContent = message || '';
  editorStatus.className = \`editor-status \${kind}\`.trim();
}

// ── LEGEND ────────────────────────────────────────────────────────────────
{
  const container = document.getElementById('legend-items');
  for (const d of DOMAINS) {
    const item = document.createElement('div');
    item.className = 'legend-item';
    item.dataset.id = d.id;
    item.innerHTML = \`<div class="legend-dot" style="background:\${d.color}"></div><span class="legend-label">\${d.label}</span>\`;
    item.addEventListener('click', () => {
      if (filterDomain === d.id) { filterDomain = null; item.classList.remove('active-filter'); }
      else { filterDomain = d.id; document.querySelectorAll('.legend-item').forEach(el => el.classList.remove('active-filter')); item.classList.add('active-filter'); }
      applyFilters();
    });
    container.appendChild(item);
  }
}

// ── TABLE CARDS ───────────────────────────────────────────────────────────
function getDomain(name) {
  for (const d of DOMAINS) if (d.tables.includes(name)) return d;
  return { id:'other', label:'Other', color:'#64748b' };
}

function esc(value) {
  return String(value ?? '').replace(/[&<>"']/g, ch => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[ch]));
}

function columnHasIndex(tableName, colName) {
  return (INDEXES[tableName] || []).some(idx => idx.columns.some(c => new RegExp(\`\\\\b\${colName}\\\\b\`, 'i').test(c)));
}

function formatColumnBadges(tableName, col) {
  const badges = [];
  if (col.isPK) badges.push('<span class="badge badge-pk">PK</span>');
  if (col.fk) badges.push('<span class="badge badge-fk">FK</span>');
  if (col.isUnique && !col.isPK) badges.push('<span class="badge badge-uq">UQ</span>');
  if (col.uniqueGroup && !col.isUnique && !col.isPK) badges.push('<span class="badge badge-uq">UQ*</span>');
  if (col.isNotNull && !col.isPK) badges.push('<span class="badge badge-nn">NN</span>');
  if (col.enumName) badges.push('<span class="badge badge-en">ENUM</span>');
  if (col.defaultValue) badges.push('<span class="badge badge-def">DEF</span>');
  if (col.isGenerated) badges.push('<span class="badge badge-gen">GEN</span>');
  if (columnHasIndex(tableName, col.name)) badges.push('<span class="badge badge-idx">IDX</span>');
  if (col.fk?.onDelete) badges.push('<span class="badge badge-del">DEL</span>');
  return badges;
}

function columnTooltip(tableName, col) {
  const lines = [\`\${tableName}.\${col.name}\`, \`Type: \${col.type}\`];
  if (col.enumName) lines.push(\`Enum \${col.enumName}: \${col.enumValues.join(', ')}\`);
  if (col.defaultValue) lines.push(\`Default: \${col.defaultValue}\`);
  if (col.isGenerated) lines.push(\`Generated: \${col.generatedExpression}\${col.generatedStorage ? ' ' + col.generatedStorage : ''}\`);
  if (col.fk) lines.push(\`References: \${col.fk.refTable}(\${col.fk.refColumn})\`);
  if (col.fk?.onDelete) lines.push(\`ON DELETE: \${col.fk.onDelete}\`);
  if (col.fk?.onUpdate) lines.push(\`ON UPDATE: \${col.fk.onUpdate}\`);
  if (col.isPK) lines.push('Primary key');
  if (col.isUnique) lines.push('Unique');
  if (col.uniqueGroup) lines.push(\`Composite unique: \${col.uniqueGroup.join(', ')}\`);
  if (col.isNotNull) lines.push('Not null');
  if (col.checks?.length) lines.push(\`Checks: \${col.checks.join('; ')}\`);
  return lines.join('\\n');
}

function renderMetaLine(label, value) {
  if (!value) return '';
  return \`<div class="dp-meta-line"><b>\${esc(label)}:</b> \${esc(value)}</div>\`;
}

function renderEmpty() {
  return '<div class="dp-empty">None</div>';
}

function buildDomainLabels() {
  document.querySelectorAll('.domain-label').forEach(el => el.remove());
  const grouped = {};
  for (const [name, pos] of Object.entries(cardPos)) {
    const d = getDomain(name);
    if (!grouped[d.id]) grouped[d.id] = { domain: d, count: 0, minX: Infinity, minY: Infinity };
    grouped[d.id].count++;
    grouped[d.id].minX = Math.min(grouped[d.id].minX, pos.x);
    grouped[d.id].minY = Math.min(grouped[d.id].minY, pos.y);
  }
  for (const group of Object.values(grouped)) {
    const label = document.createElement('div');
    label.className = 'domain-label';
    label.dataset.domain = group.domain.id;
    label.style.left = group.minX + 'px';
    label.style.top = Math.max(8, group.minY - 38) + 'px';
    label.style.color = group.domain.color;
    label.innerHTML = \`\${esc(group.domain.label)} <span>\${group.count} tables</span>\`;
    canvas.appendChild(label);
  }
}

function buildCards() {
  buildDomainLabels();
  for (const [name, tdata] of Object.entries(TABLES)) {
    const d = getDomain(name);
    const pos = cardPos[name] || { x:0, y:0, w:260 };

    const card = document.createElement('div');
    card.className = 'table-card';
    card.id = 'card-' + name;
    card.style.left  = pos.x + 'px';
    card.style.top   = pos.y + 'px';
    card.style.setProperty('--domain-color', d.color);

    // Header
    const hdr = document.createElement('div');
    hdr.className = 'card-header';
    hdr.innerHTML = \`
      <div style="display:flex;align-items:center;gap:7px;">
        <div class="card-domain-dot" style="background:\${d.color}"></div>
        <span class="card-title">\${name}</span>
      </div>
      <span class="col-count">\${tdata.columns.length}</span>
    \`;
    card.appendChild(hdr);

    // Columns
    const colWrap = document.createElement('div');
    colWrap.className = 'card-columns';

    for (const col of tdata.columns) {
      const row = document.createElement('div');
      row.className = 'col-row';
      const badges = formatColumnBadges(name, col);
      row.title = columnTooltip(name, col);
      row.innerHTML = \`\${badges.join('')}<span class="col-name">\${esc(col.name)}</span><span class="col-type">\${esc(col.type)}</span>\`;
      row.addEventListener('dblclick', e => {
        editTable(name);
        setTimeout(() => {
          document.getElementById('form-column').value = col.name;
          loadSelectedColumnIntoForm();
        }, 0);
        e.stopPropagation();
      });
      colWrap.appendChild(row);
    }
    card.appendChild(colWrap);

    // Drag logic (header drag)
    hdr.addEventListener('mousedown', e => {
      if (e.button !== 0) return;
      draggingCard = name;
      const p = cardPos[name];
      dragOffX = (e.clientX - tx) / scale - p.x;
      dragOffY = (e.clientY - ty) / scale - p.y;
      card.style.zIndex = 50;
      e.stopPropagation();
    });

    // Click card → select
    card.addEventListener('click', e => {
      if (draggingCard) return;
      selectTable(name);
      e.stopPropagation();
    });
    card.addEventListener('dblclick', e => {
      editTable(name);
      e.stopPropagation();
    });

    canvas.appendChild(card);
    cardEls[name] = card;
  }
}

// ── EDGE RENDERING ────────────────────────────────────────────────────────
function getAnchor(name, side) {
  const p = cardPos[name];
  if (!p) return { x:0, y:0 };
  const el = cardEls[name];
  const h = el ? el.offsetHeight : 120;
  if (side === 'right')  return { x: p.x + 260, y: p.y + h/2 };
  if (side === 'left')   return { x: p.x,       y: p.y + h/2 };
  if (side === 'bottom') return { x: p.x + 130,  y: p.y + h };
  return { x: p.x + 130, y: p.y };
}

function chooseAnchors(fromName, toName) {
  const fp = cardPos[fromName], tp = cardPos[toName];
  if (!fp || !tp) return null;
  const fmx = fp.x + 130, tmx = tp.x + 130;
  if (fmx < tmx) return [getAnchor(fromName,'right'), getAnchor(toName,'left')];
  return [getAnchor(fromName,'left'), getAnchor(toName,'right')];
}

function renderEdges() {
  edgeLayer.innerHTML = '';
  if (!showEdges) return;
  const svgNS = 'http://www.w3.org/2000/svg';

  // Compute canvas extent
  let maxX = 0, maxY = 0;
  for (const p of Object.values(cardPos)) { maxX = Math.max(maxX, p.x + 300); maxY = Math.max(maxY, p.y + 400); }
  edgeLayer.setAttribute('width',  maxX);
  edgeLayer.setAttribute('height', maxY);

  // Arrow marker
  const defs = document.createElementNS(svgNS, 'defs');
  DOMAINS.forEach(d => {
    const m = document.createElementNS(svgNS, 'marker');
    m.setAttribute('id', 'arrow-' + d.id);
    m.setAttribute('markerWidth', '8'); m.setAttribute('markerHeight', '8');
    m.setAttribute('refX', '6'); m.setAttribute('refY', '3'); m.setAttribute('orient', 'auto');
    const p = document.createElementNS(svgNS, 'path');
    p.setAttribute('d', 'M0,0 L0,6 L8,3 z');
    p.setAttribute('fill', d.color);
    m.appendChild(p); defs.appendChild(m);
  });
  const mOther = document.createElementNS(svgNS, 'marker');
  mOther.setAttribute('id', 'arrow-other');
  mOther.setAttribute('markerWidth', '8'); mOther.setAttribute('markerHeight', '8');
  mOther.setAttribute('refX', '6'); mOther.setAttribute('refY', '3'); mOther.setAttribute('orient', 'auto');
  const pOther = document.createElementNS(svgNS, 'path');
  pOther.setAttribute('d', 'M0,0 L0,6 L8,3 z'); pOther.setAttribute('fill', '#64748b');
  mOther.appendChild(pOther); defs.appendChild(mOther);
  edgeLayer.appendChild(defs);

  for (const edge of EDGES) {
    const anch = chooseAnchors(edge.from, edge.to);
    if (!anch) continue;
    const [a, b] = anch;
    const dx = Math.abs(b.x - a.x) * 0.45;
    const d  = \`M\${a.x},\${a.y} C\${a.x+dx},\${a.y} \${b.x-dx},\${b.y} \${b.x},\${b.y}\`;
    const dom = getDomain(edge.from);
    const el  = document.createElementNS(svgNS, 'path');
    el.setAttribute('d', d);
    el.setAttribute('class', 'edge-path');
    el.setAttribute('stroke', dom.color);
    el.setAttribute('marker-end', \`url(#arrow-\${dom.id})\`);
    el.dataset.from = edge.from;
    el.dataset.to   = edge.to;
    const title = document.createElementNS(svgNS, 'title');
    title.textContent = \`\${edge.from}(\${edge.cols.join(', ')}) → \${edge.to}(\${edge.refCols.join(', ')})\${edge.onDelete ? ' | ON DELETE ' + edge.onDelete : ''}\`;
    el.appendChild(title);
    edgeLayer.appendChild(el);
  }
}

// ── SELECTION / HIGHLIGHT ─────────────────────────────────────────────────
function selectTable(name) {
  selectedTable = name === selectedTable ? null : name;
  if (!selectedTable) { clearHighlight(); closePanel(); return; }
  highlightRelated(selectedTable);
  openPanel(selectedTable);
  if (editorPanel.classList.contains('open')) populateSchemaForm(selectedTable);
}

function highlightRelated(name) {
  const related = new Set([name]);
  for (const e of EDGES) {
    if (e.from === name) related.add(e.to);
    if (e.to   === name) related.add(e.from);
  }
  for (const [n, el] of Object.entries(cardEls)) {
    el.classList.remove('selected','highlighted','dimmed');
    if (n === name) el.classList.add('selected');
    else if (related.has(n)) el.classList.add('highlighted');
    else el.classList.add('dimmed');
  }
  document.querySelectorAll('.edge-path').forEach(ep => {
    ep.classList.remove('highlighted','dimmed');
    if (ep.dataset.from === name || ep.dataset.to === name) ep.classList.add('highlighted');
    else ep.classList.add('dimmed');
  });
}

function clearHighlight() {
  selectedTable = null;
  for (const el of Object.values(cardEls)) el.classList.remove('selected','highlighted','dimmed');
  document.querySelectorAll('.edge-path').forEach(ep => ep.classList.remove('highlighted','dimmed'));
}

// ── DOMAIN FILTER ─────────────────────────────────────────────────────────
function applyFilters() {
  const q = search.value.toLowerCase();
  for (const [name, el] of Object.entries(cardEls)) {
    const domMatch  = !filterDomain || getDomain(name).id === filterDomain;
    const tdata = TABLES[name];
    const haystack = [
      name,
      ...tdata.columns.flatMap(col => [col.name, col.type, col.enumName, col.defaultValue, col.generatedExpression].filter(Boolean)),
      ...(INDEXES[name] || []).map(idx => idx.name),
      ...(tdata.views || []).map(v => v.name),
    ].join(' ').toLowerCase();
    const nameMatch = !q || haystack.includes(q);
    el.style.display = (domMatch && nameMatch) ? '' : 'none';
  }
  document.querySelectorAll('.domain-label').forEach(label => {
    const visible = !filterDomain || label.dataset.domain === filterDomain;
    label.style.display = visible ? '' : 'none';
  });
  renderEdges();
}

// ── DETAIL PANEL ──────────────────────────────────────────────────────────
function renderConstraint(c) {
  const name = c.name ? \`\${c.name} · \` : '';
  if (c.type === 'FOREIGN KEY') {
    return \`<div class="dp-card"><div class="dp-card-title">\${esc(name)}FOREIGN KEY</div>\${esc((c.columns || []).join(', '))} → \${esc(c.refTable)}(\${esc((c.refColumns || []).join(', '))})\${c.onDelete ? '<br>ON DELETE ' + esc(c.onDelete) : ''}\${c.onUpdate ? '<br>ON UPDATE ' + esc(c.onUpdate) : ''}</div>\`;
  }
  if (c.type === 'CHECK') {
    return \`<div class="dp-card"><div class="dp-card-title">\${esc(name)}CHECK</div>\${esc(c.expression)}</div>\`;
  }
  return \`<div class="dp-card"><div class="dp-card-title">\${esc(name + c.type)}</div>\${esc((c.columns || []).join(', '))}</div>\`;
}

function renderIndex(idx) {
  return \`<div class="dp-card"><div class="dp-card-title">\${idx.unique ? 'UNIQUE ' : ''}\${esc(idx.name)}</div>\${esc(idx.method.toUpperCase())} on \${esc(idx.columns.join(', '))}\${idx.where ? '<br>WHERE ' + esc(idx.where) : ''}</div>\`;
}

function renderView(view) {
  return \`<div class="dp-card"><div class="dp-card-title">\${esc(view.name)}</div>\${esc(view.definition)}</div>\`;
}

function editTable(name) {
  if (!TABLES[name]) return;
  selectedTable = name;
  openEditor();
  setActiveEditorTab('form');
  populateSchemaForm(name);
}

function openPanel(name) {
  const tdata = TABLES[name];
  const d     = getDomain(name);
  document.getElementById('dp-title').textContent  = name;
  document.getElementById('dp-domain').textContent = d.label;
  document.getElementById('dp-domain').style.color  = d.color;

  const indexes = INDEXES[name] || [];
  const views = tdata.views || [];
  document.getElementById('dp-summary').innerHTML = [
    ['Columns', tdata.columns.length],
    ['FKs', tdata.foreignKeys.length],
    ['Indexes', indexes.length],
    ['Enums', tdata.columns.filter(c => c.enumName).length],
    ['Defaults', tdata.columns.filter(c => c.defaultValue).length],
    ['Generated', tdata.columns.filter(c => c.isGenerated).length],
  ].map(([label, value]) => \`<div class="dp-stat"><b>\${value}</b><span>\${label}</span></div>\`).join('');

  // Columns
  const colsEl = document.getElementById('dp-cols');
  colsEl.innerHTML = '';
  for (const col of tdata.columns) {
    const badges = formatColumnBadges(name, col);
    const enumValues = col.enumValues?.length
      ? \`<div class="dp-enum-values">\${col.enumValues.map(v => \`<span class="dp-enum-value">\${esc(v)}</span>\`).join('')}</div>\`
      : '';
    const meta = [
      renderMetaLine('Default', col.defaultValue),
      renderMetaLine('Generated', col.isGenerated ? \`\${col.generatedExpression}\${col.generatedStorage ? ' ' + col.generatedStorage : ''}\` : null),
      renderMetaLine('References', col.fk ? \`\${col.fk.refTable}(\${col.fk.refColumn})\` : null),
      renderMetaLine('ON DELETE', col.fk?.onDelete),
      renderMetaLine('ON UPDATE', col.fk?.onUpdate),
      renderMetaLine('Composite unique', col.uniqueGroup?.join(', ')),
      renderMetaLine('Checks', col.checks?.join('; ')),
      renderMetaLine('Raw', col.rawDefinition),
      enumValues
    ].filter(Boolean).join('');
    const row = document.createElement('div');
    row.className = 'dp-col';
    row.title = columnTooltip(name, col);
    row.innerHTML = \`\${badges.join('')}<span class="dp-col-name">\${esc(col.name)}</span><span class="dp-col-type">\${esc(col.type)}\${col.enumName ? ' · ' + esc(col.enumName) : ''}</span>\${meta ? '<div class="dp-meta">' + meta + '</div>' : ''}\`;
    colsEl.appendChild(row);
  }

  const constraintsEl = document.getElementById('dp-constraints');
  constraintsEl.innerHTML = tdata.constraints?.length ? tdata.constraints.map(renderConstraint).join('') : renderEmpty();

  const indexesEl = document.getElementById('dp-indexes');
  indexesEl.innerHTML = indexes.length ? indexes.map(renderIndex).join('') : renderEmpty();

  // FK out
  const fksEl = document.getElementById('dp-fks');
  fksEl.innerHTML = '';
  const outRefs = EDGES.filter(e => e.from === name);
  if (!outRefs.length) fksEl.innerHTML = renderEmpty();
  for (const e of outRefs) {
    const link = document.createElement('div');
    link.className = 'dp-fk';
    link.innerHTML = \`→ \${esc(e.to)} <span style="color:var(--text-muted)">\${esc(e.cols.join(','))} → \${esc(e.refCols.join(','))}\${e.onDelete ? ' · ON DELETE ' + esc(e.onDelete) : ''}</span>\`;
    link.addEventListener('click', () => { selectTable(e.to); scrollToTable(e.to); });
    fksEl.appendChild(link);
  }

  // FK in
  const refByEl = document.getElementById('dp-ref-by');
  refByEl.innerHTML = '';
  const inRefs = EDGES.filter(e => e.to === name);
  if (!inRefs.length) refByEl.innerHTML = renderEmpty();
  for (const e of inRefs) {
    const link = document.createElement('div');
    link.className = 'dp-fk';
    link.innerHTML = \`← \${esc(e.from)} <span style="color:var(--text-muted)">\${esc(e.cols.join(','))} → \${esc(e.refCols.join(','))}\${e.onDelete ? ' · ON DELETE ' + esc(e.onDelete) : ''}</span>\`;
    link.addEventListener('click', () => { selectTable(e.from); scrollToTable(e.from); });
    refByEl.appendChild(link);
  }

  const viewsEl = document.getElementById('dp-views');
  viewsEl.innerHTML = views.length ? views.map(renderView).join('') : renderEmpty();

  const editBtn = document.createElement('button');
  editBtn.className = 'editor-btn primary';
  editBtn.style.width = '100%';
  editBtn.style.marginTop = '12px';
  editBtn.textContent = 'Edit table';
  editBtn.addEventListener('click', () => editTable(name));
  viewsEl.appendChild(editBtn);

  panel.classList.add('open');
}

function closePanel() { panel.classList.remove('open'); }

function scrollToTable(name) {
  const p = cardPos[name];
  if (!p) return;
  const ww = wrap.offsetWidth, wh = wrap.offsetHeight;
  tx = ww/2 - (p.x + 130) * scale;
  ty = wh/2 - (p.y + 60)  * scale;
  setTransform();
}

document.getElementById('close-detail').addEventListener('click', () => { clearHighlight(); closePanel(); });

// ── PAN & ZOOM ────────────────────────────────────────────────────────────
wrap.addEventListener('mousedown', e => {
  if (e.button !== 0 || draggingCard) return;
  isPanning = true;
  startX = e.clientX; startY = e.clientY;
  startTX = tx; startTY = ty;
  wrap.classList.add('panning');
});

window.addEventListener('mousemove', e => {
  if (draggingCard) {
    const name = draggingCard;
    const nx = (e.clientX - tx) / scale - dragOffX;
    const ny = (e.clientY - ty) / scale - dragOffY;
    cardPos[name].x = nx; cardPos[name].y = ny;
    cardEls[name].style.left = nx + 'px';
    cardEls[name].style.top  = ny + 'px';
    renderEdges();
    return;
  }
  if (!isPanning) return;
  tx = startTX + (e.clientX - startX);
  ty = startTY + (e.clientY - startY);
  setTransform();
});

window.addEventListener('mouseup', e => {
  if (draggingCard) { cardEls[draggingCard].style.zIndex = ''; draggingCard = null; return; }
  isPanning = false;
  wrap.classList.remove('panning');
});

wrap.addEventListener('wheel', e => {
  e.preventDefault();
  const factor = e.deltaY < 0 ? 1.1 : 0.91;
  const rect = wrap.getBoundingClientRect();
  const mx = e.clientX - rect.left, my = e.clientY - rect.top;
  tx = mx + (tx - mx) * factor;
  ty = my + (ty - my) * factor;
  scale = Math.max(0.15, Math.min(2.5, scale * factor));
  setTransform();
}, { passive: false });

// Deselect on canvas click
wrap.addEventListener('click', e => { if (e.target === wrap || e.target === canvas || e.target === edgeLayer) { clearHighlight(); closePanel(); } });

// ── TOOLBAR ───────────────────────────────────────────────────────────────
document.getElementById('btn-fit').addEventListener('click', fitScreen);
document.getElementById('btn-zoom-in').addEventListener('click',  () => { scale = Math.min(2.5, scale*1.2); setTransform(); });
document.getElementById('btn-zoom-out').addEventListener('click', () => { scale = Math.max(0.15, scale*0.83); setTransform(); });
document.getElementById('btn-edges').addEventListener('click', function() {
  showEdges = !showEdges;
  this.classList.toggle('active', showEdges);
  renderEdges();
});
document.getElementById('btn-reset').addEventListener('click', () => { clearHighlight(); closePanel(); filterDomain = null; search.value = ''; document.querySelectorAll('.legend-item').forEach(el => el.classList.remove('active-filter')); applyFilters(); });

function fitScreen() {
  let minX=Infinity, minY=Infinity, maxX=-Infinity, maxY=-Infinity;
  for (const [name, p] of Object.entries(cardPos)) {
    const el = cardEls[name];
    if (!el || el.style.display==='none') continue;
    minX = Math.min(minX, p.x); minY = Math.min(minY, p.y);
    maxX = Math.max(maxX, p.x + 260); maxY = Math.max(maxY, p.y + (el.offsetHeight||120));
  }
  const pw = wrap.offsetWidth - 60, ph = wrap.offsetHeight - 60;
  scale = Math.min(pw / (maxX-minX), ph / (maxY-minY), 1.5);
  tx = 30 - minX * scale;
  ty = 30 - minY * scale;
  setTransform();
}

// ── SEARCH ────────────────────────────────────────────────────────────────
search.addEventListener('input', applyFilters);

// ── LIVE EDITOR ───────────────────────────────────────────────────────────
let sqlEditTimer = null;
let formEditTimer = null;
let isPopulatingForm = false;
let liveServiceAvailable = false;
let saveTimer = null;
let lastSavedSql = ORIGINAL_SQL;

function setActiveEditorTab(tab) {
  document.querySelectorAll('.editor-tab').forEach(btn => btn.classList.toggle('active', btn.dataset.editorTab === tab));
  document.querySelectorAll('.editor-pane').forEach(pane => pane.classList.remove('active'));
  document.getElementById(\`editor-pane-\${tab}\`).classList.add('active');
  if (tab === 'form') populateSchemaForm();
}

function openEditor() {
  sqlEditor.value = currentSql;
  populateSchemaForm();
  editorPanel.classList.add('open');
  document.getElementById('btn-editor').classList.add('active');
}

function closeEditor() {
  editorPanel.classList.remove('open');
  document.getElementById('btn-editor').classList.remove('active');
}

async function detectLiveService() {
  try {
    const response = await fetch('/api/schema', { cache: 'no-store' });
    if (!response.ok) throw new Error('Schema API unavailable');
    const payload = await response.json();
    if (typeof payload.sql !== 'string') throw new Error('Schema API returned no SQL');
    liveServiceAvailable = true;
    currentSql = payload.sql;
    lastValidSql = payload.sql;
    lastSavedSql = payload.sql;
    sqlEditor.value = payload.sql;
    document.getElementById('editor-note').innerHTML = 'Live service mode is active. Valid edits save directly to <b>lending_app_schema.sql</b> and regenerate this HTML file.';
    document.getElementById('btn-download-sql').textContent = 'Save SQL';
    tryParseCurrentSql({ silentSave: true });
    setEditorStatus('Live service connected.', 'ok');
  } catch {
    liveServiceAvailable = false;
  }
}

async function saveCurrentSqlToServer() {
  if (!liveServiceAvailable || currentSql === lastSavedSql) return;
  try {
    setEditorStatus('Saving to lending_app_schema.sql...', '');
    const response = await fetch('/api/save', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ sql: currentSql }),
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok || !payload.ok) throw new Error(payload.error || 'Save failed');
    lastSavedSql = currentSql;
    setEditorStatus('Saved to lending_app_schema.sql and regenerated index.html.', 'ok');
  } catch (err) {
    setEditorStatus(err.message || String(err), 'error');
  }
}

function scheduleServerSave() {
  if (!liveServiceAvailable) return;
  clearTimeout(saveTimer);
  saveTimer = setTimeout(saveCurrentSqlToServer, 400);
}

function findCreateTableBlock(sqlText, tableName) {
  const tableRe = /CREATE\\s+TABLE\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?(\\w+)\\s*\\(([\\s\\S]*?)\\)\\s*(?:PARTITION\\s+BY[^;]+)?;/gi;
  let match;
  while ((match = tableRe.exec(sqlText)) !== null) {
    if (match[1] === tableName) {
      return { start: match.index, end: tableRe.lastIndex, full: match[0], name: match[1], body: match[2] };
    }
  }
  return null;
}

function columnDefinitionFromForm() {
  const name = document.getElementById('form-column-name').value.trim();
  const type = document.getElementById('form-column-type').value.trim();
  if (!/^\\w+$/.test(name)) throw new Error('Column name must use letters, numbers, or underscore.');
  if (!type) throw new Error('Column type is required.');
  const parts = [name, type];
  if (document.getElementById('form-pk').checked) parts.push('PRIMARY KEY');
  if (document.getElementById('form-not-null').checked) parts.push('NOT NULL');
  if (document.getElementById('form-unique').checked && !document.getElementById('form-pk').checked) parts.push('UNIQUE');
  const defaultValue = document.getElementById('form-default').value.trim();
  if (defaultValue) parts.push('DEFAULT ' + defaultValue);
  const refTable = document.getElementById('form-ref-table').value;
  if (refTable) {
    const refColumn = document.getElementById('form-ref-column').value.trim() || 'id';
    parts.push(\`REFERENCES \${refTable}(\${refColumn})\`);
    const onDelete = document.getElementById('form-on-delete').value;
    if (onDelete) parts.push('ON DELETE ' + onDelete);
  }
  return parts.join(' ');
}

function updateSqlFromForm() {
  if (isPopulatingForm) return;
  const originalTable = document.getElementById('form-table').value;
  const originalColumn = document.getElementById('form-column').value;
  if (!originalTable || !originalColumn) return;
  clearTimeout(formEditTimer);
  formEditTimer = setTimeout(() => {
    try {
      const nextTableName = document.getElementById('form-table-name').value.trim();
      if (!/^\\w+$/.test(nextTableName)) throw new Error('Table name must use letters, numbers, or underscore.');
      const block = findCreateTableBlock(currentSql, originalTable);
      if (!block) throw new Error(\`Could not locate CREATE TABLE block for \${originalTable}.\`);
      const clauses = splitTopLevel(block.body);
      let replacedColumn = false;
      const nextColumnDefinition = columnDefinitionFromForm();
      const nextClauses = clauses.map(clause => {
        const trimmed = clause.trim();
        const columnMatch = /^(\\w+)\\s+/s.exec(trimmed);
        if (columnMatch && columnMatch[1] === originalColumn) {
          replacedColumn = true;
          const indent = /^\\s*/.exec(clause)?.[0] || '    ';
          return indent + nextColumnDefinition;
        }
        return clause;
      });
      if (!replacedColumn) throw new Error(\`Could not locate column \${originalColumn} in \${originalTable}.\`);

      let nextBlock = block.full.replace(block.body, nextClauses.join(',\\n'));
      if (nextTableName !== originalTable) {
        nextBlock = nextBlock.replace(new RegExp(\`(CREATE\\\\s+TABLE\\\\s+(?:IF\\\\s+NOT\\\\s+EXISTS\\\\s+)?)\${originalTable}\\\\b\`, 'i'), \`$1\${nextTableName}\`);
      }
      let nextSql = currentSql.slice(0, block.start) + nextBlock + currentSql.slice(block.end);
      if (nextTableName !== originalTable) {
        nextSql = nextSql.replace(new RegExp(\`(REFERENCES\\\\s+)\${originalTable}\\\\b\`, 'gi'), \`$1\${nextTableName}\`);
      }
      sqlEditor.value = nextSql;
      tryParseCurrentSql();
      document.getElementById('form-table').value = TABLES[nextTableName] ? nextTableName : originalTable;
      populateSchemaForm();
    } catch (err) {
      setEditorStatus(err.message || String(err), 'error');
    }
  }, 250);
}

function populateSchemaForm(preferredTable = null) {
  const tableNames = Object.keys(TABLES);
  const form = document.getElementById('schema-form');
  const empty = document.getElementById('form-empty');
  if (!tableNames.length) {
    form.style.display = 'none';
    empty.style.display = '';
    return;
  }

  isPopulatingForm = true;
  empty.style.display = 'none';
  form.style.display = '';

  const tableSelect = document.getElementById('form-table');
  const previousTable = tableSelect.value;
  tableSelect.innerHTML = tableNames.map(name => \`<option value="\${esc(name)}">\${esc(name)}</option>\`).join('');
  const selectedTableName = TABLES[preferredTable] ? preferredTable : (TABLES[previousTable] ? previousTable : (selectedTable || tableNames[0]));
  tableSelect.value = TABLES[selectedTableName] ? selectedTableName : tableNames[0];

  const tableName = tableSelect.value;
  document.getElementById('form-table-name').value = tableName;

  const columnSelect = document.getElementById('form-column');
  const columns = TABLES[tableName].columns || [];
  const previousColumn = columnSelect.value;
  columnSelect.innerHTML = columns.map(col => \`<option value="\${esc(col.name)}">\${esc(col.name)}</option>\`).join('');
  columnSelect.value = columns.some(col => col.name === previousColumn) ? previousColumn : (columns[0]?.name || '');

  const tableOptions = [''].concat(tableNames).map(name => \`<option value="\${esc(name)}">\${name ? esc(name) : 'None'}</option>\`).join('');
  document.getElementById('form-ref-table').innerHTML = tableOptions;

  loadSelectedColumnIntoForm();
  isPopulatingForm = false;
}

function loadSelectedColumnIntoForm() {
  const tableName = document.getElementById('form-table').value;
  const columnName = document.getElementById('form-column').value;
  const col = TABLES[tableName]?.columns.find(c => c.name === columnName);
  if (!col) return;
  document.getElementById('form-column-name').value = col.name;
  document.getElementById('form-column-type').value = col.type;
  document.getElementById('form-default').value = col.defaultValue || '';
  document.getElementById('form-ref-table').value = col.fk?.refTable || '';
  document.getElementById('form-ref-column').value = col.fk?.refColumn || 'id';
  document.getElementById('form-on-delete').value = col.fk?.onDelete || '';
  document.getElementById('form-pk').checked = Boolean(col.isPK);
  document.getElementById('form-not-null').checked = Boolean(col.isNotNull);
  document.getElementById('form-unique').checked = Boolean(col.isUnique);
}

function updateStats() {
  document.getElementById('stat-tables').textContent = Object.keys(TABLES).length;
  document.getElementById('stat-edges').textContent  = EDGES.length;
  const totalCols = Object.values(TABLES).reduce((s,t) => s + t.columns.length, 0);
  document.getElementById('stat-cols').textContent   = totalCols;
  document.getElementById('stat-enums').textContent  = Object.keys(ENUMS).length;
  document.getElementById('stat-indexes').textContent = Object.values(INDEXES).reduce((sum, list) => sum + list.length, 0);
  document.getElementById('stat-views').textContent  = Object.keys(VIEWS).length;
}

function downloadText(filename, content, type) {
  const blob = new Blob([content], { type });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

function currentHtmlForDownload() {
  const clone = document.documentElement.cloneNode(true);
  const textarea = clone.querySelector('#sql-editor');
  if (textarea) textarea.textContent = currentSql;
  const scripts = clone.querySelectorAll('script');
  const source = '<!DOCTYPE html>\\n' + clone.outerHTML;
  return source
    .replace(/const ORIGINAL_SQL = [\\s\\S]*?;\\nlet currentSql = ORIGINAL_SQL;\\nlet lastValidSql = ORIGINAL_SQL;/, \`const ORIGINAL_SQL = \${JSON.stringify(currentSql)};\\nlet currentSql = ORIGINAL_SQL;\\nlet lastValidSql = ORIGINAL_SQL;\`);
}

document.querySelectorAll('.editor-tab').forEach(btn => btn.addEventListener('click', () => setActiveEditorTab(btn.dataset.editorTab)));
document.getElementById('btn-editor').addEventListener('click', () => editorPanel.classList.contains('open') ? closeEditor() : openEditor());
document.getElementById('close-editor').addEventListener('click', closeEditor);
document.getElementById('btn-reparse').addEventListener('click', () => tryParseCurrentSql({ fit: false }));
document.getElementById('btn-download-sql').addEventListener('click', () => liveServiceAvailable ? saveCurrentSqlToServer() : downloadText('lending_app_schema.updated.sql', currentSql, 'text/sql'));
document.getElementById('btn-download-html').addEventListener('click', () => downloadText('lending_app_schema.updated.html', currentHtmlForDownload(), 'text/html'));

sqlEditor.value = currentSql;
sqlEditor.addEventListener('input', () => {
  clearTimeout(sqlEditTimer);
  setEditorStatus('Parsing...', '');
  sqlEditTimer = setTimeout(() => tryParseCurrentSql(), 350);
});

document.getElementById('form-table').addEventListener('change', () => { isPopulatingForm = true; populateSchemaForm(); isPopulatingForm = false; });
document.getElementById('form-column').addEventListener('change', () => { isPopulatingForm = true; loadSelectedColumnIntoForm(); isPopulatingForm = false; });
['form-table-name','form-column-name','form-column-type','form-default','form-ref-table','form-ref-column','form-on-delete','form-pk','form-not-null','form-unique'].forEach(id => {
  document.getElementById(id).addEventListener('input', updateSqlFromForm);
  document.getElementById(id).addEventListener('change', updateSqlFromForm);
});

detectLiveService();

// ── STATS ─────────────────────────────────────────────────────────────────
updateStats();

// ── INIT ──────────────────────────────────────────────────────────────────
buildCards();
renderEdges();
setTransform();

// Slight delay to let cards render, then fit
setTimeout(fitScreen, 120);

// keyboard
window.addEventListener('keydown', e => {
  if (e.key === 'Escape') { clearHighlight(); closePanel(); }
  if ((e.key === '=' || e.key === '+') && !e.ctrlKey) { scale = Math.min(2.5, scale*1.15); setTransform(); }
  if (e.key === '-' && !e.ctrlKey) { scale = Math.max(0.15, scale*0.87); setTransform(); }
  if (e.key === '0' && !e.ctrlKey) fitScreen();
});
</script>
</body>
</html>`;

fs.writeFileSync(outFile, html, 'utf8');
console.log(`\n✅  ERD written to: ${outFile}`);
console.log(`   Open it in any browser — no server required.`);
