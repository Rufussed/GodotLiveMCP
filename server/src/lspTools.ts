/**
 * get_script_diagnostics — wraps Godot's own built-in GDScript language
 * server (see lspClient.ts) as an MCP tool. Distinct from bridge-backed
 * tools: this talks directly to Godot's LSP port, not through bridge.gd,
 * so it works purely from the file on disk (or an in-memory draft) —
 * no live scene tree involved, and no bridge token required.
 *
 * Supersedes validate_script for anything beyond a bare parse check:
 * validate_script only returns an error code on failure and tells the
 * caller to go read the Output panel by hand for the actual message.
 * This returns real diagnostics (type mismatches, unused variables,
 * etc.) with severity, message, and line/column, directly.
 */

import { readFile } from 'fs/promises';
import { join } from 'path';
import { getScriptDiagnostics, LspError } from './lspClient.js';

export const lspToolNames = new Set(['get_script_diagnostics']);

export function isLspTool(name: string): boolean {
  return lspToolNames.has(name);
}

export const lspToolDefinitions = [
  {
    name: 'get_script_diagnostics',
    description:
      'Get real GDScript diagnostics (type errors, unused variables, and similar static checks) for a ' +
      'script, from Godot\'s own built-in language server — the same one VSCode\'s Godot extension uses. ' +
      'Requires the Godot editor to be open for this project (the LSP is part of the editor process). ' +
      'Checks on-disk content by default; pass `content` to check draft text instead, before it\'s ever ' +
      'written to disk — e.g. to validate a script before attach_script/run_script writes or runs it. ' +
      'Catches real static type errors (e.g. assigning a String to an int-typed variable) and warnings ' +
      '(e.g. unused variables), but is not exhaustive — it does not catch every possible mistake (e.g. ' +
      'calling a nonexistent method on a loosely-typed value may go unflagged); treat a clean result as ' +
      '"no issues found", not a full correctness guarantee.',
    inputSchema: {
      type: 'object',
      properties: {
        projectPath: {
          type: 'string',
          description: 'Absolute path to the Godot project directory (same as other tools\' projectPath)',
        },
        scriptPath: {
          type: 'string',
          description: 'res://-relative path to the script, e.g. "res://addons/godot_live_mcp/bridge.gd"',
        },
        content: {
          type: 'string',
          description: 'Optional: check this text instead of the file\'s current on-disk content (e.g. a draft not yet saved)',
        },
      },
      required: ['projectPath', 'scriptPath'],
    },
  },
];

export async function handleLspTool(name: string, args: any): Promise<any> {
  if (name !== 'get_script_diagnostics') {
    throw new Error(`Unknown LSP tool: ${name}`);
  }
  const params = args || {};
  const projectPath: string = params.projectPath;
  const scriptPath: string = params.scriptPath;

  if (!projectPath) {
    throw new Error('projectPath is required');
  }
  if (!scriptPath || !scriptPath.startsWith('res://')) {
    throw new Error('scriptPath must start with "res://"');
  }
  if (scriptPath.includes('..')) {
    throw new Error('scriptPath must not contain ".."');
  }

  const relative = scriptPath.slice('res://'.length);
  const absoluteScriptPath = join(projectPath, relative);

  let content: string;
  if (typeof params.content === 'string') {
    content = params.content;
  } else {
    try {
      content = await readFile(absoluteScriptPath, 'utf8');
    } catch (err: any) {
      throw new Error(`Could not read ${scriptPath}: ${err.message}`);
    }
  }

  try {
    const diagnostics = await getScriptDiagnostics(projectPath, absoluteScriptPath, content);
    return {
      content: [{
        type: 'text',
        text: JSON.stringify({ script_path: scriptPath, diagnostics, clean: diagnostics.length === 0 }),
      }],
    };
  } catch (err: any) {
    if (err instanceof LspError) {
      throw new Error(err.message);
    }
    throw err;
  }
}
