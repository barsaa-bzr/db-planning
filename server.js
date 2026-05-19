#!/usr/bin/env node
/**
 * Local live ERD service.
 *
 * Usage:
 *   node server.js [schema.sql] [index.html] [port]
 *
 * Open the printed localhost URL. Edits made from that page can save directly
 * back to the SQL file because the browser is talking to this local service.
 */

const fs = require('fs');
const http = require('http');
const path = require('path');
const { spawnSync } = require('child_process');

const rootDir = __dirname;
const sqlFile = path.resolve(rootDir, process.argv[2] || 'lending_app_schema.sql');
const htmlFile = path.resolve(rootDir, process.argv[3] || 'index.html');
const port = Number(process.argv[4] || process.env.PORT || 5173);
const generatorFile = path.resolve(rootDir, 'generate.js');

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
}

function sendText(res, status, body, contentType = 'text/plain; charset=utf-8') {
  res.writeHead(status, {
    'Content-Type': contentType,
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
}

function readRequestBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.setEncoding('utf8');
    req.on('data', chunk => {
      body += chunk;
      if (body.length > 10 * 1024 * 1024) {
        reject(new Error('Request body is too large.'));
        req.destroy();
      }
    });
    req.on('end', () => resolve(body));
    req.on('error', reject);
  });
}

function runGenerator(inputSql, outputHtml) {
  const result = spawnSync(process.execPath, [generatorFile, inputSql, outputHtml], {
    cwd: rootDir,
    encoding: 'utf8',
  });
  if (result.status !== 0) {
    throw new Error((result.stderr || result.stdout || 'Generator failed.').trim());
  }
}

function regenerateHtml() {
  runGenerator(sqlFile, htmlFile);
}

function validateSql(sql) {
  const tmpDir = path.resolve(rootDir, '.erd-live-tmp');
  fs.mkdirSync(tmpDir, { recursive: true });
  const tmpSql = path.join(tmpDir, 'candidate.sql');
  const tmpHtml = path.join(tmpDir, 'candidate.html');
  fs.writeFileSync(tmpSql, sql, 'utf8');
  try {
    runGenerator(tmpSql, tmpHtml);
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
}

function saveSql(sql) {
  validateSql(sql);
  fs.writeFileSync(sqlFile, sql, 'utf8');
  regenerateHtml();
}

function contentTypeFor(filePath) {
  if (filePath.endsWith('.html')) return 'text/html; charset=utf-8';
  if (filePath.endsWith('.js')) return 'text/javascript; charset=utf-8';
  if (filePath.endsWith('.css')) return 'text/css; charset=utf-8';
  if (filePath.endsWith('.sql')) return 'text/plain; charset=utf-8';
  if (filePath.endsWith('.pdf')) return 'application/pdf';
  return 'application/octet-stream';
}

function serveFile(res, requestedPath) {
  const safePath = path.normalize(requestedPath).replace(/^(\.\.[/\\])+/, '');
  const filePath = path.resolve(rootDir, safePath);
  if (!filePath.startsWith(rootDir)) {
    sendText(res, 403, 'Forbidden');
    return;
  }
  if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
    sendText(res, 404, 'Not found');
    return;
  }
  const body = fs.readFileSync(filePath);
  res.writeHead(200, {
    'Content-Type': contentTypeFor(filePath),
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

    if (req.method === 'GET' && url.pathname === '/api/schema') {
      const sql = fs.readFileSync(sqlFile, 'utf8');
      const stat = fs.statSync(sqlFile);
      sendJson(res, 200, { ok: true, sql, mtimeMs: stat.mtimeMs });
      return;
    }

    if (req.method === 'POST' && url.pathname === '/api/save') {
      const body = await readRequestBody(req);
      const payload = JSON.parse(body || '{}');
      if (typeof payload.sql !== 'string') {
        sendJson(res, 400, { ok: false, error: 'Expected JSON body with a sql string.' });
        return;
      }
      saveSql(payload.sql);
      sendJson(res, 200, { ok: true, savedTo: path.relative(rootDir, sqlFile), regenerated: path.relative(rootDir, htmlFile) });
      return;
    }

    if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
      regenerateHtml();
      serveFile(res, htmlFile);
      return;
    }

    if (req.method === 'GET') {
      serveFile(res, decodeURIComponent(url.pathname.slice(1)));
      return;
    }

    sendText(res, 405, 'Method not allowed');
  } catch (err) {
    if (!res.headersSent) {
      const message = err instanceof SyntaxError ? 'Invalid JSON request body.' : (err.message || String(err));
      sendJson(res, 500, { ok: false, error: message });
    } else {
      res.end();
    }
  }
});

server.listen(port, '127.0.0.1', () => {
  regenerateHtml();
  console.log(`Live ERD service running at http://127.0.0.1:${port}/`);
  console.log(`SQL file: ${path.relative(rootDir, sqlFile)}`);
  console.log(`HTML file: ${path.relative(rootDir, htmlFile)}`);
});
