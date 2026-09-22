/**
 * TCP client for Godot's built-in GDScript language server.
 *
 * Distinct from bridgeClient.ts: that talks to our own addon (bridge.gd)
 * over a newline-delimited JSON protocol we designed. This talks to
 * Godot's OWN GDScript LSP, which the editor runs unconditionally
 * whenever it's open (127.0.0.1:6005 by default) — the same server
 * VSCode's official Godot extension connects to. Standard LSP framing
 * (Content-Length-prefixed JSON-RPC 2.0 over TCP), with one confirmed-live
 * quirk: `initialize` gets no response at all — not even an error, just
 * silence forever — unless the request includes the deprecated `rootPath`
 * field alongside `rootUri`. Sending `rootUri` alone (the modern,
 * spec-correct field) is not enough.
 *
 * v1 scope: one thing only — open a script, wait for the diagnostics
 * Godot pushes back, close it. Reconnects fresh per call rather than
 * keeping a persistent LSP session alive, which is simpler and avoids
 * any stale-state risk between calls; revisit if the reconnect overhead
 * (an initialize round trip per call) ever matters in practice.
 * Confirmed live: Godot does publish an empty diagnostics array for a
 * clean file rather than staying silent, so waiting for the first
 * `textDocument/publishDiagnostics` notification for our URI is a
 * reliable success signal, not something that needs a "did we just not
 * get a notification yet vs. is it actually clean" guess.
 */

import { connect, Socket } from 'net';
import { pathToFileURL } from 'url';

export class LspError extends Error {}

export interface LspDiagnostic {
  severity: 'error' | 'warning' | 'information' | 'hint';
  message: string;
  line: number;   // 1-indexed, matching how GDScript's own error output reports lines
  column: number;  // 1-indexed
  end_line: number;
  end_column: number;
  source: string | null;
}

const SEVERITY_NAMES: Record<number, LspDiagnostic['severity']> = {
  1: 'error',
  2: 'warning',
  3: 'information',
  4: 'hint',
};

interface JsonRpcMessage {
  jsonrpc?: string;
  id?: number | string;
  method?: string;
  params?: any;
  result?: any;
  error?: any;
}

/** Incrementally parses Content-Length-framed JSON-RPC messages off a growing buffer. */
class LspFrameReader {
  private buffer: Buffer = Buffer.alloc(0);

  push(chunk: Buffer): JsonRpcMessage[] {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    const messages: JsonRpcMessage[] = [];
    while (true) {
      const headerEnd = this.buffer.indexOf('\r\n\r\n');
      if (headerEnd === -1) break;
      const header = this.buffer.subarray(0, headerEnd).toString('utf8');
      const match = /Content-Length:\s*(\d+)/i.exec(header);
      if (!match) {
        // Malformed framing — drop what we have rather than spin forever.
        this.buffer = Buffer.alloc(0);
        break;
      }
      const length = Number(match[1]);
      const bodyStart = headerEnd + 4;
      if (this.buffer.length < bodyStart + length) break; // wait for more data
      const body = this.buffer.subarray(bodyStart, bodyStart + length).toString('utf8');
      this.buffer = this.buffer.subarray(bodyStart + length);
      try {
        messages.push(JSON.parse(body));
      } catch {
        // skip unparsable frame, keep going
      }
    }
    return messages;
  }
}

function frame(obj: JsonRpcMessage): Buffer {
  const body = Buffer.from(JSON.stringify(obj), 'utf8');
  const header = Buffer.from(`Content-Length: ${body.length}\r\n\r\n`, 'utf8');
  return Buffer.concat([header, body]);
}

export interface LspConfig {
  host?: string;
  port?: number;
  timeoutMs?: number;
}

/**
 * Opens `scriptContent` (already-read text, not re-read from disk here —
 * caller decides what "the script" means, e.g. unsaved edits) against
 * Godot's LSP as `absoluteScriptPath`, waits for the diagnostics Godot
 * pushes back for it, then closes the document and disconnects.
 */
export async function getScriptDiagnostics(
  projectRootAbsolutePath: string,
  absoluteScriptPath: string,
  scriptContent: string,
  config?: LspConfig
): Promise<LspDiagnostic[]> {
  const host = config?.host || process.env.GODOT_LIVE_MCP_LSP_HOST || '127.0.0.1';
  const port = config?.port || Number(process.env.GODOT_LIVE_MCP_LSP_PORT || 6005);
  const timeoutMs = config?.timeoutMs || 8000;

  if (host !== '127.0.0.1' && host !== 'localhost') {
    throw new LspError(`Refusing to connect to non-local LSP host "${host}". The GDScript LSP is localhost-only by design.`);
  }

  const rootUri = pathToFileURL(projectRootAbsolutePath).toString();
  const docUri = pathToFileURL(absoluteScriptPath).toString();

  return new Promise((resolve, reject) => {
    const socket: Socket = connect({ host, port });
    const reader = new LspFrameReader();
    let settled = false;
    let initialized = false;

    const cleanup = () => {
      socket.removeAllListeners();
      socket.destroy();
    };
    const finish = (fn: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      cleanup();
      fn();
    };

    const timer = setTimeout(() => {
      finish(() => reject(new LspError(
        initialized
          ? `Timed out waiting for diagnostics on ${absoluteScriptPath} (is the Godot editor open for this project?)`
          : `Timed out waiting for the GDScript language server to initialize (is the Godot editor open for this project? LSP listens on ${host}:${port} while the editor is running).`
      )));
    }, timeoutMs);

    socket.on('connect', () => {
      socket.write(frame({
        jsonrpc: '2.0',
        id: 1,
        method: 'initialize',
        params: {
          processId: process.pid,
          // Both fields required — confirmed live: rootUri alone gets no
          // response at all from Godot's LSP, silently, forever.
          rootPath: projectRootAbsolutePath,
          rootUri: rootUri,
          capabilities: { textDocument: { publishDiagnostics: {} } },
          trace: 'off',
        },
      }));
    });

    socket.on('data', (chunk) => {
      if (settled) return;
      for (const msg of reader.push(chunk)) {
        if (msg.id === 1 && msg.result) {
          initialized = true;
          socket.write(frame({ jsonrpc: '2.0', method: 'initialized', params: {} }));
          socket.write(frame({
            jsonrpc: '2.0',
            method: 'textDocument/didOpen',
            params: {
              textDocument: { uri: docUri, languageId: 'gdscript', version: 1, text: scriptContent },
            },
          }));
          continue;
        }
        if (msg.method === 'textDocument/publishDiagnostics' && msg.params?.uri === docUri) {
          const diagnostics: LspDiagnostic[] = (msg.params.diagnostics || []).map((d: any) => ({
            severity: SEVERITY_NAMES[d.severity] ?? 'error',
            message: d.message,
            line: d.range.start.line + 1,
            column: d.range.start.character + 1,
            end_line: d.range.end.line + 1,
            end_column: d.range.end.character + 1,
            source: d.source ?? null,
          }));
          // Best-effort cleanup — don't block returning the result on it.
          try {
            socket.write(frame({
              jsonrpc: '2.0',
              method: 'textDocument/didClose',
              params: { textDocument: { uri: docUri } },
            }));
          } catch { /* socket may already be closing */ }
          finish(() => resolve(diagnostics));
          return;
        }
        // Anything else (e.g. Godot's own gdscript/capabilities notice,
        // or publishDiagnostics for some other already-open doc) is
        // expected noise — ignore and keep waiting.
      }
    });

    socket.on('error', (err) => {
      finish(() => reject(new LspError(`Could not reach the GDScript language server at ${host}:${port}: ${err.message}`)));
    });

    socket.on('close', () => {
      finish(() => reject(new LspError('LSP connection closed before diagnostics arrived.')));
    });
  });
}
