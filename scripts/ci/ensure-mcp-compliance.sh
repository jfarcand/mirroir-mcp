#!/bin/bash
# ABOUTME: MCP protocol compliance validation script for mirroir-mcp.
# ABOUTME: Tests the MCP server against the Model Context Protocol specification.
#
# Usage: ./scripts/ci/ensure-mcp-compliance.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

echo -e "${BLUE}==== mirroir-mcp MCP Compliance Validation ====${NC}"
echo "Project root: $PROJECT_ROOT"

# Track success
COMPLIANCE_PASSED=true
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Locate the release binary — build only if not already present (CI builds it in a prior step)
BINARY="$PROJECT_ROOT/.build/release/mirroir-mcp"
if [ -x "$BINARY" ]; then
    echo -e "${GREEN}[OK] Using existing release binary${NC}"
else
    echo ""
    echo -e "${BLUE}==== Building release binary... ====${NC}"
    cd "$PROJECT_ROOT"
    if swift build -c release 2>&1; then
        echo -e "${GREEN}[OK] Release binary built${NC}"
    else
        echo -e "${RED}[FAIL] swift build -c release failed${NC}"
        exit 1
    fi
    if [ ! -x "$BINARY" ]; then
        echo -e "${RED}[FAIL] Binary not found at $BINARY${NC}"
        exit 1
    fi
fi

# Helper: send JSON-RPC messages to the MCP server and capture output
mcp_send() {
    local input="$1"
    local flags="${2:-}"
    echo "$input" | $BINARY $flags 2>/dev/null
}

# Helper: record test result
record_test() {
    local name="$1"
    local passed="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [ "$passed" = true ]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo -e "${GREEN}  [PASS] $name${NC}"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo -e "${RED}  [FAIL] $name${NC}"
        COMPLIANCE_PASSED=false
    fi
}

# ============================================================
# Test 1: JSON-RPC 2.0 Initialize
# ============================================================
echo ""
echo -e "${BLUE}==== Test: JSON-RPC 2.0 Initialize ====${NC}"

INIT_RESPONSE=$(mcp_send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')
if echo "$INIT_RESPONSE" | python3 -c "
import sys, json
obj = json.loads(sys.stdin.readline())
assert obj.get('jsonrpc') == '2.0', f'Missing jsonrpc 2.0, got: {obj.get(\"jsonrpc\")}'
assert 'result' in obj, f'Missing result in: {obj}'
assert obj['result']['serverInfo']['name'] == 'mirroir-mcp', f'Wrong server name'
assert obj['result']['protocolVersion'] == '2025-11-25', f'Wrong protocol version: {obj[\"result\"][\"protocolVersion\"]}'
print('OK')
" 2>&1 | grep -q "OK"; then
    record_test "Initialize returns valid JSON-RPC 2.0 with protocolVersion 2025-11-25" true
else
    record_test "Initialize returns valid JSON-RPC 2.0 with protocolVersion 2025-11-25" false
fi

# ============================================================
# Test 2: Server capabilities
# ============================================================
echo ""
echo -e "${BLUE}==== Test: Server Capabilities ====${NC}"

if echo "$INIT_RESPONSE" | python3 -c "
import sys, json
obj = json.loads(sys.stdin.readline())
result = obj['result']
assert 'capabilities' in result, 'Missing capabilities'
assert 'tools' in result['capabilities'], 'Missing tools capability'
assert 'serverInfo' in result, 'Missing serverInfo'
assert 'name' in result['serverInfo'], 'Missing server name'
assert 'version' in result['serverInfo'], 'Missing server version'
print('OK')
" 2>&1 | grep -q "OK"; then
    record_test "Initialize includes capabilities and serverInfo" true
else
    record_test "Initialize includes capabilities and serverInfo" false
fi

# ============================================================
# Test 3: tools/list returns valid tool definitions
# ============================================================
echo ""
echo -e "${BLUE}==== Test: tools/list ====${NC}"

TOOLS_RESPONSE=$(printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}\n' \
    | $BINARY --dangerously-skip-permissions 2>/dev/null | tail -1)

if echo "$TOOLS_RESPONSE" | python3 -c "
import sys, json
obj = json.loads(sys.stdin.readline())
assert 'result' in obj, f'Missing result: {obj}'
assert 'tools' in obj['result'], f'Missing tools: {obj[\"result\"]}'
tools = obj['result']['tools']
assert len(tools) > 0, 'tools/list returned 0 tools'
names = {t['name'] for t in tools}
# Verify core tools are present (not an exhaustive list — avoids breaking when tools are added)
core = {'screenshot', 'tap', 'swipe', 'type_text', 'press_key', 'describe_screen', 'status'}
missing = core - names
assert not missing, f'Missing core tools: {missing}'
print(f'OK ({len(tools)} tools)')
" 2>&1 | grep -q "OK"; then
    record_test "tools/list returns tools including core set" true
else
    record_test "tools/list returns tools including core set" false
fi

# ============================================================
# Test 4: Tool schemas have required fields per MCP spec
# ============================================================
echo ""
echo -e "${BLUE}==== Test: Tool Schema Validation ====${NC}"

if echo "$TOOLS_RESPONSE" | python3 -c "
import sys, json
obj = json.loads(sys.stdin.readline())
tools = {t['name']: t for t in obj['result']['tools']}

for name, tool in tools.items():
    assert 'name' in tool, f'Tool missing name field'
    assert 'description' in tool, f'{name}: missing description'
    assert 'inputSchema' in tool, f'{name}: missing inputSchema'
    schema = tool['inputSchema']
    assert isinstance(schema, dict), f'{name}: inputSchema must be object'

# Validate specific tool schemas
tap = tools['tap']['inputSchema']
assert 'x' in tap.get('properties', {}), 'tap missing x property'
assert 'y' in tap.get('properties', {}), 'tap missing y property'
assert set(tap.get('required', [])) == {'x', 'y'}, 'tap should require x and y'

swipe = tools['swipe']['inputSchema']
for coord in ['from_x', 'from_y', 'to_x', 'to_y']:
    assert coord in swipe.get('properties', {}), f'swipe missing {coord}'

type_text = tools['type_text']['inputSchema']
assert 'text' in type_text.get('properties', {}), 'type_text missing text'

print('OK')
" 2>&1 | grep -q "OK"; then
    record_test "Tool schemas have correct properties and required fields" true
else
    record_test "Tool schemas have correct properties and required fields" false
fi

# ============================================================
# Test 5: Fail-closed default (readonly tools only without permission flag)
# ============================================================
echo ""
echo -e "${BLUE}==== Test: Fail-Closed Default ====${NC}"

DEFAULT_TOOLS=$(printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}\n' \
    | $BINARY 2>/dev/null | tail -1)

if echo "$DEFAULT_TOOLS" | python3 -c "
import sys, json
obj = json.loads(sys.stdin.readline())
tools = [t['name'] for t in obj['result']['tools']]
expected_readonly = {'screenshot','start_recording','stop_recording','get_orientation','status','check_health','describe_screen','list_skills','get_skill','list_targets'}
assert set(tools) == expected_readonly, f'Default should show only readonly tools.\nExpected: {expected_readonly}\nGot: {set(tools)}\nExtra: {set(tools) - expected_readonly}\nMissing: {expected_readonly - set(tools)}'
print('OK')
" 2>&1 | grep -q "OK"; then
    record_test "Default mode exposes only readonly tools (fail-closed)" true
else
    record_test "Default mode exposes only readonly tools (fail-closed)" false
fi

# ============================================================
# Test 6: Unknown method returns JSON-RPC error
# ============================================================
echo ""
echo -e "${BLUE}==== Test: Unknown Method Error ====${NC}"

ERROR_RESPONSE=$(printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n{"jsonrpc":"2.0","id":2,"method":"nonexistent/method","params":{}}\n' \
    | $BINARY 2>/dev/null | tail -1)

if echo "$ERROR_RESPONSE" | python3 -c "
import sys, json
obj = json.loads(sys.stdin.readline())
assert 'error' in obj, f'Expected error response, got: {obj}'
assert obj['error']['code'] == -32601, f'Expected -32601 (Method not found), got: {obj[\"error\"][\"code\"]}'
assert 'message' in obj['error'], 'Error missing message'
print('OK')
" 2>&1 | grep -q "OK"; then
    record_test "Unknown method returns -32601 (Method not found)" true
else
    record_test "Unknown method returns -32601 (Method not found)" false
fi

# ============================================================
# Test 7: Invalid JSON returns parse error (-32700)
# ============================================================
echo ""
echo -e "${BLUE}==== Test: Invalid JSON Handling ====${NC}"

PARSE_RESPONSE=$(printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\nthis is not json\n' \
    | $BINARY 2>/dev/null | tail -1)

if echo "$PARSE_RESPONSE" | python3 -c "
import sys, json
obj = json.loads(sys.stdin.readline())
assert 'error' in obj, f'Expected error for bad JSON, got: {obj}'
assert obj['error']['code'] == -32700, f'Expected -32700 (Parse error), got: {obj[\"error\"][\"code\"]}'
print('OK')
" 2>&1 | grep -q "OK"; then
    record_test "Invalid JSON returns -32700 (Parse error)" true
else
    record_test "Invalid JSON returns -32700 (Parse error)" false
fi

# ============================================================
# Test 8: Ping responds with empty result
# ============================================================
echo ""
echo -e "${BLUE}==== Test: Ping Support ====${NC}"

PING_RESPONSE=$(printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n{"jsonrpc":"2.0","id":2,"method":"ping","params":{}}\n' \
    | $BINARY 2>/dev/null | tail -1)

if echo "$PING_RESPONSE" | python3 -c "
import sys, json
obj = json.loads(sys.stdin.readline())
assert 'result' in obj, f'Ping should return result, got: {obj}'
assert obj['id'] == 2, f'Wrong id in ping response'
print('OK')
" 2>&1 | grep -q "OK"; then
    record_test "Ping returns valid response" true
else
    record_test "Ping returns valid response" false
fi

# ============================================================
# Test 9: JSON-RPC response IDs match request IDs
# ============================================================
echo ""
echo -e "${BLUE}==== Test: Request/Response ID Matching ====${NC}"

ID_RESPONSE=$(printf '{"jsonrpc":"2.0","id":42,"method":"initialize","params":{}}\n{"jsonrpc":"2.0","id":99,"method":"tools/list","params":{}}\n' \
    | $BINARY 2>/dev/null)

if echo "$ID_RESPONSE" | python3 -c "
import sys, json
lines = sys.stdin.readlines()
init_resp = json.loads(lines[0])
tools_resp = json.loads(lines[1])
assert init_resp['id'] == 42, f'Init response id should be 42, got: {init_resp[\"id\"]}'
assert tools_resp['id'] == 99, f'Tools response id should be 99, got: {tools_resp[\"id\"]}'
print('OK')
" 2>&1 | grep -q "OK"; then
    record_test "Response IDs match request IDs" true
else
    record_test "Response IDs match request IDs" false
fi

# ============================================================
# Test 10: All responses include jsonrpc: "2.0"
# ============================================================
echo ""
echo -e "${BLUE}==== Test: JSON-RPC 2.0 Version Field ====${NC}"

MULTI_RESPONSE=$(printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}\n{"jsonrpc":"2.0","id":3,"method":"ping","params":{}}\n{"jsonrpc":"2.0","id":4,"method":"nonexistent","params":{}}\n' \
    | $BINARY 2>/dev/null)

if echo "$MULTI_RESPONSE" | python3 -c "
import sys, json
lines = sys.stdin.readlines()
for i, line in enumerate(lines):
    obj = json.loads(line.strip())
    assert obj.get('jsonrpc') == '2.0', f'Response {i} missing jsonrpc 2.0: {obj}'
print('OK')
" 2>&1 | grep -q "OK"; then
    record_test "All responses include jsonrpc: 2.0" true
else
    record_test "All responses include jsonrpc: 2.0" false
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  MCP Compliance Summary${NC}"
echo -e "${BLUE}============================================${NC}"
echo -e "  Total:  $TOTAL_TESTS"
echo -e "  Passed: ${GREEN}$PASSED_TESTS${NC}"
echo -e "  Failed: ${RED}$FAILED_TESTS${NC}"

PASS_RATE=$((PASSED_TESTS * 100 / TOTAL_TESTS))
echo -e "  Rate:   ${PASS_RATE}%"
echo -e "${BLUE}============================================${NC}"

echo ""
if [ "$COMPLIANCE_PASSED" = true ]; then
    echo -e "${GREEN}MCP Compliance Validation PASSED${NC}"
    exit 0
else
    echo -e "${RED}MCP Compliance Validation FAILED${NC}"
    exit 1
fi
