#!/usr/bin/env bash
#
# codeindex demo — showcases all MCP tools against a live codebase.
#
# Usage:
#   ./demo.sh                    # Demo against codeindex itself
#   ./demo.sh /path/to/project   # Demo against any project
#
# Requires: zig/zig-out/bin/codeindex (build first: cd zig && ./fetch-vendor.sh && zig build)

set -euo pipefail

BINARY="${CODEINDEX_BINARY:-./zig/zig-out/bin/codeindex}"
WORKSPACE="${1:-.}"

if [ ! -f "$BINARY" ]; then
    echo "Error: binary not found at $BINARY"
    echo "Build first: cd zig && ./fetch-vendor.sh && zig build"
    exit 1
fi

WORKSPACE="$(cd "$WORKSPACE" && pwd)"

echo "══════════════════════════════════════════════════════════════════════════════"
echo "  codeindex demo — indexing: $WORKSPACE"
echo "══════════════════════════════════════════════════════════════════════════════"
echo ""

# Build JSON-RPC request sequence
REQS=''

add_req() {
    local method="$1"
    local params="$2"
    local id="$3"
    REQS+="{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"$method\""
    if [ -n "$params" ]; then
        REQS+=",\"params\":$params"
    fi
    REQS+="}\n"
}

# Initialize
add_req "initialize" '{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"demo","version":"0.1"}}' 1
add_req "notifications/initialized" "" 0

echo "─── status ────────────────────────────────────────────────────────────────"
echo ""
printf "$REQS" | CODEINDEX_WORKSPACE="$WORKSPACE" timeout 30 "$BINARY" --mcp 2>/dev/null | \
    python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        msg = json.loads(line)
    except: continue
    if msg.get('id') == 1:
        result = msg.get('result', {})
        info = result.get('serverInfo', {})
        print(f'Server: {info.get(\"name\",\"?\")} v{info.get(\"version\",\"?\")}')
        print(f'Protocol: {result.get(\"protocolVersion\",\"?\")}')
" || true

# Wait for indexing to complete, then run queries
sleep 2

echo ""
echo "─── tools/list ────────────────────────────────────────────────────────────"
echo ""

REQS=''
add_req "initialize" '{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"demo","version":"0.1"}}' 1
add_req "notifications/initialized" "" 0
add_req "tools/list" '{}' 2

printf "$REQS" | CODEINDEX_WORKSPACE="$WORKSPACE" timeout 30 "$BINARY" --mcp 2>/dev/null | \
    python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        msg = json.loads(line)
    except: continue
    if msg.get('id') == 2:
        tools = msg.get('result', {}).get('tools', [])
        print(f'{len(tools)} tools available:')
        for t in tools:
            desc = t.get('description', '')[:70]
            print(f'  • {t[\"name\"]:20s} {desc}')
" || true

echo ""
echo "─── status (index stats) ──────────────────────────────────────────────────"
echo ""

REQS=''
add_req "initialize" '{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"demo","version":"0.1"}}' 1
add_req "notifications/initialized" "" 0
add_req "tools/call" '{"name":"status","arguments":{}}' 2

printf "$REQS" | CODEINDEX_WORKSPACE="$WORKSPACE" timeout 30 "$BINARY" --mcp 2>/dev/null | \
    python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        msg = json.loads(line)
    except: continue
    if msg.get('id') == 2:
        content = msg.get('result', {}).get('content', [])
        for c in content:
            if c.get('type') == 'text':
                data = json.loads(c['text'])
                print(f'  Files:     {data.get(\"files\", 0)}')
                print(f'  Symbols:   {data.get(\"symbols\", 0)}')
                print(f'  Lines:     {data.get(\"total_lines\", 0)}')
                print(f'  Bytes:     {data.get(\"total_bytes\", 0)}')
                print(f'  Naive tokens (full files): {data.get(\"naive_tokens\", 0):,}')
                print(f'  Outline tokens:            {data.get(\"outline_tokens\", 0):,}')
                print(f'  Token savings:             {data.get(\"savings_pct\", 0)}%')
                print(f'  Indexing:  {data.get(\"indexing\", False)}')
                print(f'  Watcher:   {data.get(\"watcher\", False)}')
" || true

echo ""
echo "─── find_symbol: Explorer ─────────────────────────────────────────────────"
echo ""

REQS=''
add_req "initialize" '{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"demo","version":"0.1"}}' 1
add_req "notifications/initialized" "" 0
add_req "tools/call" '{"name":"find_symbol","arguments":{"name":"Explorer","limit":5}}' 2

printf "$REQS" | CODEINDEX_WORKSPACE="$WORKSPACE" timeout 30 "$BINARY" --mcp 2>/dev/null | \
    python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        msg = json.loads(line)
    except: continue
    if msg.get('id') == 2:
        content = msg.get('result', {}).get('content', [])
        for c in content:
            if c.get('type') == 'text':
                print(c['text'][:500])
" || true

echo ""
echo "─── search: trigram ───────────────────────────────────────────────────────"
echo ""

REQS=''
add_req "initialize" '{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"demo","version":"0.1"}}' 1
add_req "notifications/initialized" "" 0
add_req "tools/call" '{"name":"search","arguments":{"query":"trigram","limit":5}}' 2

printf "$REQS" | CODEINDEX_WORKSPACE="$WORKSPACE" timeout 30 "$BINARY" --mcp 2>/dev/null | \
    python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        msg = json.loads(line)
    except: continue
    if msg.get('id') == 2:
        content = msg.get('result', {}).get('content', [])
        for c in content:
            if c.get('type') == 'text':
                print(c['text'][:500])
" || true

echo ""
echo "─── analyze: cycles ───────────────────────────────────────────────────────"
echo ""

REQS=''
add_req "initialize" '{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"demo","version":"0.1"}}' 1
add_req "notifications/initialized" "" 0
add_req "tools/call" '{"name":"analyze","arguments":{"analysis":"cycles"}}' 2

printf "$REQS" | CODEINDEX_WORKSPACE="$WORKSPACE" timeout 30 "$BINARY" --mcp 2>/dev/null | \
    python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        msg = json.loads(line)
    except: continue
    if msg.get('id') == 2:
        content = msg.get('result', {}).get('content', [])
        for c in content:
            if c.get('type') == 'text':
                print(c['text'][:800])
" || true

echo ""
echo "══════════════════════════════════════════════════════════════════════════════"
echo "  Demo complete. Register codeindex with your AI agent to use it live."
echo "  claude mcp add codeindex -- $BINARY --mcp"
echo "══════════════════════════════════════════════════════════════════════════════"