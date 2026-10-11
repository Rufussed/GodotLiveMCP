// Parity harness: runs one list of tool calls through the Node server (stdio,
// reaching the editor's bridge) and through the editor's own HTTP endpoint,
// against the same scratch editor, and compares what comes back. Needs a
// scratch editor started with GODOT_LIVE_MCP_PROFILE=full:
//
//   PROJECT_DIR=/path/to/scratch GODOT_LIVE_MCP_TOKEN=… GODOT_LIVE_MCP_PORT=9081 \
//   MCP_URL=http://127.0.0.1:<port>/mcp MCP_TOKEN=… node tests/parity.mjs
//
// With GAME=1 and a running game (e.g. `godot --headless --path <scratch> --editor-pid 1`),
// the running-game tools are compared on real answers; without it they must both fail.
// The editor is reset to the same scene before each pass, so every call sees
// the same state. Results are compared as parsed JSON, so "1" vs "1.0" and key
// order don't count. A tool error is compared by its message, whether the
// server reports it as a protocol error (Node) or as isError (in-editor).
import { spawn } from 'node:child_process';
import { writeFileSync, unlinkSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { isDeepStrictEqual } from 'node:util';

const here = dirname(fileURLToPath(import.meta.url));
const dir = process.env.PROJECT_DIR;
if (!dir || !process.env.MCP_URL || !process.env.MCP_TOKEN) {
  console.error('Set PROJECT_DIR, MCP_URL and MCP_TOKEN (and the Node server env: GODOT_LIVE_MCP_TOKEN, GODOT_LIVE_MCP_PORT).');
  process.exit(2);
}

function nodeClient() {
  const server = spawn('node', [join(here, '../server/build/index.js')], { env: process.env, stdio: ['pipe', 'pipe', 'ignore'] });
  let buf = '', id = 0; const pending = {};
  server.stdout.on('data', d => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { const l = buf.slice(0, i); buf = buf.slice(i + 1);
    try { const m = JSON.parse(l); if (pending[m.id]) { pending[m.id](m); delete pending[m.id]; } } catch {} } });
  const rpc = (method, params) => new Promise(r => { const i = ++id; pending[i] = r; server.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: i, method, params }) + '\n'); });
  return { name: 'node', rpc, close: () => server.kill(), notify: m => server.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: m }) + '\n') };
}
function httpClient() {
  let id = 0;
  const post = body => fetch(process.env.MCP_URL, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${process.env.MCP_TOKEN}` }, body: JSON.stringify(body) });
  return { name: 'http', rpc: async (method, params) => (await post({ jsonrpc: '2.0', id: ++id, method, params })).json(), close() {}, notify: m => post({ jsonrpc: '2.0', method: m }) };
}

/** What a caller sees: parsed JSON text, an image's shape, or the error message. */
function norm(r) {
  if (r.error) return { error: r.error.message };
  const res = r.result;
  if (res?.isError) return { error: res.content?.[0]?.text ?? '' };
  return (res?.content ?? []).map(c => {
    if (c.type === 'image') return { image: c.mimeType, bytes: c.data ? 'present' : 'missing' };
    try { return JSON.parse(c.text); } catch { return c.text; }
  });
}

const SCENE = '[gd_scene format=3]\n\n[node name="Root" type="Node3D"]\n\n[node name="A" type="Node3D" parent="."]\n\n[node name="M" type="MeshInstance3D" parent="."]\n';
const SCRIPT_PATH = 'res://zz_parity.gd';
const GAME_CALLS = [
  ['game_eval_expression', { expression: '1' }],
  ['game_list_scene_tree', {}],
  ['get_game_screenshot', {}],
  ['capture_game_frames', {}],
  ['monitor_game_properties', { watch: [{ node_path: '.', property: 'name' }], duration_sec: 0 }],
  ['wait_for_game_condition', { expression: 'true' }],
  ['simulate_key', { keycode: 'KEY_A' }],
];
const calls = [
  ['list_scene_tree', {}],
  ['list_scene_tree', { node_path: 'A' }],
  ['get_node_properties', { node_path: 'A', properties: ['position', 'visible'] }],
  ['find_nodes', { type: 'MeshInstance3D' }],
  ['get_signals', { node_path: 'M' }],
  ['get_node_groups', { node_path: 'A' }],
  ['get_editor_selection', {}],
  ['eval_expression', { expression: '1 + 2' }],
  ['eval_expression', { node_path: 'A', expression: 'name' }],
  ['run_script', { source: 'return node.get_child_count()' }],
  ['add_node_live', { parent_path: '.', node_type: 'Label3D', node_name: 'L' }],
  ['set_property', { node_path: 'L', property_name: 'text', value: '"hi"' }],
  ['set_properties', { node_path: 'L', properties: { pixel_size: '0.02', visible: 'true' } }],
  ['set_transform', { node_path: 'A', position: 'Vector3(1, 2, 3)', scale: 'Vector3(2, 2, 2)' }],
  ['get_node_properties', { node_path: 'A', properties: ['position', 'scale'] }],
  ['rename_node', { node_path: 'L', new_name: 'Label' }],
  ['duplicate_node', { node_path: 'A' }],
  ['set_node_groups', { node_path: 'A', groups: ['x', 'y'] }],
  ['get_node_groups', { node_path: 'A' }],
  ['select_nodes', { node_paths: ['A'] }],
  ['get_editor_selection', {}],
  ['clear_editor_selection', {}],
  ['reparent_node', { node_path: 'Label', new_parent_path: 'A' }],
  ['add_mesh_instance', { parent_path: '.', mesh_type: 'BoxMesh', mesh_params: { size: 'Vector3(1, 1, 1)' }, node_name: 'Box' }],
  ['set_material_3d', { node_path: 'Box', material_params: { albedo_color: 'Color(1, 0, 0, 1)' } }],
  ['get_material_info', { node_path: 'Box' }],
  ['setup_collision', { node_path: 'Box', shape_type: 'BoxShape3D' }],
  ['get_collision_info', { node_path: 'Box' }],
  ['get_physics_layers', { node_path: 'Box' }],
  ['get_node_bounds', { node_path: 'Box' }],
  ['remove_node', { node_path: 'A/Label' }],
  ['edit_script_text', { path: SCRIPT_PATH, text: 'extends Node\n\nfunc _ready():\n\tpass\n' }],
  ['get_script_text', { path: SCRIPT_PATH }],
  ['validate_script', { script_path: SCRIPT_PATH }],
  ['attach_script', { node_path: 'M', script_path: SCRIPT_PATH }],
  ['edit_script_text', { path: SCRIPT_PATH, old_text: 'pass', new_text: 'print(1' }],
  ['validate_script', { script_path: SCRIPT_PATH }],
  ['edit_script_text', { path: SCRIPT_PATH, text: 'extends Node\n' }],
  ['is_playing_scene', {}],
  ['list_tours', {}],
  ['get_tour_status', {}],
  ['get_audio_bus_layout', {}],
  ['get_editor_screenshot', {}],
  ['get_inspector_screenshot', {}],
  ['search_assets', { query: 'dialogue', max_results: 3 }],
  ['search_assets', { query: 'terrain', category: 'Tools', sort: 'updated', max_results: 2, godot_version: '4.4' }],
  ['search_assets', { query: 'zzzz-no-such-addon-zzzz' }],
  ['install_asset', { asset_id: 'abc' }],
  // Errors must read the same.
  ['list_scene_tree', { path: 'A' }],
  ['get_node_properties', { node_path: 'Nope' }],
  ['set_property', { node_path: 'A', property_name: 'no_such_property', value: '1' }],
  ['open_scene', { path: 'res://does_not_exist.tscn' }],
  // Running-game tools. With no game running both servers must fail; the in-editor
// wording is deliberately more helpful, so only "it is an error" is compared.
  ...GAME_CALLS.map(c => (process.env.GAME ? c : [...c, { anyError: true }])),
];

async function runPass(client) {
  await client.rpc('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'parity', version: '0' } });
  await client.notify('notifications/initialized');
  // Reset: fresh scene file, open it, drop edits from the previous pass.
  if (existsSync(join(dir, 'zz_parity.gd'))) unlinkSync(join(dir, 'zz_parity.gd'));
  writeFileSync(join(dir, 'zz_parity.tscn'), SCENE);
  await client.rpc('tools/call', { name: 'open_scene', arguments: { path: 'res://zz_parity.tscn' } });
  await client.rpc('tools/call', { name: 'run_script', arguments: { source: 'EditorInterface.reload_scene_from_path("res://zz_parity.tscn")\nreturn true' } });
  await new Promise(r => setTimeout(r, 1500));
  const out = [];
  for (const [name, args] of calls) out.push(norm(await client.rpc('tools/call', { name, arguments: args })));
  return out;
}

const node = nodeClient(), http = httpClient();
let failures = 0;
const report = (name, ok, detail = '') => { console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : '\n      ' + detail}`); if (!ok) failures++; };

// The list of tools both servers offer, with identical definitions.
await node.rpc('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'parity', version: '0' } });
const nodeTools = (await node.rpc('tools/list', {})).result.tools;
const httpTools = (await http.rpc('tools/list', {})).result.tools;
const nodeByName = Object.fromEntries(nodeTools.map(t => [t.name, t]));
let sameDefs = 0;
for (const t of httpTools) {
  const n = nodeByName[t.name];
  if (!n) { report(`tools/list: ${t.name} exists in Node`, false, 'only in-editor'); continue; }
  if (isDeepStrictEqual(n.inputSchema, t.inputSchema) && n.description === t.description) sameDefs++;
  else report(`tools/list: definition of ${t.name} matches`, false, 'description or schema differs');
}
report(`tools/list: ${sameDefs} of ${httpTools.length} in-editor definitions match Node's`, sameDefs === httpTools.length);

const nodeOut = await runPass(node);
const httpOut = await runPass(http);
calls.forEach(([name, args, opts], i) => {
  const same = opts?.anyError ? Boolean(nodeOut[i].error && httpOut[i].error) : isDeepStrictEqual(nodeOut[i], httpOut[i]);
  report(`${name} ${JSON.stringify(args).slice(0, 70)}`, same,
    `node: ${JSON.stringify(nodeOut[i]).slice(0, 400)}\n      http: ${JSON.stringify(httpOut[i]).slice(0, 400)}`);
});

for (const f of ['zz_parity.tscn', 'zz_parity.gd']) if (existsSync(join(dir, f))) unlinkSync(join(dir, f));
node.close();
console.log(failures === 0 ? '\nAll calls match.' : `\n${failures} difference(s).`);
process.exit(failures === 0 ? 0 : 1);
