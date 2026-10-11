/**
 * Definitions of the tools that launch Godot or run headless operations
 * (handled in index.ts). Kept here so the tools.json export can import them
 * without starting a server.
 */

export const lifecycleToolDefinitions = [
  {
    name: 'launch_editor',
    description: 'Launch Godot editor for a specific project',
    inputSchema: {
      type: 'object',
      properties: {
        projectPath: {
          type: 'string',
          description: 'Path to the Godot project directory',
        },
      },
      required: ['projectPath'],
    },
  },
  {
    name: 'run_project',
    description: 'Run the Godot project and capture output',
    inputSchema: {
      type: 'object',
      properties: {
        projectPath: {
          type: 'string',
          description: 'Path to the Godot project directory',
        },
        scene: {
          type: 'string',
          description: 'Optional: Specific scene to run',
        },
      },
      required: ['projectPath'],
    },
  },
  {
    name: 'get_debug_output',
    description: 'Get the current debug output and errors',
    inputSchema: {
      type: 'object',
      properties: {},
      required: [],
    },
  },
  {
    name: 'stop_project',
    description: 'Stop the currently running Godot project',
    inputSchema: {
      type: 'object',
      properties: {},
      required: [],
    },
  },
  {
    name: 'get_godot_version',
    description: 'Get the installed Godot version',
    inputSchema: {
      type: 'object',
      properties: {},
      required: [],
    },
  },
  {
    name: 'list_projects',
    description: 'List Godot projects in a directory',
    inputSchema: {
      type: 'object',
      properties: {
        directory: {
          type: 'string',
          description: 'Directory to search for Godot projects',
        },
        recursive: {
          type: 'boolean',
          description: 'Whether to search recursively (default: false)',
        },
      },
      required: ['directory'],
    },
  },
  {
    name: 'get_project_info',
    description: 'Retrieve metadata about a Godot project',
    inputSchema: {
      type: 'object',
      properties: {
        projectPath: {
          type: 'string',
          description: 'Path to the Godot project directory',
        },
      },
      required: ['projectPath'],
    },
  },
  {
    name: 'create_scene',
    description: 'Create a new Godot scene file',
    inputSchema: {
      type: 'object',
      properties: {
        projectPath: {
          type: 'string',
          description: 'Path to the Godot project directory',
        },
        scenePath: {
          type: 'string',
          description: 'Path where the scene file will be saved (relative to project)',
        },
        rootNodeType: {
          type: 'string',
          description: 'Type of the root node (e.g., Node2D, Node3D)',
        },
      },
      required: ['projectPath', 'scenePath'],
    },
  },
  {
    name: 'add_node',
    description: 'Add a node to an existing scene',
    inputSchema: {
      type: 'object',
      properties: {
        projectPath: {
          type: 'string',
          description: 'Path to the Godot project directory',
        },
        scenePath: {
          type: 'string',
          description: 'Path to the scene file (relative to project)',
        },
        parentNodePath: {
          type: 'string',
          description: 'Path to the parent node (e.g., "root" or "root/Player")',
        },
        nodeType: {
          type: 'string',
          description: 'Type of node to add (e.g., Sprite2D, CollisionShape2D)',
        },
        nodeName: {
          type: 'string',
          description: 'Name for the new node',
        },
        properties: {
          type: 'object',
          description: 'Optional properties to set on the node',
        },
      },
      required: ['projectPath', 'scenePath', 'nodeType', 'nodeName'],
    },
  },
  {
    name: 'load_sprite',
    description: 'Load a sprite into a Sprite2D node',
    inputSchema: {
      type: 'object',
      properties: {
        projectPath: {
          type: 'string',
          description: 'Path to the Godot project directory',
        },
        scenePath: {
          type: 'string',
          description: 'Path to the scene file (relative to project)',
        },
        nodePath: {
          type: 'string',
          description: 'Path to the Sprite2D node (e.g., "root/Player/Sprite2D")',
        },
        texturePath: {
          type: 'string',
          description: 'Path to the texture file (relative to project)',
        },
      },
      required: ['projectPath', 'scenePath', 'nodePath', 'texturePath'],
    },
  },
  {
    name: 'export_mesh_library',
    description: 'Export a scene as a MeshLibrary resource',
    inputSchema: {
      type: 'object',
      properties: {
        projectPath: {
          type: 'string',
          description: 'Path to the Godot project directory',
        },
        scenePath: {
          type: 'string',
          description: 'Path to the scene file (.tscn) to export',
        },
        outputPath: {
          type: 'string',
          description: 'Path where the mesh library (.res) will be saved',
        },
        meshItemNames: {
          type: 'array',
          items: {
            type: 'string',
          },
          description: 'Optional: Names of specific mesh items to include (defaults to all)',
        },
      },
      required: ['projectPath', 'scenePath', 'outputPath'],
    },
  },
  {
    name: 'save_scene',
    description:
      'Resave a scene FILE via a separate headless Godot process, entirely independent of any running ' +
      'editor: it load()s the .tscn fresh from disk, instantiates it, and re-packs THAT — it never sees ' +
      'the live editor\'s in-memory scene state. If a bridge tool (add_node_live, set_property, ' +
      'set_transform, ...) has changed the live scene since the last save, those changes are NOT on ' +
      'disk yet and this tool will silently discard them while still reporting success. Confirmed live ' +
      '(2026-09-22): a real session hit exactly this. Use save_scene_live instead whenever an editor is ' +
      'open for this project — this file-based tool is only correct for scenes whose only edits came ' +
      'through file-based tools (create_scene, add_node) with no live editor session involved.',
    inputSchema: {
      type: 'object',
      properties: {
        projectPath: {
          type: 'string',
          description: 'Path to the Godot project directory',
        },
        scenePath: {
          type: 'string',
          description: 'Path to the scene file (relative to project)',
        },
        newPath: {
          type: 'string',
          description: 'Optional: New path to save the scene to (for creating variants)',
        },
      },
      required: ['projectPath', 'scenePath'],
    },
  },
  {
    name: 'get_uid',
    description: 'Get the UID for a specific file in a Godot project (for Godot 4.4+)',
    inputSchema: {
      type: 'object',
      properties: {
        projectPath: {
          type: 'string',
          description: 'Path to the Godot project directory',
        },
        filePath: {
          type: 'string',
          description: 'Path to the file (relative to project) for which to get the UID',
        },
      },
      required: ['projectPath', 'filePath'],
    },
  },
  {
    name: 'update_project_uids',
    description: 'Update UID references in a Godot project by resaving resources (for Godot 4.4+)',
    inputSchema: {
      type: 'object',
      properties: {
        projectPath: {
          type: 'string',
          description: 'Path to the Godot project directory',
        },
      },
      required: ['projectPath'],
    },
  },
];
