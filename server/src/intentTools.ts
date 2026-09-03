/**
 * log_intent / log_result — a pair of plain logging tools (no Godot
 * involved at all) that let the calling agent bracket one conceptual step
 * of work with a short note before its tool calls and a short outcome
 * note after. This turns the shared usage log from an undifferentiated
 * pile of tool_call entries into a sequence of self-contained
 * {intent, calls, result} units, which is what actually makes a later
 * review pass (see TOOL_CANDIDATES.md / the review-tool-candidates skill)
 * accurate instead of guesswork reconstructed from timestamps alone.
 *
 * These bypass the generic tool_call logging wrapper in index.ts
 * (handled there via a name check) and call logEvent directly with their
 * own entry `type`, since callLog.ts uses that type field to track the
 * per-step call/error tally and stamp it onto the result entry
 * automatically — see callLog.ts's updateStepTally.
 *
 * Call log_intent once per conceptually distinct step — including each
 * sub-step of a larger prompt that naturally decomposes into several —
 * not once per trivial follow-up within the same step. Call log_result
 * once that step's calls are done, whether it fully succeeded, partially
 * succeeded, or failed.
 */

import { logEvent, hasPendingReview } from './callLog.js';

export const intentToolNames = new Set(['log_intent', 'log_result']);

export function isIntentTool(name: string): boolean {
  return intentToolNames.has(name);
}

export const intentToolDefinitions = [
  {
    name: 'log_intent',
    description:
      'Log a short (one sentence) summary of what you\'re about to do, before making the tool calls for ' +
      'it. Call this once per conceptually distinct step — including each sub-step of a larger prompt that ' +
      'naturally decomposes into several — not once per trivial follow-up within the same step. This is what ' +
      'turns the shared usage log (see TOOL_CANDIDATES.md) from an undifferentiated pile of tool calls into ' +
      'reviewable {intent, calls, result} units. Pair with log_result once the step is done.',
    inputSchema: {
      type: 'object',
      properties: {
        summary: { type: 'string', description: 'One sentence: what is this step trying to accomplish, e.g. "add a bouncy platform to the scene"' },
      },
      required: ['summary'],
    },
  },
  {
    name: 'log_result',
    description:
      'Log a short outcome summary for the step most recently opened with log_intent, once its tool calls ' +
      'are done. The number of calls and errors made since that log_intent is recorded automatically — you ' +
      'don\'t need to count or report that yourself, just describe the outcome. The response includes ' +
      'pending_review_ready: true whenever a tool-candidate batch is waiting — mention this to the user when ' +
      'it comes up (e.g. "there\'s a tool-candidate batch ready whenever you want to look") rather than ' +
      'staying silent about it; a background server process has no other way to surface this.',
    inputSchema: {
      type: 'object',
      properties: {
        summary: { type: 'string', description: 'One sentence: what actually happened, e.g. "done, bounce=0.9 applied and verified" or "partial — moved but AI script wasn\'t attached"' },
        outcome: { type: 'string', enum: ['success', 'partial', 'failure'], description: 'Coarse outcome classification' },
      },
      required: ['summary', 'outcome'],
    },
  },
];

export async function handleIntentTool(name: string, args: any): Promise<any> {
  const params = args || {};
  if (name === 'log_intent') {
    await logEvent({
      type: 'intent',
      summary: params.summary,
      cwd: process.cwd(),
      pid: process.pid,
    });
    return { content: [{ type: 'text', text: JSON.stringify({ ok: true }) }] };
  }
  if (name === 'log_result') {
    await logEvent({
      type: 'result',
      summary: params.summary,
      outcome: params.outcome,
      cwd: process.cwd(),
      pid: process.pid,
    });
    const pendingReviewReady = await hasPendingReview();
    return { content: [{ type: 'text', text: JSON.stringify({ ok: true, pending_review_ready: pendingReviewReady }) }] };
  }
  throw new Error(`Unknown intent tool: ${name}`);
}
