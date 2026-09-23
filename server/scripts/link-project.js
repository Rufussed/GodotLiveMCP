#!/usr/bin/env node
// Links this repo's Godot addon into a Godot project, so the project runs the
// clone's addon directly (a `git pull` updates every linked project at once)
// and the in-editor Assistant panel can resolve the link back to this repo to
// find the built MCP server — no manual path or token setup.
//
// Usage: npm run link-project -- <path/to/godot/project> [--force | --unlink]
//
// Exit codes: 0 success, 1 error, 2 an existing non-link addon folder is in
// the way (re-run with --force to replace it) — distinct so a caller like
// the launcher app can offer that choice instead of parsing error text.

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const serverDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const repoRoot = path.resolve(serverDir, '..');
const addonSource = path.join(repoRoot, 'addon', 'godot_live_mcp');
const serverEntry = path.join(serverDir, 'build', 'index.js');

function fail(msg, code = 1) {
  console.error(`link-project: ${msg}`);
  process.exit(code);
}

const PLUGIN_CFG = 'res://addons/godot_live_mcp/plugin.cfg';

// Adds or removes the addon in project.godot's [editor_plugins] enabled list,
// the same entry Project Settings > Plugins writes. If the project is open in
// Godot at the time, the editor may overwrite this when it next saves its
// settings, so this is meant for projects that aren't open.
function setPluginEnabled(projectFile, enabled) {
  const text = fs.readFileSync(projectFile, 'utf8');
  const sectionRe = /^\[editor_plugins\][^\[]*/m;
  const listRe = /^enabled=PackedStringArray\((.*)\)$/m;
  const section = text.match(sectionRe);
  const listMatch = section && section[0].match(listRe);
  const entries = listMatch
    ? [...listMatch[1].matchAll(/"((?:[^"\\]|\\.)*)"/g)].map((m) => m[1])
    : [];
  if (entries.includes(PLUGIN_CFG) === enabled) return false;
  const next = enabled ? [...entries, PLUGIN_CFG] : entries.filter((e) => e !== PLUGIN_CFG);
  const line = `enabled=PackedStringArray(${next.map((e) => `"${e}"`).join(', ')})`;
  let out;
  if (listMatch) {
    out = text.replace(sectionRe, section[0].replace(listRe, line));
  } else if (section) {
    out = text.replace(sectionRe, section[0].replace(/^\[editor_plugins\]\n/, `[editor_plugins]\n\n${line}\n`));
  } else {
    out = `${text.replace(/\n*$/, '\n')}\n[editor_plugins]\n\n${line}\n`;
  }
  fs.writeFileSync(projectFile, out);
  return true;
}

const args = process.argv.slice(2);
const force = args.includes('--force');
const unlink = args.includes('--unlink');
const positional = args.filter((a) => !a.startsWith('--'));
if (positional.length !== 1) {
  fail('usage: npm run link-project -- <path/to/godot/project> [--force | --unlink]');
}

const projectDir = path.resolve(positional[0]);
if (!fs.existsSync(path.join(projectDir, 'project.godot'))) {
  fail(`no project.godot in ${projectDir} — pass the folder that contains it`);
}
const projectFile = path.join(projectDir, 'project.godot');
const addonsDir = path.join(projectDir, 'addons');
const linkPath = path.join(addonsDir, 'godot_live_mcp');

let existing = null;
try {
  existing = fs.lstatSync(linkPath);
} catch {
  // nothing there yet
}

if (unlink) {
  if (setPluginEnabled(projectFile, false)) {
    console.log('Disabled the plugin in project.godot.');
  }
  if (!existing) {
    console.log(`Nothing to unlink at ${linkPath}.`);
    process.exit(0);
  }
  if (!existing.isSymbolicLink()) {
    fail(`${linkPath} is a real folder (a copied addon), not a link — not removing it.`);
  }
  // unlinkSync removes only the link itself, never the repo folder it points to.
  fs.unlinkSync(linkPath);
  console.log(`Unlinked ${linkPath}`);
  process.exit(0);
}

if (!fs.existsSync(serverEntry)) {
  fail(`server isn't built yet (${serverEntry} missing) — run \`npm install\` in ${serverDir} first`);
}
fs.mkdirSync(addonsDir, { recursive: true });

if (existing) {
  if (existing.isSymbolicLink()) {
    const current = path.resolve(addonsDir, fs.readlinkSync(linkPath));
    if (current === addonSource) {
      console.log(`Already linked: ${linkPath} -> ${addonSource}`);
      if (setPluginEnabled(projectFile, true)) console.log('Enabled the plugin in project.godot.');
      process.exit(0);
    }
    fs.unlinkSync(linkPath);
  } else if (force) {
    fs.rmSync(linkPath, { recursive: true, force: true });
    console.log(`Removed existing copied addon at ${linkPath} (--force).`);
  } else {
    fail(
      `${linkPath} already exists and isn't a link (probably a copied older version).\n` +
        '  Re-run with --force to replace it with a link to this repo.',
      2
    );
  }
}

// 'junction' makes a directory junction on Windows (no admin rights needed,
// unlike a true symlink); the type argument is ignored on Linux/macOS.
fs.symlinkSync(addonSource, linkPath, 'junction');

console.log(`Linked ${linkPath} -> ${addonSource}`);
if (setPluginEnabled(projectFile, true)) console.log('Enabled the plugin in project.godot.');
console.log('');
console.log('Next: open the project in Godot and start a session from the AI Assistant');
console.log('panel — the server path and auth token are wired up automatically.');
console.log('(If the project was already open, reopen it or enable "GodotLive MCP Bridge"');
console.log('in Project > Project Settings > Plugins.)');
