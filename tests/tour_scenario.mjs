// Tour tools end to end: validate every shipped tour with start_tour dry_run,
// check that a bad tour is rejected with its problems, then list tours and read
// the status. Needs a running scratch editor (see script_io.mjs for the env);
// works through Node or, with MCP_URL/MCP_TOKEN, the editor's HTTP endpoint.
import { readFileSync, readdirSync, writeFileSync, unlinkSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { connect } from './mcp_client.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const toursDir = join(here, '../docs/tours');
const { call, close } = await connect();
const dir = process.env.PROJECT_DIR;
if (!dir) { console.error('Set PROJECT_DIR to the scratch project (a scene is written there to validate tours against).'); process.exit(2); }
let failures = 0;
const check = (name, ok, detail = '') => { console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : '  ' + detail}`); if (!ok) failures++; };

writeFileSync(join(dir, 'zz_tour.tscn'), '[gd_scene format=3]\n\n[node name="Root" type="Control"]\n');
const opened = await call('open_scene', { path: 'res://zz_tour.tscn' });
check('open a scene to validate against', !opened.__error, JSON.stringify(opened));

const fine = await call('start_tour', { tour: { format: 'godot-live-tour/1', title: 'fine', steps: [{ text: 'Read this.', done_when: { type: 'manual' } }] }, dry_run: true });
check('a valid tour passes the dry run', !fine.__error, JSON.stringify(fine).slice(0, 200));
for (const f of readdirSync(toursDir).filter(f => f.endsWith('.tour.json'))) {
  const tour = JSON.parse(readFileSync(join(toursDir, f), 'utf8'));
  const r = await call('start_tour', { tour, dry_run: true });
  // The scratch scene lacks the nodes a shipped tour names, so either verdict is fine,
  // as long as the answer is the structured one rather than a crash or a silence.
  check(`dry run of ${f} gets a verdict`, !r.__error || r.__error.startsWith('tour is invalid'), JSON.stringify(r).slice(0, 200));
}
const bad = await call('start_tour', { tour: { format: 'godot-live-tour/1', title: 'bad', steps: [{ text: 'no done_when' }] }, dry_run: true });
check('a tour with a broken step is rejected', !!bad.__error || bad.ok === false || (bad.problems && bad.problems.length > 0), JSON.stringify(bad).slice(0, 200));
const list = await call('list_tours');
check('list_tours answers', !list.__error, JSON.stringify(list).slice(0, 200));
const status = await call('get_tour_status');
check('get_tour_status answers', !status.__error, JSON.stringify(status).slice(0, 200));
const wrong = await call('start_tour', { tuor: {} });
check('a misspelled parameter is rejected', !!wrong.__error && /unknown parameter/.test(wrong.__error), JSON.stringify(wrong).slice(0, 200));

try { unlinkSync(join(dir, 'zz_tour.tscn')); } catch {}
close();
process.exit(failures === 0 ? 0 : 1);
