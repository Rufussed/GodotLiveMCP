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
const addonsDir = path.join(projectDir, 'addons');
const linkPath = path.join(addonsDir, 'godot_live_mcp');

let existing = null;
try {
  existing = fs.lstatSync(linkPath);
} catch {
  // nothing there yet
}

if (unlink) {
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
console.log('');
console.log('Next: open the project in Godot, enable "GodotLive MCP Bridge" in');
console.log('Project > Project Settings > Plugins, then start a session from the');
console.log('AI Assistant panel — the server path and auth token are wired up automatically.');
