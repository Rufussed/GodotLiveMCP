#!/usr/bin/env bash
# Run to open the GodotLiveMCP launcher (Linux).
# Uses $GODOT if set, then godot/godot4 on PATH, then the Flatpak.
cd "$(dirname "$0")/launcher" || exit 1

if [[ -n $GODOT ]]; then
  godot_cmd=("$GODOT")
elif command -v godot >/dev/null; then
  godot_cmd=(godot)
elif command -v godot4 >/dev/null; then
  godot_cmd=(godot4)
elif command -v flatpak >/dev/null && flatpak info org.godotengine.Godot >/dev/null 2>&1; then
  godot_cmd=(flatpak run org.godotengine.Godot)
else
  echo "Couldn't find Godot. Put it on PATH as 'godot', or set GODOT to its binary."
  exit 1
fi

"${godot_cmd[@]}" --path . >/dev/null 2>&1 &
disown
echo "Launcher started."
