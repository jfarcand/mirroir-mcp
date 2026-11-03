#!/usr/bin/env bash
# ABOUTME: Packs a release mirroir-mcp binary into an MCP Bundle (.mcpb) for one-click install in MCPB hosts.
# ABOUTME: `--check` validates mcpb/manifest.json and its version against server.json without packing.
#
# Usage:
#   mcpb/build-mcpb.sh <path-to-mirroir-mcp-binary> <output.mcpb>
#   mcpb/build-mcpb.sh --check
#
# The bundle is a `binary` MCPB: the native server sits at server/mirroir-mcp
# inside the archive, so the host starts it with no Node runtime and no network
# fetch. The binary is the same one release.yml tars for npm and Homebrew.

set -euo pipefail

# Pinned so a CLI release cannot change what the bundle validates against.
MCPB_CLI_VERSION="2.1.2"
# The release binary is Apple Silicon only (embacle-ffi ships arm64 alone);
# MCPB cannot declare a CPU architecture, so the packer enforces it.
REQUIRED_ARCH="arm64"
BUNDLE_BINARY_PATH="server/mirroir-mcp"

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

check_manifest() {
    local manifest_version server_version
    manifest_version="$(json_field "$manifest" version)"
    server_version="$(json_field "$server_json" version)"
    if [ "$manifest_version" != "$server_version" ]; then
        echo "ERROR: mcpb/manifest.json version $manifest_version != server.json version $server_version" >&2
        exit 1
    fi
    mcpb_cli validate "$manifest"
}

if [ "${1:-}" = "--check" ]; then
    check_manifest
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
mkdir -p "$stage/$(dirname "$BUNDLE_BINARY_PATH")"
cp "$binary" "$stage/$BUNDLE_BINARY_PATH"
chmod 755 "$stage/$BUNDLE_BINARY_PATH"
cp "$repo_root/LICENSE" "$stage/LICENSE"

mcpb_cli pack "$stage" "$output"
mcpb_cli info "$output"
