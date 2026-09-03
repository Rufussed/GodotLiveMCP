/**
 * Shared, cross-session usage log for GodotLiveMCP.
 *
 * The MCP server is registered at Claude Code user scope — one binary shared
 * across every workspace that points at it — but each workspace's session
 * spawns its own separate server subprocess with its own private memory.
 * This log is the one thing that actually crosses that boundary: every tool
 * call (bridge-backed or the original godot-mcp lifecycle tools) and every
 * line of output from a Godot process this server launched are appended
 * here, timestamped, so call and resulting output can be correlated after
 * the fact — real usage data for deciding which dedicated tools are worth
 * building, rather than guessing from a tool-name list.
 *
 * Lives outside any repo so it survives rebuilds and isn't tied to one
 * project's git state.
 */

import { appendFile, mkdir } from 'fs/promises';
import { join } from 'path';
import { homedir } from 'os';

const LOG_DIR = join(homedir(), '.local', 'share', 'godot-live-mcp');
const LOG_PATH = join(LOG_DIR, 'calls.ndjson');
let dirReady: Promise<void> | null = null;

export async function logEvent(entry: Record<string, any>): Promise<void> {
  try {
    if (!dirReady) dirReady = mkdir(LOG_DIR, { recursive: true }).then(() => undefined);
    await dirReady;
    await appendFile(LOG_PATH, JSON.stringify({ ts: new Date().toISOString(), ...entry }) + '\n', 'utf8');
  } catch {
    // Diagnostic-only — never let a filesystem hiccup affect the actual operation.
  }
}
