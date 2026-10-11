# Phase 5: packaging and submission

2026-10-11. What is ready, how to publish, and what only the owner can do.
Store rules below are from Godot's docs
([Asset Library](https://docs.godotengine.org/en/stable/community/asset_library/submitting_to_assetlib.html),
[Asset Store](https://docs.godotengine.org/en/stable/community/asset_store/submitting_to_asset_store.html));
check them again at submission time.

## What is ready

| Item | Where | Check |
|---|---|---|
| Install zip: only `addons/godot_live_mcp/` plus `LICENSE`, reproducible | `cd server && node scripts/build-release.js` → `dist/godot_live_mcp-<version>.zip` | Refuses to build if versions disagree (`plugin.cfg`, `server/package.json`, `server/src/index.ts`), `tools.json` is stale, a required file is missing or the changelog has no entry |
| Install into a brand-new project and use it | `tests/install_check.sh` | Unzips as a user would, enables the plugin on a throwaway `HOME`, checks the version, 28 Lite tools, a tool call, a refused request, and a clean editor log: **passes** |
| Version `0.2.0`, one source of truth | `addon/godot_live_mcp/plugin.cfg` | The server reports it in `initialize`; the Settings popup shows it |
| Update notice | Settings > "Check for updates" | Runs only when pressed (one request to GitHub's releases API). `tests/update_check.sh` passes, including a real request to a local stand-in server. Needs a published GitHub release to say anything |
| Licence and notices inside the addon | `addon/godot_live_mcp/LICENSE`, `THIRD_PARTY_NOTICES`; same `LICENSE` at the repo root | MIT, "GodotLiveMCP contributors" (see below) |
| Changelog | `CHANGELOG.md` | Entry for 0.2.0 |
| Icon (256×256) and three screenshots | `docs/store/` | Taken from a real editor on a clean install |
| Asset Library branch tree | `node scripts/build-release.js --tree <dir>` | Addon + LICENSE + README + `.gitignore` + `.gitattributes` (export-ignore) + icon + `screenshots/` (with `.gdignore`) |

Also fixed while testing a clean install: the panel logged "Parse JSON failed"
errors on a machine that had never run an agent CLI (it read config files that
don't exist yet).

## Why a separate branch for the Asset Library

The Asset Library has no field for a download URL. You give it a repository and a
**commit hash**, and it downloads GitHub's archive of that commit. That archive
has to contain `addons/godot_live_mcp/` at its top level. This repository keeps the
addon in `addon/` (singular) next to the server, launcher and docs, and renaming it
would break every project already linked to it. So the published tree lives on its
own branch, `assetlib`, built from the release script. The new Asset Store has a
Versions page where the zip can be uploaded.

## Publishing a release (in order; every step is yours to run)

1. Bump `version` in `plugin.cfg`, `server/package.json` and `server/src/index.ts`
   (the build refuses if they differ), add `## <version>` to `CHANGELOG.md`,
   `cd server && npm run build`, run the tests, commit.
2. `git tag v<version>` and push the tag.
3. `cd server && node scripts/build-release.js --tree ../dist/assetlib` (also
   writes the zip).
4. Update the `assetlib` branch **without rewriting its history** (the Asset
   Library keeps old commit hashes for old versions):
   ```
   # first time only
   git clone --no-checkout https://github.com/Rufussed/GodotLiveMCP.git dist/assetlib-repo
   git -C dist/assetlib-repo checkout --orphan assetlib
   # every time
   git -C dist/assetlib-repo rm -rf --quiet . 2>/dev/null; cp -a dist/assetlib/. dist/assetlib-repo/
   git -C dist/assetlib-repo add -A && git -C dist/assetlib-repo commit -m "GodotLive MCP <version>"
   git -C dist/assetlib-repo push origin assetlib
   ```
   (After the first time, `git clone --branch assetlib` instead of the orphan step.)
   The commit hash it prints is the Asset Library's "Download Commit".
5. GitHub release `v<version>` with the zip attached (this also gives the update
   check something to find):
   `gh release create v<version> dist/godot_live_mcp-<version>.zip --notes-file ...`
6. Submit to the stores (below), then do the real "install from the store on a
   fresh project" test, which is the phase's last item and cannot be done before
   approval.

## Asset Library form (godotengine.org/asset-library)

| Field | Value |
|---|---|
| Name | GodotLive MCP |
| Category | Addons / Tools |
| Godot version | 4.7 (the only version tested; one entry per version) |
| Version | 0.2.0 |
| Repository host / URL | GitHub, `https://github.com/Rufussed/GodotLiveMCP` |
| Issues URL | `https://github.com/Rufussed/GodotLiveMCP/issues` |
| Download Commit | the hash from step 4 (on the `assetlib` branch) |
| Icon URL | `https://raw.githubusercontent.com/Rufussed/GodotLiveMCP/assetlib/icon.png` |
| License | MIT |
| Previews | the three files under `screenshots/` on the `assetlib` branch (raw URLs) |
| Description | plain text only; draft below |

## Asset Store (store.godotengine.org)

Account, then **Upload Asset**: publisher name and slug, asset name and slug,
accept the terms. Then: Settings (summary, description, tags, type **Addon**,
license **MIT** matching the repository, source link, **AI usage disclosure**),
Media (thumbnail = icon, the screenshots), Versions (upload the zip; name
`0.2.0`; changelog from `CHANGELOG.md`; minimum Godot **4.7**), Pricing (free).
Then Submit for review from Overview.

## Draft text

*Summary:* Let an AI app drive your running Godot editor, with one-click setup and no extra software to install.

*Description:* GodotLive MCP lets AI apps such as Claude Code, Codex, Cursor, VS Code, opencode and Gemini CLI see and change your open Godot project while you work: the scene tree, node properties, scripts, materials, animation, audio, the running game, screenshots, and the Asset Library. The editor serves the connection itself, on your own computer only; nothing needs to be installed besides this addon. Enable the plugin, press your app's button on the "Connect your AI app" card in the AI Assistant tab, confirm what will be written, and ask your AI to do something. Includes an AI Assistant panel with chat and terminal modes, guided tours, and Lite and Full tool groups so you choose how much the AI can do.

*Security note for reviewers and users:* the server listens only on 127.0.0.1, requires a per-project token on every request, and refuses requests whose Host or Origin is not this computer. Anything holding the token can run code in the editor and edit the project, so the token is treated like a password. The addon writes configuration files outside the project only when the user presses a Connect button and confirms a dialog that shows the exact file and contents (the token is masked), keeps a backup of the original, and never touches a file it cannot parse. Network requests: Asset Library search and install (godotengine.org and GitHub) happen only when the AI calls those tools; "Check for updates" contacts GitHub only when pressed.

## Owner decisions and unknowns

- **Copyright holder.** `LICENSE` says "Copyright (c) 2026 GodotLiveMCP contributors", matching `package.json`. Change it to your name or organisation if you want (both copies, same text, or the build refuses). The stores require a licence file with the year and holder.
- **Icon provenance.** The robot icons in `addon/godot_live_mcp/icons/` are described in code comments as Material Design robot faces taken from the Nerd Font; the other icons' origins are not recorded. Confirm each licence allows redistribution and add a credit to `THIRD_PARTY_NOTICES`, or replace them, before submitting.
- **AI usage disclosure.** The Asset Store requires one if AI was used; this project was developed with AI assistance.
- **Name.** The plugin is called "GodotLive MCP Bridge" in `plugin.cfg` and the Plugins list; the store entry is drafted as "GodotLive MCP". Pick one.
- **Godot versions.** Only 4.7 on Linux is tested. The plan targets 4.4+; submit for 4.7 until that is checked. Windows and macOS are untested (phase 4).
- **Accounts and uploads** are yours: GitHub (tag, branch, release) and both stores. I have not published, pushed or submitted anything.
- **Screenshots** show a test project with the fake-home paths hidden (`~/…`); retake them if the UI changes.
