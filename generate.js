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
  { id: 'auth',     label: 'Users & Auth',        color: '#4f8ef7', tables: ['users','customer_profiles','merchant_profiles','staff_profiles','otp_sessions','user_sessions','calpro_message_logs'] },
  { id: 'kyc',      label: 'KYC & 3rd-Party',     color: '#a78bfa', tables: ['dan_verifications','hur_data_snapshots','sain_score_requests','kyc_verification_steps'] },
  { id: 'credit',   label: 'Credit & Limits',      color: '#34d399', tables: ['credit_score_results','credit_scoring_factors','loan_limits'] },
  { id: 'loans',    label: 'Loans & Products',     color: '#f59e0b', tables: ['loan_products','loan_applications','loans','loan_account_mappings'] },
  { id: 'bnpl',     label: 'BNPL Flow',            color: '#f97316', tables: ['bnpl_terminals','bnpl_payment_invoices','bnpl_qr_codes','bnpl_transactions','bnpl_terminal_callbacks'] },
  { id: 'repay',    label: 'Repayment & QPay',     color: '#ec4899', tables: ['repayment_schedules','qpay_repayment_invoices','qpay_repayment_callbacks','repayment_transactions','penalty_records'] },
  { id: 'polaris',  label: 'Polaris Core Banking', color: '#06b6d4', tables: ['polaris_accounts','polaris_transactions','polaris_api_logs','polaris_sync_queue'] },
  { id: 'merchant', label: 'Merchant Portal',      color: '#84cc16', tables: ['merchant_portal_users','merchant_refund_requests','merchant_return_items','merchant_settlements'] },
  { id: 'audit',    label: 'Audit & Notifications',color: '#94a3b8', tables: ['audit_logs','staff_action_reviews','service_pause_windows','notification_templates','notification_logs','system_event_logs'] },
];

function getDomain(tableName) {
  for (const d of DOMAINS) {
    if (d.tables.includes(tableName)) return d;
  }
  return { id: 'other', label: 'Other', color: '#64748b' };
}

// ─── LAYOUT ────────────────────────────────────────────────────────────────
// Place tables in a grid grouped by domain, with some spacing

function layoutTables(tables) {
  const positions = {};
  const CARD_W = 260, CARD_H_BASE = 80, ROW_H = 22;
  const DOMAIN_PAD = 40, COL_GAP = 40, ROW_GAP = 40;

  // Group by domain
  const groups = {};
  for (const name of Object.keys(tables)) {
    const d = getDomain(name);
    if (!groups[d.id]) groups[d.id] = { domain: d, tables: [] };
    groups[d.id].tables.push(name);
  }

  let gx = 60, gy = 60;
  const COLS_PER_DOMAIN = 3;

  for (const gid of Object.keys(groups)) {
    const grp = groups[gid];
    const colCount = Math.min(COLS_PER_DOMAIN, grp.tables.length);
    let maxRowHeight = 0;

    grp.tables.forEach((name, i) => {
      const col = i % colCount;
      const row = Math.floor(i / colCount);
      const h = CARD_H_BASE + tables[name].columns.length * ROW_H;
      const x = gx + col * (CARD_W + COL_GAP);
      const y = gy + row * (Math.max(maxRowHeight, h) + ROW_GAP);
      positions[name] = { x, y, w: CARD_W, h };
      if (col === colCount - 1) maxRowHeight = 0;
      else maxRowHeight = Math.max(maxRowHeight, h);
    });

    const rowCount = Math.ceil(grp.tables.length / colCount);
    const groupHeight = rowCount * (CARD_H_BASE + 200 + ROW_GAP);
    gy += groupHeight + DOMAIN_PAD * 2;
    if (gy > 4000) { gy = 60; gx += (CARD_W + COL_GAP) * COLS_PER_DOMAIN + 100; }
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

<div id="toolbar">
  <button class="tool-btn" id="btn-fit" title="Fit to screen">⊞ Fit</button>
  <div class="tool-divider"></div>
  <button class="tool-btn" id="btn-zoom-in">＋</button>
  <button class="tool-btn" id="btn-zoom-out">－</button>
  <div class="tool-divider"></div>
  <button class="tool-btn" id="btn-edges" title="Toggle FK lines">⇢ Edges</button>
  <button class="tool-btn" id="btn-reset" title="Reset selection">⟳ Reset</button>
</div>

<canvas id="minimap"></canvas>

<script>
// ── DATA ──────────────────────────────────────────────────────────────────
const TABLES  = ${tableData};
const ENUMS   = ${enumData};
const INDEXES = ${indexData};
const VIEWS   = ${viewData};
const POSITIONS = ${posData};
const EDGES   = ${edgeData};
const DOMAINS = ${domainData};

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

function setTransform() {
  canvas.style.transform = \`translate(\${tx}px,\${ty}px) scale(\${scale})\`;
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

function buildCards() {
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

// ── STATS ─────────────────────────────────────────────────────────────────
document.getElementById('stat-tables').textContent = Object.keys(TABLES).length;
document.getElementById('stat-edges').textContent  = EDGES.length;
const totalCols = Object.values(TABLES).reduce((s,t) => s + t.columns.length, 0);
document.getElementById('stat-cols').textContent   = totalCols;
document.getElementById('stat-enums').textContent  = Object.keys(ENUMS).length;
document.getElementById('stat-indexes').textContent = Object.values(INDEXES).reduce((sum, list) => sum + list.length, 0);
document.getElementById('stat-views').textContent  = Object.keys(VIEWS).length;

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
