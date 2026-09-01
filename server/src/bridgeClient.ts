/**
 * TCP client for the GodotLiveMCP runtime bridge addon.
 *
 * Talks newline-delimited JSON to the bridge over 127.0.0.1. Values that
 * aren't native JSON types (Vector2, Color, NodePath, ...) are passed through
 * as Godot's var_to_str()/str_to_var() string encoding on both sides.
 */

import { connect, Socket } from 'net';
import { randomUUID } from 'crypto';

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
      throw new BridgeError(
        'No bridge token configured. Set GODOT_LIVE_MCP_TOKEN to the token printed/stored ' +
        'by the GodotLiveMCP bridge addon (user://godot_live_mcp_token.txt in the Godot project).'
      );
    }

    const id = randomUUID();
    const payload = JSON.stringify({ id, token: this.token, command, params }) + '\n';

    return new Promise((resolve, reject) => {
      const socket: Socket = connect({ host: this.host, port: this.port });
      let buffer = '';
      let settled = false;

      const cleanup = () => {
        socket.removeAllListeners();
        socket.destroy();
      };

      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        cleanup();
        reject(new BridgeError(
          `Timed out waiting for bridge response (is the GodotLiveMCP addon running in the editor?)`
        ));
      }, this.timeoutMs);

      socket.on('connect', () => {
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
