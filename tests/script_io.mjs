// Round-trip tests for reading and writing scripts and shaders through the
// bridge: writes land in the editor and on disk, saves are verified, parse
// errors are reported, awkward content survives. Needs a running Godot editor
// with the addon (scratch project), reached through the built MCP server:
//
//   GODOT_LIVE_MCP_TOKEN=… GODOT_LIVE_MCP_PORT=9081 PROJECT_DIR=/path/to/project \
//     node tests/script_io.mjs
//
// To run the same checks against the editor's own HTTP endpoint, with no Node
// server in between, set MCP_URL and MCP_TOKEN instead:
//
//   MCP_URL=http://127.0.0.1:41069/mcp MCP_TOKEN=… PROJECT_DIR=/path/to/project \
//     node tests/script_io.mjs
//
// PROJECT_DIR (optional) lets the test remove its zz_test_* files afterwards.
import { spawn } from 'node:child_process';
import { existsSync, readFileSync, unlinkSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const httpUrl = process.env.MCP_URL;
let id = 0;
let rpc, notify, close;
if (httpUrl) {
  const post = body => fetch(httpUrl, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${process.env.MCP_TOKEN}` }, body: JSON.stringify(body) });
  rpc = async (method, params) => (await post({ jsonrpc: '2.0', id: ++id, method, params })).json();
  notify = async method => { await post({ jsonrpc: '2.0', method }); };
  close = () => {};
} else {
  const server = spawn('node', [join(here, '../server/build/index.js')], { env: process.env, stdio: ['pipe', 'pipe', 'ignore'] });
  let buf = ''; const pending = {};
  server.stdout.on('data', d => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { const l = buf.slice(0, i); buf = buf.slice(i + 1);
    try { const m = JSON.parse(l); if (pending[m.id]) { pending[m.id](m); delete pending[m.id]; } } catch {} } });
  rpc = (method, params) => new Promise(r => { const i = ++id; pending[i] = r; server.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: i, method, params }) + '\n'); });
  notify = async method => { server.stdin.write(JSON.stringify({ jsonrpc: '2.0', method }) + '\n'); };
  close = () => server.kill();
}
const call = async (name, args = {}) => {
  const r = await rpc('tools/call', { name, arguments: args });
  if (r.error) return { __error: r.error.message };
  if (r.result?.isError) return { __error: r.result.content?.[0]?.text ?? 'error' };
  const t = r.result?.content?.[0]?.text ?? '';
  try { return JSON.parse(t); } catch { return { text: t }; }
};
const wait = ms => new Promise(r => setTimeout(r, ms));
let failures = 0;
const check = (name, ok, detail = '') => { console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : '  ' + detail}`); if (!ok) failures++; };
const dir = process.env.PROJECT_DIR;
const disk = p => (dir && existsSync(join(dir, p.replace('res://', ''))) ? readFileSync(join(dir, p.replace('res://', '')), 'utf8') : null);

await rpc('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'test', version: '0' } });
await notify('notifications/initialized');

const A = 'res://zz_test_a.gd';
let r = await call('edit_script_text', { path: A, text: 'extends Node\n\nfunc _ready():\n\tpass\n' });
check('create a script', r.ok && r.created && r.saved && r.editor_matches && r.disk_matches === true, JSON.stringify(r));
if (dir) check('  …file content on disk', disk(A) === 'extends Node\n\nfunc _ready():\n\tpass\n');

r = await call('edit_script_text', { path: A, old_text: '\tpass', new_text: '\tprint("hi")' });
check('partial edit without saving is reported unsaved', r.ok && r.unsaved === true && r.editor_matches && r.lines?.[0] === 4, JSON.stringify(r));
r = await call('get_script_text', { path: A });
check('read sees the unsaved edit and says dirty', r.source === 'editor' && r.dirty === true && r.text.includes('print("hi")'), JSON.stringify(r));
if (dir) check('  …disk still has the old text', disk(A).includes('pass') && !disk(A).includes('print'));
r = await call('save_scripts');
check('save_scripts saves the dirty script', r.count >= 1 && r.saved.every(s => s.saved), JSON.stringify(r));
r = await call('get_script_text', { path: A });
check('read now says clean', r.dirty === false, JSON.stringify(r));
if (dir) check('  …disk has the edit', disk(A).includes('print("hi")'));

r = await call('edit_script_text', { path: A, old_text: 'nothing like this', new_text: 'x' });
check('missing old_text is an error', !!r.__error && /not found/.test(r.__error), JSON.stringify(r));
r = await call('edit_script_text', { path: A, old_text: 'e', new_text: 'E' });
check('ambiguous old_text is an error', !!r.__error && /times/.test(r.__error), JSON.stringify(r));

r = await call('edit_script_text', { path: A, text: 'extends Node\n\nvar broken := (\n', save: true });
check('a parse error is reported, the write still lands', r.ok && r.saved && !!r.parse_error && r.disk_matches === true, JSON.stringify(r));

const odd = {
  'CRLF line endings': 'extends Node\r\n\r\nfunc f():\r\n\tpass\r\n',
  'tabs and spaces mixed': 'extends Node\n\nfunc f():\n\tif true:\n\t    pass\n',
  'unicode': 'extends Node\n\n# héllo 日本語 🙂\nvar s := "ünï"\n',
  'no trailing newline': 'extends Node\n\nfunc f():\n\tpass',
  'long file (5000 lines)': 'extends Node\n' + Array.from({ length: 5000 }, (_, i) => `# line ${i}`).join('\n') + '\n',
};
for (const [name, text] of Object.entries(odd)) {
  r = await call('edit_script_text', { path: A, text, save: true });
  const back = await call('get_script_text', { path: A });
  const onDisk = disk(A);
  // The editor's own save cleanup may change indentation/whitespace; then the
  // result says `normalized`. Either way the tab and the file must agree.
  const exact = r.editor_matches && r.disk_matches === true;
  const agrees = back.dirty === false && (onDisk === null || onDisk.replace(/\r\n/g, '\n') === back.text.replace(/\r\n/g, '\n'));
  check(`round trip: ${name}${r.normalized ? ' (editor normalized it)' : ''}`, r.ok && r.saved && (exact || r.normalized) && agrees, JSON.stringify(r).slice(0, 220));
}

const S = 'res://zz_test_s.gdshader';
r = await call('edit_script_text', { path: S, text: 'shader_type spatial;\n\nvoid fragment() {\n}\n' });
check('create a shader', r.ok && r.created && r.editor_matches, JSON.stringify(r));
r = await call('edit_script_text', { path: S, text: 'shader_type spatial;\n\nvoid fragment() {\n    ALBEDO = vec3(1.0, 0.0, 0.0);\n}\n', save: true });
check('edit and save a shader', r.ok && r.saved && r.editor_matches && r.disk_matches === true, JSON.stringify(r));
r = await call('get_script_text', { path: S });
check('read the shader back', r.ok && r.text.includes('ALBEDO'), JSON.stringify(r).slice(0, 200));
if (dir) check('  …shader on disk', disk(S)?.includes('ALBEDO'));

if (dir) for (const f of readdirSync(dir)) if (f.startsWith('zz_test_')) unlinkSync(join(dir, f));
console.log(failures === 0 ? '\nall passed' : `\n${failures} FAILED`);
close();
process.exit(failures === 0 ? 0 : 1);
