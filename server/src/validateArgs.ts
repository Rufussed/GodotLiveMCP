/**
 * Rejects tool calls that pass a parameter name not declared in that tool's
 * inputSchema, instead of letting the handler silently default the field it
 * expected and ignore the one it got. Found via real usage: a second MCP
 * client (Codex) guessed plausible-but-wrong names (`path` instead of
 * `node_path`, etc.) against several bridge tools, and — because handlers
 * pick named fields off `args` with `??`/optional-chaining fallbacks — each
 * call returned `ok: true` describing the wrong node instead of failing.
 */

interface ToolDefinition {
  name: string;
  inputSchema: {
    properties?: Record<string, unknown>;
  };
}

export function validateToolArgs(definitions: ToolDefinition[], name: string, args: any): void {
  if (!args || typeof args !== 'object') return;

  const def = definitions.find((d) => d.name === name);
  if (!def) return;

  const allowed = new Set(Object.keys(def.inputSchema.properties ?? {}));
  const unknown = Object.keys(args).filter((key) => !allowed.has(key));
  if (unknown.length === 0) return;

  const expected = allowed.size > 0 ? [...allowed].sort().join(', ') : '(no parameters)';
  throw new Error(
    `unknown parameter(s) for "${name}": ${unknown.join(', ')} — expected one of: ${expected}`
  );
}
