#!/usr/bin/env bash
# ABOUTME: Packs a release mirroir-mcp binary into an MCP Bundle (.mcpb) for one-click install in MCPB hosts.
# ABOUTME: `--check` validates mcpb/manifest.json, its version and paths, without packing (the icon is checked at pack time).
#
# Usage:
#   mcpb/build-mcpb.sh <path-to-mirroir-mcp-binary> <output.mcpb>
#   mcpb/build-mcpb.sh --check
#
# The bundle is a `binary` MCPB: the native server sits inside an app bundle,
# server/mirroir-mcp.app, so the host starts it with no Node runtime and no
# network fetch. The binary is the same one release.yml tars for npm and
# Homebrew; it builds its own .app and icon (`mirroir-mcp bundle-app`), so
# macOS Privacy & Security lists the server as "mirroir-mcp" with the robot
# icon instead of a bare exec, and the manifest's icon is the same robot.

set -euo pipefail

# Pinned so a CLI release cannot change what the bundle validates against.
MCPB_CLI_VERSION="2.1.2"
# The release binary is Apple Silicon only (embacle-ffi ships arm64 alone);
# MCPB cannot declare a CPU architecture, so the packer enforces it.
REQUIRED_ARCH="arm64"
BUNDLE_APP_PATH="server/mirroir-mcp.app"
BUNDLE_EXECUTABLE_PATH="$BUNDLE_APP_PATH/Contents/MacOS/mirroir-mcp"
BUNDLE_ICON_PATH="icon.png"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
manifest="$script_dir/manifest.json"
server_json="$repo_root/server.json"

mcpb_cli() {
    npx --yes "@anthropic-ai/mcpb@${MCPB_CLI_VERSION}" "$@"
}

json_field() {
    python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"
}

# Checks the manifest's version and paths. The schema is validated where the
# manifest is staged: `mcpb validate` also requires the icon file next to it,
# which only a pack draws, so --check validates a copy without the icon key.
check_manifest() {
    local manifest_version server_version
    manifest_version="$(json_field "$manifest" version)"
    server_version="$(json_field "$server_json" version)"
    if [ "$manifest_version" != "$server_version" ]; then
        echo "ERROR: mcpb/manifest.json version $manifest_version != server.json version $server_version" >&2
        exit 1
    fi
    # The manifest must start the executable and name the icon this script packs.
    python3 -I - "$manifest" "$BUNDLE_EXECUTABLE_PATH" "$BUNDLE_ICON_PATH" <<'PY'
import json, sys
manifest, executable, icon = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
server = manifest["server"]
expected = {
    "server.entry_point": (server["entry_point"], executable),
    "server.mcp_config.command": (server["mcp_config"]["command"], "${__dirname}/" + executable),
    "icon": (manifest.get("icon"), icon),
}
wrong = [f"{key} is {found!r}, expected {want!r}" for key, (found, want) in expected.items() if found != want]
if wrong:
    sys.exit("ERROR: mcpb/manifest.json: " + "; ".join(wrong))
PY
}

if [ "${1:-}" = "--check" ]; then
    check_manifest
    check_dir="$(mktemp -d)"
    trap 'rm -r -- "$check_dir"' EXIT
    python3 -I -c 'import json, sys; m = json.load(open(sys.argv[1])); m.pop("icon", None); json.dump(m, open(sys.argv[2], "w"))' \
        "$manifest" "$check_dir/manifest.json"
    mcpb_cli validate "$check_dir/manifest.json"
    exit 0
fi

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <path-to-mirroir-mcp-binary> <output.mcpb> | --check" >&2
    exit 64
fi

binary="$1"
output_dir="$(cd "$(dirname "$2")" && pwd)"
output="$output_dir/$(basename "$2")"

if [ ! -x "$binary" ]; then
    echo "ERROR: $binary is not an executable file" >&2
    exit 1
fi
if ! lipo -archs "$binary" | tr ' ' '\n' | grep -qx "$REQUIRED_ARCH"; then
    echo "ERROR: $binary has no $REQUIRED_ARCH slice (found: $(lipo -archs "$binary"))" >&2
    exit 1
fi

check_manifest

stage="$(mktemp -d)"
trap 'rm -r -- "$stage"' EXIT

cp "$manifest" "$stage/manifest.json"
mkdir -p "$stage/$(dirname "$BUNDLE_APP_PATH")"
"$binary" bundle-app --app "$stage/$BUNDLE_APP_PATH" --icon "$stage/$BUNDLE_ICON_PATH"
codesign --verify --strict "$stage/$BUNDLE_APP_PATH"
cp "$repo_root/LICENSE" "$stage/LICENSE"
mcpb_cli validate "$stage/manifest.json"

mcpb_cli pack "$stage" "$output"
mcpb_cli info "$output"
