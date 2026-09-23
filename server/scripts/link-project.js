#!/usr/bin/env node
// Links this repo's Godot addon into a Godot project, so the project runs the
// clone's addon directly (a `git pull` updates every linked project at once)
// and the in-editor Assistant panel can resolve the link back to this repo to
// find the built MCP server — no manual path or token setup.
//
// Usage: npm run link-project -- <path/to/godot/project> [--force]

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const serverDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const repoRoot = path.resolve(serverDir, '..');
const addonSource = path.join(repoRoot, 'addon', 'godot_live_mcp');
const serverEntry = path.join(serverDir, 'build', 'index.js');

function fail(msg) {
  console.error(`link-project: ${msg}`);
  process.exit(1);
}

const args = process.argv.slice(2);
const force = args.includes('--force');
const positional = args.filter((a) => !a.startsWith('--'));
if (positional.length !== 1) {
  fail('usage: npm run link-project -- <path/to/godot/project> [--force]');
}

const projectDir = path.resolve(positional[0]);
if (!fs.existsSync(path.join(projectDir, 'project.godot'))) {
  fail(`no project.godot in ${projectDir} — pass the folder that contains it`);
}
if (!fs.existsSync(serverEntry)) {
  fail(`server isn't built yet (${serverEntry} missing) — run \`npm install\` in ${serverDir} first`);
}

const addonsDir = path.join(projectDir, 'addons');
const linkPath = path.join(addonsDir, 'godot_live_mcp');
fs.mkdirSync(addonsDir, { recursive: true });

let existing = null;
try {
  existing = fs.lstatSync(linkPath);
} catch {
  // nothing there yet
}

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
        '  Re-run with --force to replace it with a link to this repo.'
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
