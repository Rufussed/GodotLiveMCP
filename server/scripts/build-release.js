// Builds what gets published:
//
//   node scripts/build-release.js                 dist/godot_live_mcp-<version>.zip
//   node scripts/build-release.js --tree <dir>    also the tree for the Asset Library's
//                                                 "assetlib" branch (see docs/phase5_submission.md)
//
// The zip holds only the addon, as addons/godot_live_mcp/..., plus LICENSE: unzip it
// into a project and enable the plugin. It is byte-for-byte reproducible (fixed
// timestamps, sorted entries). Refuses to build if the versions disagree, tools.json
// is stale, a required file is missing, or the changelog has no entry for the version.

import fs from 'fs';
import path from 'path';
import zlib from 'zlib';
import crypto from 'crypto';
import { execFileSync } from 'child_process';
import { fileURLToPath } from 'url';

const here = path.dirname(fileURLToPath(import.meta.url));
const serverDir = path.resolve(here, '..');
const repo = path.resolve(serverDir, '..');
const addonDir = path.join(repo, 'addon', 'godot_live_mcp');
const args = process.argv.slice(2);
const treeDir = args.includes('--tree') ? path.resolve(args[args.indexOf('--tree') + 1] ?? '') : null;
const outDir = path.resolve(args.includes('--out') ? args[args.indexOf('--out') + 1] : path.join(repo, 'dist'));

const problems = [];
const fail = (msg) => problems.push(msg);

// ---- versions ---------------------------------------------------------------
const cfg = fs.readFileSync(path.join(addonDir, 'plugin.cfg'), 'utf8');
const version = (cfg.match(/^version="([^"]+)"/m) ?? [])[1];
if (!version) fail('plugin.cfg has no version');
const pkgVersion = JSON.parse(fs.readFileSync(path.join(serverDir, 'package.json'), 'utf8')).version;
const indexVersion = (fs.readFileSync(path.join(serverDir, 'src', 'index.ts'), 'utf8').match(/name: 'godot-mcp',\s*version: '([^']+)'/) ?? [])[1];
if (version && pkgVersion !== version) fail(`server/package.json is ${pkgVersion}, plugin.cfg is ${version}`);
if (version && indexVersion !== version) fail(`server/src/index.ts says ${indexVersion}, plugin.cfg is ${version}`);

// ---- required files and a fresh tools.json -------------------------------------------
for (const f of ['LICENSE', 'README.md', 'THIRD_PARTY_NOTICES', 'plugin.cfg', 'plugin.gd', 'tools.json']) {
  if (!fs.existsSync(path.join(addonDir, f))) fail(`addon/godot_live_mcp/${f} is missing`);
}
if (!fs.existsSync(path.join(repo, 'LICENSE'))) fail('LICENSE is missing at the repo root');
if (fs.existsSync(path.join(repo, 'LICENSE')) && fs.existsSync(path.join(addonDir, 'LICENSE')) &&
    fs.readFileSync(path.join(repo, 'LICENSE'), 'utf8') !== fs.readFileSync(path.join(addonDir, 'LICENSE'), 'utf8')) {
  fail('LICENSE at the repo root and in the addon differ');
}
try {
  execFileSync('node', [path.join(here, 'export-tools.js'), '--check'], { cwd: serverDir, stdio: 'pipe' });
} catch (e) {
  fail('tools.json is stale (run `npm run build` in server/ and commit it)');
}
const changelog = fs.existsSync(path.join(repo, 'CHANGELOG.md')) ? fs.readFileSync(path.join(repo, 'CHANGELOG.md'), 'utf8') : '';
if (version && !new RegExp(`^## ${version.replace(/\./g, '\\.')}\\b`, 'm').test(changelog)) fail(`CHANGELOG.md has no "## ${version}" entry`);

// ---- the files -----------------------------------------------------------------------------
const JUNK = /(^|\/)(\.DS_Store|\.godot|.*\.bak|.*\.tmp)(\/|$)/;
function walk(dir, rel = '') {
  const out = [];
  for (const name of fs.readdirSync(dir).sort()) {
    const r = rel ? `${rel}/${name}` : name;
    if (JUNK.test(r)) continue;
    const full = path.join(dir, name);
    const st = fs.lstatSync(full);
    if (st.isSymbolicLink()) { fail(`${r} is a symbolic link`); continue; }
    if (st.isDirectory()) out.push(...walk(full, r));
    else out.push(r);
  }
  return out;
}
const files = walk(addonDir);

if (problems.length) {
  console.error('Not building:\n' + problems.map((p) => '  - ' + p).join('\n'));
  process.exit(1);
}

// ---- zip (deflate, fixed timestamp, sorted) -----------------------------------------------------
const CRC = (() => { const t = new Uint32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
const crc32 = (buf) => { let c = 0xffffffff; for (const b of buf) c = CRC[(c ^ b) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };

function makeZip(entries) {
  const parts = [], central = [];
  let offset = 0;
  const DOS_TIME = 0, DOS_DATE = (0 << 9) | (1 << 5) | 1; // 1980-01-01
  for (const { name, data } of entries) {
    const nameBuf = Buffer.from(name, 'utf8');
    const comp = zlib.deflateRawSync(data, { level: 9 });
    const useDeflate = comp.length < data.length;
    const body = useDeflate ? comp : data;
    const crc = crc32(data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(20, 4); local.writeUInt16LE(0x0800, 6);
    local.writeUInt16LE(useDeflate ? 8 : 0, 8); local.writeUInt16LE(DOS_TIME, 10); local.writeUInt16LE(DOS_DATE, 12);
    local.writeUInt32LE(crc, 14); local.writeUInt32LE(body.length, 18); local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBuf.length, 26); local.writeUInt16LE(0, 28);
    parts.push(local, nameBuf, body);
    const cen = Buffer.alloc(46);
    cen.writeUInt32LE(0x02014b50, 0); cen.writeUInt16LE(0x031e, 4); cen.writeUInt16LE(20, 6); cen.writeUInt16LE(0x0800, 8);
    cen.writeUInt16LE(useDeflate ? 8 : 0, 10); cen.writeUInt16LE(DOS_TIME, 12); cen.writeUInt16LE(DOS_DATE, 14);
    cen.writeUInt32LE(crc, 16); cen.writeUInt32LE(body.length, 20); cen.writeUInt32LE(data.length, 24);
    cen.writeUInt16LE(nameBuf.length, 28); cen.writeUInt32LE((0o100644 << 16) >>> 0, 38); cen.writeUInt32LE(offset, 42);
    central.push(cen, nameBuf);
    offset += 30 + nameBuf.length + body.length;
  }
  const cenBuf = Buffer.concat(central);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(cenBuf.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...parts, cenBuf, end]);
}

const entries = files.map((rel) => ({ name: `addons/godot_live_mcp/${rel}`, data: fs.readFileSync(path.join(addonDir, rel)) }));
entries.push({ name: 'LICENSE', data: fs.readFileSync(path.join(repo, 'LICENSE')) });
fs.mkdirSync(outDir, { recursive: true });
const zipPath = path.join(outDir, `godot_live_mcp-${version}.zip`);
const zip = makeZip(entries);
fs.writeFileSync(zipPath, zip);
console.log(`${path.relative(process.cwd(), zipPath)}  ${entries.length} files, ${(zip.length / 1024).toFixed(0)} KB, sha256 ${crypto.createHash('sha256').update(zip).digest('hex')}`);

// ---- the Asset Library tree ------------------------------------------------------------------------
if (treeDir) {
  fs.rmSync(treeDir, { recursive: true, force: true });
  for (const e of entries) {
    const dest = path.join(treeDir, e.name);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.writeFileSync(dest, e.data);
  }
  // What the Asset Library asks of a repository: .gitignore, .gitattributes with
  // export-ignore (so a download holds only the addon and the licence), README.
  fs.writeFileSync(path.join(treeDir, '.gitignore'), '.godot/\n*.tmp\n.DS_Store\n');
  fs.writeFileSync(path.join(treeDir, '.gitattributes'),
    '* text=auto eol=lf\n/** export-ignore\n/addons !export-ignore\n/addons/** !export-ignore\n/LICENSE !export-ignore\n');
  fs.writeFileSync(path.join(treeDir, 'README.md'),
    `# GodotLive MCP ${version}\n\nThis branch holds only the installable addon, for the Godot Asset Library. ` +
    'The project, its documentation and its source are at https://github.com/Rufussed/GodotLiveMCP.\n\n' +
    'Install: copy `addons/godot_live_mcp` into your project, enable the plugin, and press your AI app\'s button ' +
    'on the "Connect your AI app" card in the AI Assistant tab.\n');
  const shots = path.join(repo, 'docs', 'store');
  if (fs.existsSync(shots)) {
    for (const f of fs.readdirSync(shots)) {
      const dest = path.join(treeDir, f === 'icon.png' ? 'icon.png' : path.join('screenshots', f));
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      fs.copyFileSync(path.join(shots, f), dest);
    }
    if (fs.existsSync(path.join(treeDir, 'screenshots'))) fs.writeFileSync(path.join(treeDir, 'screenshots', '.gdignore'), '');
  }
  console.log(`tree written to ${treeDir}`);
}
