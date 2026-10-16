#!/usr/bin/env bash
set -euo pipefail
# The real editor API is required for dock setup and prompt submission. Use an
# isolated project/settings directory and fake RPC client: never launch Pi.
if [[ "$(uname -s)" != Linux ]]; then
  echo 'Editor integration runner requires Linux for XDG settings isolation.' >&2
  exit 1
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
engine="${GODOT:-godot}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/addons/test_runner" "$tmp/config" "$tmp/data"
cp -R "$root/addons/pi_agent" "$tmp/addons/"
cp "$root/tests/editor_plugin.gd" "$tmp/addons/test_runner/plugin.gd"
printf '[plugin]\nname="Test Runner"\ndescription="Feature integration tests"\nauthor=""\nversion="1"\nscript="plugin.gd"\n' > "$tmp/addons/test_runner/plugin.cfg"
printf 'config_version=5\n[application]\nconfig/name="Pi Feature Tests"\n[editor_plugins]\nenabled=PackedStringArray("res://addons/test_runner/plugin.cfg")\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n' > "$tmp/project.godot"
display_args=(--headless)
if [[ -n "${PI_TEST_CAPTURE_DIR:-}" ]]; then
  mkdir -p "$PI_TEST_CAPTURE_DIR"
  display_args=(--display-driver x11 --rendering-method gl_compatibility --rendering-driver opengl3 --audio-driver Dummy)
fi
XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" \
  "$engine" "${display_args[@]}" --editor --path "$tmp" --quit-after 300 2>&1 | tee "$tmp/result.log"
# Godot can exit successfully after a script error; require the success marker
# AND the absence of engine/script errors.
grep -q 'Editor integration tests: .* checks, 0 failures' "$tmp/result.log"
! grep -E '(SCRIPT ERROR:|ERROR:)' "$tmp/result.log"
