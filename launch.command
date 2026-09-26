#!/bin/zsh
# Double-click in Finder to open the GodotLiveMCP launcher (macOS).
# Uses $GODOT if set, then `godot` on PATH, then Godot*.app in Applications.
cd "$(dirname "$0")/launcher" || exit 1

godot_bin="$GODOT"
[[ -z $godot_bin ]] && godot_bin=$(command -v godot)
if [[ -z $godot_bin ]]; then
  for app in /Applications/Godot*.app(N) ~/Applications/Godot*.app(N); do
    [[ -x $app/Contents/MacOS/Godot ]] && godot_bin=$app/Contents/MacOS/Godot && break
  done
fi
if [[ -z $godot_bin ]]; then
  echo "Couldn't find Godot. Put Godot.app in /Applications, or set GODOT to its binary."
  read -k 1 "?Press any key to close."
  exit 1
fi

"$godot_bin" --path . >/dev/null 2>&1 &!
echo "Launcher started. You can close this window."
