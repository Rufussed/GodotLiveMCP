// set_nested_property on a component of a value-type property ("position:y",
// "modulate:a"), which tour "Show me" derives for single-axis steps. Needs a
// running scratch editor (see script_io.mjs for the env); works through Node
// or, with MCP_URL/MCP_TOKEN, the editor's HTTP endpoint.
import { writeFileSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import { connect } from './mcp_client.mjs';

const { call, close } = await connect();
const dir = process.env.PROJECT_DIR;
if (!dir) { console.error('Set PROJECT_DIR to the scratch project (a scene is written there).'); process.exit(2); }
let failures = 0;
const check = (name, ok, detail = '') => { console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : '  ' + detail}`); if (!ok) failures++; };

const scene = join(dir, 'zz_nested.tscn');
writeFileSync(scene, '[gd_scene format=3]\n\n[node name="Root" type="Node2D"]\n\n[node name="Ball" type="Node2D" parent="."]\nposition = Vector2(3, 4)\n');
const opened = await call('open_scene', { path: 'res://zz_nested.tscn' });
check('open the scratch scene', !opened.__error, JSON.stringify(opened));

const y = await call('set_nested_property', { node_path: 'Ball', property_path: 'position:y', value: '10' });
check('position:y sets one axis', !y.__error && Number(y.value) === 10, JSON.stringify(y));
const props = await call('get_node_properties', { node_path: 'Ball' });
check('the other axis is untouched', JSON.stringify(props).includes('Vector2(3, 10)'), JSON.stringify(props).slice(0, 300));

const a = await call('set_nested_property', { node_path: 'Ball', property_path: 'modulate:a', value: '0.5' });
check('modulate:a sets one channel', !a.__error && Math.abs(Number(a.value) - 0.5) < 1e-6, JSON.stringify(a));

const bad = await call('set_nested_property', { node_path: 'Ball', property_path: 'position:w', value: '1' });
check('an unknown component fails loudly', !!bad.__error && bad.__error.includes('no component'), JSON.stringify(bad));

await close();
try { unlinkSync(scene); } catch {}
console.log(failures ? `${failures} failed` : 'All passed');
process.exit(failures ? 1 : 0);
