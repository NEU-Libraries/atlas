// The Stage 1 gate: Spectral's counted rules plus a generated TypeScript
// client that must compile, held against baseline.json. The counts must match
// the baseline exactly, so a fix lowers it in the same commit and a regression
// cannot hide under an old, higher number. See docs/openapi.md.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import openapiTS, { astToString } from 'openapi-typescript';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const baselinePath = join(here, 'baseline.json');
const bin = (name) => join(here, 'node_modules', '.bin', name);
const mode = process.argv[2] || '';

if (!['', '--check', '--update', '--verbose'].includes(mode)) {
  console.error(`unknown option: ${mode}`);
  process.exit(2);
}

const documents = (dir) => readdirSync(dir).flatMap((name) => {
  const path = join(dir, name);
  if (statSync(path).isDirectory()) return documents(path);
  return name.endsWith('.yaml') ? [path] : [];
});

const spectral = (doc) => {
  let out;
  try {
    out = execFileSync(bin('spectral'), ['lint', doc, '-r', join(here, 'spectral.yaml'), '-f', 'json', '--quiet'],
      { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (e) {
    // Spectral exits 1 when it finds an error, with the report still on stdout.
    if (!e.stdout) throw e;
    out = e.stdout;
  }
  return JSON.parse(out).filter((r) => r.severity === 0);
};

// A client generator that fails, or a client that does not type-check, breaks
// every consumer that generates one. Each tsc diagnostic counts once.
const client = async (doc) => {
  const dir = mkdtempSync(join(tmpdir(), 'atlas-openapi-client-'));
  const file = join(dir, 'atlas.ts');
  try {
    writeFileSync(file, astToString(await openapiTS(pathToFileURL(doc))));
  } catch (e) {
    return [{ code: 'client-typescript', message: `openapi-typescript failed: ${e.message}`, path: [] }];
  }
  try {
    execFileSync(bin('tsc'), ['--noEmit', '--strict', '--skipLibCheck', '--target', 'es2022', file],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    return [];
  } catch (e) {
    return (e.stdout || '').split('\n').filter((l) => /error TS\d+/.test(l))
      .map((l) => ({ code: 'client-typescript', message: l, path: [] }));
  }
};

const current = {};
const findings = {};
for (const doc of documents(join(root, 'openapi')).sort()) {
  const name = relative(root, doc);
  const results = [...spectral(doc), ...(await client(doc))];
  findings[name] = results;
  current[name] = {};
  for (const r of results) current[name][r.code] = (current[name][r.code] || 0) + 1;
  current[name] = Object.fromEntries(Object.entries(current[name]).sort());
}

if (mode === '--update') {
  writeFileSync(baselinePath, `${JSON.stringify(current, null, 2)}\n`);
  console.log(`Wrote ${relative(root, baselinePath)}.`);
  process.exit(0);
}

let baseline = {};
try { baseline = JSON.parse(readFileSync(baselinePath, 'utf8')); } catch { /* first run */ }

let drift = false;
for (const name of new Set([...Object.keys(current), ...Object.keys(baseline)])) {
  const now = current[name] || {};
  const was = baseline[name] || {};
  console.log(name);
  for (const code of [...new Set([...Object.keys(now), ...Object.keys(was)])].sort()) {
    const [n, w] = [now[code] || 0, was[code] || 0];
    const mark = n > w ? `  ROSE from ${w}` : n < w ? `  fell from ${w}` : '';
    if (n !== w) drift = true;
    console.log(`  ${String(n).padStart(4)}  ${code}${mark}`);
  }
  if (mode === '--verbose') {
    for (const r of findings[name] || []) console.log(`    ${r.code}: ${r.path.join('.')} ${r.message}`);
  }
}

if (drift) {
  console.log('\nThe counts differ from openapi-lint/baseline.json.');
  console.log('A count that rose is a new fault: fix it, or accept it with --update and say why in the commit.');
  console.log('A count that fell is a fix: record it with bin/openapi-lint --update.');
  if (mode === '--check') process.exit(1);
}
