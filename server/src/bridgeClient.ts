/**
 * TCP client for the GodotLiveMCP runtime bridge addon.
 *
 * Talks newline-delimited JSON to the bridge over 127.0.0.1. Values that
 * aren't native JSON types (Vector2, Color, NodePath, ...) are passed through
 * as Godot's var_to_str()/str_to_var() string encoding on both sides.
 */

import { connect, Socket } from 'net';
import { randomUUID } from 'crypto';
import fs from 'fs';
import os from 'os';
import path from 'path';

/**
 * Finds the token the bridge addon saved for the Godot project this server
 * was started in (walking up from the working directory to project.godot),
 * so a client started inside the project — Codex, a plain `claude`, any MCP
 * client — works without being handed the token. The bridge saves it at
 * user://godot_live_mcp_token.txt, i.e. <Godot data dir>/app_userdata/
 * <project name>/. Projects using a custom user dir aren't covered.
 */
export function discoverProjectToken(startDir: string = process.cwd()): string {
  let dir = path.resolve(startDir);
  for (;;) {
    const projectFile = path.join(dir, 'project.godot');
    if (fs.existsSync(projectFile)) {
      const m = fs.readFileSync(projectFile, 'utf8').match(/^config\/name="((?:[^"\\]|\\.)*)"/m);
      if (!m) return '';
      const name = m[1].replace(/\\"/g, '"');
      const home = os.homedir();
      const dataDir =
        process.platform === 'win32' ? path.join(process.env.APPDATA || path.join(home, 'AppData', 'Roaming'), 'Godot')
        : process.platform === 'darwin' ? path.join(home, 'Library', 'Application Support', 'Godot')
        : path.join(process.env.XDG_DATA_HOME || path.join(home, '.local', 'share'), 'godot');
      try {
        return fs.readFileSync(path.join(dataDir, 'app_userdata', name, 'godot_live_mcp_token.txt'), 'utf8').trim();
      } catch {
        return '';
      }
    }
    const parent = path.dirname(dir);
    if (parent === dir) return '';
    dir = parent;
  }
}

// Call-level usage logging (for reviewing what tools get used and how)
// lives one layer up, in index.ts's single CallToolRequestSchema handler —
// that's the one choke point every tool call passes through, bridge-backed
// or not, so logging there covers both without double-logging bridge calls
// here too. See callLog.ts.

export interface BridgeRequest {
  command: string;
  params?: Record<string, any>;
}

export interface BridgeConfig {
  host?: string;
  port?: number;
  token?: string;
  timeoutMs?: number;
}

export class BridgeError extends Error {}

export class BridgeClient {
  private host: string;
  private port: number;
  private token: string;
  private timeoutMs: number;

  constructor(config?: BridgeConfig) {
    this.host = config?.host || process.env.GODOT_LIVE_MCP_HOST || '127.0.0.1';
    this.port = config?.port || Number(process.env.GODOT_LIVE_MCP_PORT || 9080);
    this.token = config?.token || process.env.GODOT_LIVE_MCP_TOKEN || '';
    this.timeoutMs = config?.timeoutMs || 5000;

    if (this.host !== '127.0.0.1' && this.host !== 'localhost') {
      throw new BridgeError(
        `Refusing to connect to non-local bridge host "${this.host}". ` +
        `The bridge is localhost-only by design.`
      );
    }
  }

  async call(command: string, params: Record<string, any> = {}): Promise<any> {
    if (!this.token) {
      this.token = discoverProjectToken();
    }
    if (!this.token) {
      throw new BridgeError(
        'No bridge token configured. Set GODOT_LIVE_MCP_TOKEN to the token printed/stored ' +
        'by the GodotLiveMCP bridge addon (user://godot_live_mcp_token.txt in the Godot project), ' +
        'or start this MCP client inside the Godot project folder so it can find that file.'
      );
    }
    try {
      return await this.send(this.token, command, params);
    } catch (err) {
      // The configured token can be the wrong one (e.g. a fixed global token
      // while this editor generated its own) — fall back to the project's.
      if (err instanceof BridgeError && err.message === 'invalid token') {
        const discovered = discoverProjectToken();
        if (discovered && discovered !== this.token) {
          const result = await this.send(discovered, command, params);
          this.token = discovered;
          return result;
        }
      }
      throw err;
    }
  }

  private send(token: string, command: string, params: Record<string, any>): Promise<any> {
    const id = randomUUID();
    const payload = JSON.stringify({ id, token, command, params }) + '\n';

    return new Promise((resolve, reject) => {
      const socket: Socket = connect({ host: this.host, port: this.port });
      let buffer = '';
      let settled = false;
      let connected = false;

      const cleanup = () => {
        socket.removeAllListeners();
        socket.destroy();
      };

      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        cleanup();
        // Once connected, the addon is demonstrably running (nothing else
        // listens on this port), so blaming it was wrong: real use saw this
        // message on save_scene_live while a call two seconds later was
        // answered. What silence means is a busy editor or a modal dialog —
        // and that the command may still finish, so a retry could repeat it.
        reject(new BridgeError(connected
          ? `No reply to "${command}" within ${this.timeoutMs / 1000}s. The GodotLiveMCP addon is connected, so the editor is ` +
            `probably busy or showing a dialog (check the editor window). The command may still complete — check the ` +
            `result before repeating it.`
          : `Timed out connecting to the GodotLiveMCP bridge (is the addon running in the editor?)`
        ));
      }, this.timeoutMs);

      socket.on('connect', () => {
        connected = true;
        socket.write(payload);
      });

      socket.on('data', (chunk) => {
        buffer += chunk.toString('utf8');
        const nl = buffer.indexOf('\n');
        if (nl === -1) return;
        const line = buffer.slice(0, nl);
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        cleanup();
        try {
          const response = JSON.parse(line);
          if (!response.ok) {
            reject(new BridgeError(response.error || 'unknown bridge error'));
          } else {
            resolve(response.result);
          }
        } catch (e: any) {
          reject(new BridgeError(`Malformed bridge response: ${e.message}`));
        }
      });

      socket.on('error', (err) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        cleanup();
        reject(new BridgeError(
          `Could not reach GodotLiveMCP bridge at ${this.host}:${this.port}: ${err.message}`
        ));
      });
    });
  }
}
