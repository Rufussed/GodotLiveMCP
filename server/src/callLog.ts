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
 * Lives outside any repo by default so it survives rebuilds and isn't tied
 * to one project's git state (override with GODOT_LIVE_MCP_LOG_PATH).
 *
 * This file only ever does mechanical bookkeeping (append, count, batch,
 * rotate, discard by size) — it never judges whether anything in the log is
 * worth turning into a tool. That judgment requires an LLM and happens in
 * the `review-tool-candidates` skill, on the batches this file hands it via
 * `calls.pending-review.ndjson`, never automatically. See TOOL_CANDIDATES.md
 * for the review criteria and CONTRIBUTING.md for what happens after.
 *
 * Rotation is triggered by a "candidate signal" counter, not raw file size —
 * most logged calls succeed and are noise for review purposes, so sizing
 * batches by bytes alone tends to produce review prompts with nothing
 * useful in them. Two mechanical (no-judgment) signals increment the
 * counter, matching the two failure shapes this project has actually hit
 * building its own tools:
 * - an error (`ok: false`) — a real, if approximate, proxy for a structural
 *   gap (a call the current tools genuinely couldn't do, or a validation
 *   catching a mistake).
 * - a "burst" — several calls fired in quick succession, a proxy for the
 *   pure-efficiency pattern (many round trips standing in for what should
 *   be one call), the same shape that led to this project's own
 *   get_material_info tool. Counted once per burst, not once per call in
 *   it, so one inefficient sequence doesn't dominate the tally on its own.
 * Byte size remains as an independent backstop, in case a long, all-
 * successful, non-bursty session still grows the file large before either
 * signal fires.
 *
 * Env vars (all optional; defaults preserve always-on logging):
 * - GODOT_LIVE_MCP_LOG=off              disable logging entirely.
 * - GODOT_LIVE_MCP_LOG_REVIEW=off       permanent opt-out of review: batches
 *                                       are discarded at rotation instead of
 *                                       being handed to
 *                                       calls.pending-review.ndjson. Logging
 *                                       itself stays on (still useful for
 *                                       the process-output correlation
 *                                       feature).
 * - GODOT_LIVE_MCP_LOG_CANDIDATE_THRESHOLD  candidate-signal count that
 *                                       triggers rotation. Default 3.
 * - GODOT_LIVE_MCP_LOG_BURST_SIZE       calls within the burst gap window
 *                                       that count as one burst signal.
 *                                       Default 5.
 * - GODOT_LIVE_MCP_LOG_BURST_GAP_MS     max gap between consecutive calls
 *                                       for them to count as the same
 *                                       burst. Default 10000.
 * - GODOT_LIVE_MCP_LOG_MAX_MB           byte-size backstop, independent of
 *                                       the candidate-signal count. Default
 *                                       10.
 * - GODOT_LIVE_MCP_LOG_PATH             override the log file location.
 *
 * All thresholds are untuned starting points — env-var overridable rather
 * than hardcoded, since there's no real usage data yet to calibrate them
 * against.
 */

import { appendFile, mkdir, readFile, stat, writeFile } from 'fs/promises';
import { dirname, join } from 'path';
import { homedir } from 'os';

const DEFAULT_LOG_DIR = join(homedir(), '.local', 'share', 'godot-live-mcp');
const DEFAULT_MAX_MB = 10;
const DEFAULT_CANDIDATE_THRESHOLD = 3;
const DEFAULT_BURST_SIZE = 5;
const DEFAULT_BURST_GAP_MS = 10_000;
const PENDING_HARD_CAP_MB = 50; // backstop if review is never run — drop, don't grow forever

let dirReady: Promise<void> | null = null;

// In-memory burst/candidate tracking — per server process, resets on
// restart. That's fine: a restart is a natural place for the tally to
// start over, same as the log itself being process-local until rotated.
let candidateCount = 0;
let lastCallAtMs: number | null = null;
let currentBurstLength = 0;
let currentBurstCounted = false;

function resolveLogPath(): string {
  return process.env.GODOT_LIVE_MCP_LOG_PATH || join(DEFAULT_LOG_DIR, 'calls.ndjson');
}

function pendingReviewPath(logPath: string): string {
  return join(dirname(logPath), 'calls.pending-review.ndjson');
}

function isLoggingEnabled(): boolean {
  return (process.env.GODOT_LIVE_MCP_LOG || '').toLowerCase() !== 'off';
}

function isReviewEnabled(): boolean {
  return (process.env.GODOT_LIVE_MCP_LOG_REVIEW || '').toLowerCase() !== 'off';
}

function envInt(name: string, fallback: number): number {
  const n = Number(process.env[name]);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

function maxBatchBytes(): number {
  return envInt('GODOT_LIVE_MCP_LOG_MAX_MB', DEFAULT_MAX_MB) * 1024 * 1024;
}

function candidateThreshold(): number {
  return envInt('GODOT_LIVE_MCP_LOG_CANDIDATE_THRESHOLD', DEFAULT_CANDIDATE_THRESHOLD);
}

function burstSize(): number {
  return envInt('GODOT_LIVE_MCP_LOG_BURST_SIZE', DEFAULT_BURST_SIZE);
}

function burstGapMs(): number {
  return envInt('GODOT_LIVE_MCP_LOG_BURST_GAP_MS', DEFAULT_BURST_GAP_MS);
}

/**
 * Updates the burst/error tally for one entry and returns the new
 * candidate-signal count. Pure arithmetic on this entry and the timestamp
 * of the previous one — no lookback beyond that, no judgment about content.
 */
function updateCandidateSignal(entry: Record<string, any>, now: number): number {
  if (lastCallAtMs !== null && now - lastCallAtMs <= burstGapMs()) {
    currentBurstLength += 1;
  } else {
    currentBurstLength = 1;
    currentBurstCounted = false;
  }
  lastCallAtMs = now;

  if (!currentBurstCounted && currentBurstLength >= burstSize()) {
    candidateCount += 1;
    currentBurstCounted = true;
  }

  if (entry.ok === false) {
    candidateCount += 1;
  }

  return candidateCount;
}

export async function logEvent(entry: Record<string, any>): Promise<void> {
  if (!isLoggingEnabled()) return;
  try {
    const logPath = resolveLogPath();
    if (!dirReady) dirReady = mkdir(dirname(logPath), { recursive: true }).then(() => undefined);
    await dirReady;

    const now = Date.now();
    const signalCount = updateCandidateSignal(entry, now);

    // Append first so the entry that triggers rotation is included in the
    // batch that gets rotated, rather than starting the next one.
    await appendFile(logPath, JSON.stringify({ ts: new Date(now).toISOString(), ...entry }) + '\n', 'utf8');

    let shouldRotate = signalCount >= candidateThreshold();
    if (!shouldRotate) {
      shouldRotate = await exceedsSizeBackstop(logPath);
    }
    if (shouldRotate) {
      await rotate(logPath);
      candidateCount = 0;
    }
  } catch {
    // Diagnostic-only — never let a filesystem hiccup affect the actual operation.
  }
}

async function exceedsSizeBackstop(logPath: string): Promise<boolean> {
  try {
    return (await stat(logPath)).size >= maxBatchBytes();
  } catch {
    return false; // doesn't exist yet
  }
}

/**
 * Mechanical batch rotation — pure file movement, no judgment about the
 * content is made or needed here. Called once a trigger (candidate-signal
 * count or the size backstop) has already decided rotation should happen.
 */
async function rotate(logPath: string): Promise<void> {
  let currentBatch: string;
  try {
    currentBatch = await readFile(logPath, 'utf8');
  } catch {
    return; // doesn't exist yet — nothing to rotate
  }
  if (currentBatch.length === 0) return;

  if (isReviewEnabled()) {
    const pendingPath = pendingReviewPath(logPath);
    let pendingSize = 0;
    try {
      pendingSize = (await stat(pendingPath)).size;
    } catch {
      // no existing pending-review file yet
    }
    if (pendingSize + Buffer.byteLength(currentBatch, 'utf8') <= PENDING_HARD_CAP_MB * 1024 * 1024) {
      await appendFile(pendingPath, currentBatch, 'utf8');
    }
    // else: the hard cap is already reached and nobody has run the review
    // skill — drop this batch rather than growing without bound. The
    // existing pending file is left untouched for whenever review happens.
  }
  // Review disabled, or this batch was handled above either way — the live
  // log always starts fresh so new entries never land in an oversized file.
  await writeFile(logPath, '', 'utf8');
}
