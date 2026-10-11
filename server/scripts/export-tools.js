// Exports every tool definition to addon/godot_live_mcp/tools.json, the one
// list both the Node server and the in-editor server read. The TypeScript
// definitions stay the source of truth until the in-editor server reaches
// parity (docs/phase0_inventory.md, section 3).
//
//   node scripts/export-tools.js           write the file
//   node scripts/export-tools.js --check   exit 1 if the committed file is stale
//
// Each entry is the MCP tool object plus an "x_godot" object the in-editor
// server strips before answering tools/list:
//   route    "generic" (bridge command of the same name), "adapter" (named
//            GDScript function), or "node" (stays in Node)
//   target   "editor" (bridge, port 9080) or "game" (runtime bridge, port 9090)
//   command  bridge command name when it differs from the tool name
//   adapter  adapter function name, for route "adapter"
//   group    "lite" or "full"

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const here = path.dirname(fileURLToPath(import.meta.url));
const build = path.join(here, '..', 'build');
const OUT = path.join(here, '..', '..', 'addon', 'godot_live_mcp', 'tools.json');

const { lifecycleToolDefinitions } = await import(path.join(build, 'lifecycleTools.js'));
const { bridgeToolDefinitions } = await import(path.join(build, 'bridgeTools.js'));
const { runtimeToolDefinitions } = await import(path.join(build, 'runtimeTools.js'));
const { intentToolDefinitions } = await import(path.join(build, 'intentTools.js'));
const { lspToolDefinitions } = await import(path.join(build, 'lspTools.js'));

// Tools a newcomer needs; everything else is Full (docs/phase0_inventory.md, section 4).
const LITE = new Set([
  'list_scene_tree', 'get_node_properties', 'find_nodes', 'get_signals',
  'get_editor_selection', 'get_output_log', 'get_editor_screenshot', 'get_script_text',
  'open_scene', 'save_scene_live', 'add_node_live', 'remove_node', 'rename_node',
  'reparent_node', 'duplicate_node', 'select_nodes',
  'set_property', 'set_properties', 'set_transform', 'connect_signal',
  'attach_script', 'edit_script_text', 'validate_script', 'save_scripts',
  'play_scene', 'stop_scene', 'is_playing_scene',
  'eval_expression',
]);

// Bridge tools whose result is not plain text, or that live only in Node.
const BRIDGE_ADAPTERS = {
  get_editor_screenshot: 'image',
  get_inspector_screenshot: 'image',
  search_assets: 'search_assets',
  install_asset: 'install_asset',
};

// Runtime (running game) tools: bridge command, when renamed, and adapter, when the result is reshaped.
const RUNTIME = {
  game_eval_expression: { command: 'eval_expression' },
  game_list_scene_tree: { command: 'list_scene_tree' },
  game_get_node_properties: { command: 'get_node_properties' },
  game_set_property: { command: 'set_property' },
  game_set_properties: { command: 'set_properties' },
  simulate_key: {},
  simulate_mouse_button: {},
  simulate_mouse_motion: {},
  wait_for_game_condition: { command: 'wait_for_condition' },
  get_game_screenshot: { adapter: 'image' },
  capture_game_frames: { adapter: 'capture_game_frames' },
  monitor_game_properties: { command: 'monitor_properties', adapter: 'monitor_game_properties' },
};

function entry(def, meta) {
  const { name, description, inputSchema } = def;
  const x = { route: meta.route, target: meta.target ?? 'editor' };
  if (meta.command) x.command = meta.command;
  if (meta.adapter) x.adapter = meta.adapter;
  x.group = LITE.has(name) ? 'lite' : 'full';
  return { name, description, inputSchema, x_godot: x };
}

const tools = [];
for (const d of lifecycleToolDefinitions) tools.push(entry(d, { route: 'node' }));
for (const d of bridgeToolDefinitions) {
  const adapter = BRIDGE_ADAPTERS[d.name];
  tools.push(entry(d, adapter ? { route: 'adapter', adapter } : { route: 'generic' }));
}
for (const d of runtimeToolDefinitions) {
  const r = RUNTIME[d.name];
  if (!r) throw new Error(`runtime tool "${d.name}" is not classified in export-tools.js`);
  tools.push(entry(d, { route: r.adapter ? 'adapter' : 'generic', target: 'game', ...r }));
}
for (const d of intentToolDefinitions) tools.push(entry(d, { route: 'node' }));
for (const d of lspToolDefinitions) tools.push(entry(d, { route: 'node' }));

const names = tools.map((t) => t.name);
const dupes = names.filter((n, i) => names.indexOf(n) !== i);
if (dupes.length) throw new Error(`duplicate tool names: ${dupes.join(', ')}`);
const missingLite = [...LITE].filter((n) => !names.includes(n));
if (missingLite.length) throw new Error(`Lite names that are not tools: ${missingLite.join(', ')}`);
const unknownRuntime = Object.keys(RUNTIME).filter((n) => !names.includes(n));
if (unknownRuntime.length) throw new Error(`classified runtime tools that do not exist: ${unknownRuntime.join(', ')}`);
const unknownAdapters = Object.keys(BRIDGE_ADAPTERS).filter((n) => !names.includes(n));
if (unknownAdapters.length) throw new Error(`classified bridge adapters that do not exist: ${unknownAdapters.join(', ')}`);

const text = JSON.stringify({ tools }, null, 2) + '\n';

if (process.argv.includes('--check')) {
  const current = fs.existsSync(OUT) ? fs.readFileSync(OUT, 'utf8') : '';
  if (current !== text) {
    console.error('tools.json is stale: run `node scripts/export-tools.js` in server/ and commit the result.');
    process.exit(1);
  }
  console.log(`tools.json is up to date (${tools.length} tools).`);
} else {
  fs.writeFileSync(OUT, text);
  const by = (f) => tools.filter(f).length;
  console.log(`Wrote ${tools.length} tools to ${path.relative(process.cwd(), OUT)} ` +
    `(generic ${by((t) => t.x_godot.route === 'generic')}, adapter ${by((t) => t.x_godot.route === 'adapter')}, ` +
    `node ${by((t) => t.x_godot.route === 'node')}; lite ${by((t) => t.x_godot.group === 'lite')}).`);
}
