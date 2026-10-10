/**
 * MCP tool definitions and dispatch for tools that talk to a RUNNING GAME
 * instance via runtime_bridge.gd — the counterpart to bridgeTools.ts,
 * which only talks to the editor process. These require the user to add
 * runtime_bridge.gd as a Project Settings > Autoload singleton; installing
 * the addon plugin alone does not wire this up (an EditorPlugin and an
 * Autoload are two independent Godot mechanisms, and Run Project launches
 * a separate OS process the editor plugin has no presence in at all).
 */

import { BridgeClient } from './bridgeClient.js';
import { validateToolArgs } from './validateArgs.js';

const NODE_PATH_PROPERTY = {
  node_path: {
    type: 'string',
    description: 'Path to the node, relative to the running scene root (e.g. "Player/Sprite2D"), or "." for the root',
  },
};

const VALUE_ENCODING_NOTE =
  ' Values are Godot\'s var_to_str() string encoding (e.g. "5", "true", "\\"hello\\"", ' +
  '"Vector2(1, 2)", "Color(1, 0, 0, 1)"; colours may also be "#ff0000") — not plain JSON.';

const RUNTIME_REQUIREMENT_NOTE =
  ' Requires runtime_bridge.gd to be added as a Project Settings > Autoload singleton in the target ' +
  'project, and the game to actually be running (e.g. via run_project) — this has no effect on the editor ' +
  'itself, only a live running game instance, a separate OS process from the editor.';

export const runtimeToolNames = new Set([
  'game_eval_expression',
  'game_list_scene_tree',
  'game_get_node_properties',
  'game_set_property',
  'game_set_properties',
  'get_game_screenshot',
  'simulate_key',
  'simulate_mouse_button',
  'simulate_mouse_motion',
  'wait_for_game_condition',
  'capture_game_frames',
  'monitor_game_properties',
]);

export function isRuntimeTool(name: string): boolean {
  return runtimeToolNames.has(name);
}

export const runtimeToolDefinitions = [
  {
    name: 'game_eval_expression',
    description:
      'Evaluate a GDScript expression against a node in a RUNNING GAME instance (not the editor) and ' +
      'return the result. The game-side counterpart to eval_expression.' + RUNTIME_REQUIREMENT_NOTE + VALUE_ENCODING_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        expression: { type: 'string', description: 'GDScript expression to evaluate, e.g. "position.x" or "health"' },
      },
      required: ['expression'],
    },
  },
  {
    name: 'game_list_scene_tree',
    description: 'List the scene tree of a RUNNING GAME instance, starting at a node. The game-side counterpart to list_scene_tree.' + RUNTIME_REQUIREMENT_NOTE,
    inputSchema: {
      type: 'object',
      properties: { ...NODE_PATH_PROPERTY },
      required: [],
    },
  },
  {
    name: 'game_get_node_properties',
    description: 'Get all editor-visible properties (plus global transform for spatial nodes) of a node in a RUNNING GAME instance. The game-side counterpart to get_node_properties.' + RUNTIME_REQUIREMENT_NOTE + VALUE_ENCODING_NOTE,
    inputSchema: {
      type: 'object',
      properties: { ...NODE_PATH_PROPERTY },
      required: [],
    },
  },
  {
    name: 'game_set_property',
    description: 'Set a property on a node in a RUNNING GAME instance. The game-side counterpart to set_property — no undo/redo at runtime, a direct assignment.' + RUNTIME_REQUIREMENT_NOTE + VALUE_ENCODING_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        property_name: { type: 'string', description: 'Name of the property to set' },
        value: { type: 'string', description: 'New value, var_to_str()-encoded' },
      },
      required: ['property_name', 'value'],
    },
  },
  {
    name: 'game_set_properties',
    description: 'Set multiple properties on a node in a RUNNING GAME instance in one call. The game-side counterpart to set_properties.' + RUNTIME_REQUIREMENT_NOTE + VALUE_ENCODING_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        properties: { type: 'object', description: 'Map of property_name -> var_to_str()-encoded value' },
      },
      required: ['properties'],
    },
  },
  {
    name: 'get_game_screenshot',
    description:
      'Capture a RUNNING GAME instance\'s main viewport as a PNG image — actual gameplay, distinct from ' +
      'get_editor_screenshot which only sees the editor\'s 3D gizmo viewport.' + RUNTIME_REQUIREMENT_NOTE +
      ' Returned as an image content block, not JSON.',
    inputSchema: {
      type: 'object',
      properties: {
        max_dimension: { type: 'integer', description: 'Downscale so neither dimension exceeds this (default 800); pass 0 for full resolution' },
      },
      required: [],
    },
  },
  {
    name: 'simulate_key',
    description:
      'Simulate a keyboard key press/release in a RUNNING GAME instance via Input.parse_input_event() — ' +
      'a real event fed into the engine\'s input pipeline (reaches _input()/_unhandled_input()/' +
      'Input.is_action_pressed() the same way an actual keypress would), not just an internal flag flip.' +
      RUNTIME_REQUIREMENT_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        keycode: { type: 'string', description: 'A single character (e.g. "a", "5", " ") or a special key name: "KEY_SPACE", "KEY_ENTER", "KEY_ESCAPE", "KEY_TAB", "KEY_BACKSPACE", "KEY_DELETE", "KEY_HOME", "KEY_END", "KEY_LEFT", "KEY_RIGHT", "KEY_UP", "KEY_DOWN", "KEY_SHIFT", "KEY_CTRL", "KEY_ALT", "KEY_F1".."KEY_F12"' },
        pressed: { type: 'boolean', description: 'true for key-down, false for key-up (default true)' },
      },
      required: ['keycode'],
    },
  },
  {
    name: 'simulate_mouse_button',
    description: 'Simulate a mouse button press/release at a viewport position in a RUNNING GAME instance.' + RUNTIME_REQUIREMENT_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        button: { type: 'string', enum: ['MOUSE_BUTTON_LEFT', 'MOUSE_BUTTON_RIGHT', 'MOUSE_BUTTON_MIDDLE', 'MOUSE_BUTTON_WHEEL_UP', 'MOUSE_BUTTON_WHEEL_DOWN'], description: 'Which button (default MOUSE_BUTTON_LEFT)' },
        pressed: { type: 'boolean', description: 'true for press, false for release (default true)' },
        position: { type: 'string', description: 'var_to_str()-encoded Vector2 viewport position, e.g. "Vector2(100, 200)"' },
      },
      required: ['position'],
    },
  },
  {
    name: 'simulate_mouse_motion',
    description: 'Simulate mouse movement to a viewport position in a RUNNING GAME instance.' + RUNTIME_REQUIREMENT_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        position: { type: 'string', description: 'var_to_str()-encoded Vector2 viewport position, e.g. "Vector2(100, 200)"' },
      },
      required: ['position'],
    },
  },
  {
    name: 'wait_for_game_condition',
    description:
      'Poll a boolean GDScript expression against a node in a RUNNING GAME instance once per frame until ' +
      'it\'s true or timeout_sec elapses (capped at 4s) — use this instead of repeatedly calling ' +
      'game_eval_expression in a loop yourself, which would be one bridge round trip per frame. Useful for ' +
      'assertions/tests that depend on game state settling over a few frames (e.g. waiting for a scene ' +
      'transition or an animation to finish) rather than a framework of dedicated assertion tools — reading ' +
      'state and judging pass/fail is something you can already do yourself with the read tools.' + RUNTIME_REQUIREMENT_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        ...NODE_PATH_PROPERTY,
        expression: { type: 'string', description: 'GDScript boolean expression, e.g. "health <= 0" or "get_node(\\"Player\\").position.y > 100"' },
        timeout_sec: { type: 'number', description: 'Max seconds to wait, capped at 4 (default 2)' },
      },
      required: ['expression'],
    },
  },
  {
    name: 'capture_game_frames',
    description:
      'Capture several screenshots of a RUNNING GAME spaced interval_sec apart (real time), returned as ' +
      'consecutive image blocks labelled with their timestamp — for judging motion, animation, or anything ' +
      'a single get_game_screenshot can\'t show. Total span (count-1)*interval_sec is capped at 10s. Pair with ' +
      'simulate_key etc. by sending the input first, then capturing.' + RUNTIME_REQUIREMENT_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        count: { type: 'integer', description: 'Number of frames, 1-8 (default 4)' },
        interval_sec: { type: 'number', description: 'Seconds between frames (default 0.25; 0 = consecutive rendered frames)' },
        max_dimension: { type: 'integer', description: 'Downscale so neither dimension exceeds this (default 400; 0 = full resolution)' },
      },
      required: [],
    },
  },
  {
    name: 'monitor_game_properties',
    description:
      'Sample node properties and/or expressions in a RUNNING GAME every interval_sec for duration_sec ' +
      '(max 10s) and return the time series as {columns, rows} — one call instead of polling ' +
      'game_eval_expression yourself. Use for "does the player actually fall / does health drain / does the ' +
      'velocity settle". Every watch entry is validated before sampling starts, so a misspelled property ' +
      'errors immediately.' + VALUE_ENCODING_NOTE + RUNTIME_REQUIREMENT_NOTE,
    inputSchema: {
      type: 'object',
      properties: {
        watch: {
          type: 'array',
          description: 'What to sample. Each entry: {node_path, property} or {node_path, expression}, plus optional label.',
          items: {
            type: 'object',
            properties: {
              ...NODE_PATH_PROPERTY,
              property: { type: 'string', description: 'Property name; sub-paths like "position:y" or "velocity:x" are allowed' },
              expression: { type: 'string', description: 'GDScript expression evaluated with the node as self, e.g. "global_position.distance_to(get_node(\"../Goal\").global_position)"' },
              label: { type: 'string', description: 'Column name (defaults to node_path.property)' },
            },
          },
        },
        duration_sec: { type: 'number', description: 'How long to sample, max 10 (default 2)' },
        interval_sec: { type: 'number', description: 'Seconds between samples (default 0.1; 0 = every rendered frame)' },
        max_samples: { type: 'integer', description: 'Stop early after this many rows (default 200, max 1000)' },
      },
      required: ['watch'],
    },
  },
];

// runtime_bridge.gd caps sampling commands at 10s; allow headroom for
// frame encoding and the round trip.
const SAMPLING_TIMEOUT_MS = 15000;

let sharedClient: BridgeClient | null = null;
function getClient(): BridgeClient {
  if (!sharedClient) {
    sharedClient = new BridgeClient({
      port: Number(process.env.GODOT_LIVE_MCP_RUNTIME_PORT || 9090),
    });
  }
  return sharedClient;
}

export async function handleRuntimeTool(name: string, args: any): Promise<any> {
  validateToolArgs(runtimeToolDefinitions, name, args);
  const client = getClient();
  const params = args || {};

  switch (name) {
    case 'game_eval_expression':
      return textResult(await client.call('eval_expression', {
        node_path: params.node_path ?? '.',
        expression: params.expression,
      }));
    case 'game_list_scene_tree':
      return textResult(await client.call('list_scene_tree', {
        node_path: params.node_path ?? '.',
      }));
    case 'game_get_node_properties':
      return textResult(await client.call('get_node_properties', {
        node_path: params.node_path ?? '.',
      }));
    case 'game_set_property':
      return textResult(await client.call('set_property', {
        node_path: params.node_path ?? '.',
        property_name: params.property_name,
        value: params.value,
      }));
    case 'game_set_properties':
      return textResult(await client.call('set_properties', {
        node_path: params.node_path ?? '.',
        properties: params.properties ?? {},
      }));
    case 'get_game_screenshot':
      return imageResult(await client.call('get_game_screenshot', {
        max_dimension: params.max_dimension ?? 800,
      }));
    case 'simulate_key':
      return textResult(await client.call('simulate_key', {
        keycode: params.keycode,
        pressed: params.pressed ?? true,
      }));
    case 'simulate_mouse_button':
      return textResult(await client.call('simulate_mouse_button', {
        button: params.button ?? 'MOUSE_BUTTON_LEFT',
        pressed: params.pressed ?? true,
        position: params.position,
      }));
    case 'simulate_mouse_motion':
      return textResult(await client.call('simulate_mouse_motion', {
        position: params.position,
      }));
    case 'wait_for_game_condition':
      return textResult(await client.call('wait_for_condition', {
        node_path: params.node_path ?? '.',
        expression: params.expression,
        timeout_sec: params.timeout_sec ?? 2.0,
      }));
    case 'capture_game_frames': {
      const result = await client.call('capture_game_frames', {
        count: params.count ?? 4,
        interval_sec: params.interval_sec ?? 0.25,
        max_dimension: params.max_dimension ?? 400,
      }, SAMPLING_TIMEOUT_MS);
      return {
        content: result.frames.flatMap((f: any) => [
          { type: 'text', text: `t=${f.t.toFixed(3)}s (${f.width}x${f.height})` },
          { type: 'image', data: f.base64, mimeType: `image/${f.format}` },
        ]),
      };
    }
    case 'monitor_game_properties': {
      const result = await client.call('monitor_properties', {
        watch: params.watch,
        duration_sec: params.duration_sec ?? 2.0,
        interval_sec: params.interval_sec ?? 0.1,
        max_samples: params.max_samples ?? 200,
      }, SAMPLING_TIMEOUT_MS);
      // One row per line: pretty-printed JSON would put every cell on its own line.
      return textResult(
        JSON.stringify(result.columns) + '\n' +
        result.rows.map((r: any[]) => JSON.stringify([Number(r[0].toFixed(3)), ...r.slice(1)])).join('\n')
      );
    }
    default:
      throw new Error(`Unknown runtime tool: ${name}`);
  }
}

function imageResult(result: { base64: string; format: string }) {
  return {
    content: [
      {
        type: 'image',
        data: result.base64,
        mimeType: `image/${result.format}`,
      },
    ],
  };
}

function textResult(result: any) {
  return {
    content: [
      {
        type: 'text',
        text: typeof result === 'string' ? result : JSON.stringify(result, null, 2),
      },
    ],
  };
}
