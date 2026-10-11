// Tiny MCP test client shared by the drivers: talks to the editor's HTTP
// endpoint when MCP_URL is set (with MCP_TOKEN), otherwise to the Node server
// over stdio. call() returns the parsed JSON of a tool's text reply, or
// { __error } when the call failed.
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

export async function connect() {
  const here = dirname(fileURLToPath(import.meta.url));
  const url = process.env.MCP_URL;
  let id = 0, rpc, notify, close;
  if (url) {
    const post = body => fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${process.env.MCP_TOKEN}` }, body: JSON.stringify(body) });
    rpc = async (method, params) => (await post({ jsonrpc: '2.0', id: ++id, method, params })).json();
    notify = async method => { await post({ jsonrpc: '2.0', method }); };
    close = () => {};
  } else {
    const server = spawn('node', [join(here, '../server/build/index.js')], { env: process.env, stdio: ['pipe', 'pipe', 'ignore'] });
    let buf = ''; const pending = {};
    server.stdout.on('data', d => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { const l = buf.slice(0, i); buf = buf.slice(i + 1);
      try { const m = JSON.parse(l); if (pending[m.id]) { pending[m.id](m); delete pending[m.id]; } } catch {} } });
    rpc = (method, params) => new Promise(r => { const i = ++id; pending[i] = r; server.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: i, method, params }) + '\n'); });
    notify = async method => { server.stdin.write(JSON.stringify({ jsonrpc: '2.0', method }) + '\n'); };
    close = () => server.kill();
  }
  await rpc('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'test', version: '0' } });
  await notify('notifications/initialized');
  const call = async (name, args = {}) => {
    const r = await rpc('tools/call', { name, arguments: args });
    if (r.error) return { __error: r.error.message };
    if (r.result?.isError) return { __error: r.result.content?.[0]?.text ?? 'error' };
    const t = r.result?.content?.[0]?.text ?? '';
    try { return JSON.parse(t); } catch { return { text: t }; }
  };
  return { rpc, call, close };
}
