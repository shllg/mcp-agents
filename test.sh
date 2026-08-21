#!/usr/bin/env bash
# Smoke tests for mcp-agents stdio transport.
# Verifies provider servers handle JSON-RPC over stdio and exit cleanly
# after stdin EOF. Timeouts are guardrails, not the expected shutdown path.
set -euo pipefail

cd "$(dirname "$0")"

TEST_REPO_ROOT=$(pwd)
TEST_CODEX_HOME_ROOT="$TEST_REPO_ROOT/tmp/codex-homes"
SERVER="node server.js"
# Resolve once to an ABSOLUTE path: tests that restrict PATH to simulate a
# published install must not lose the harness's own timeout binary.
TIMEOUT_CMD="$(command -v timeout || command -v gtimeout || true)"
if [ -z "$TIMEOUT_CMD" ]; then
  echo "Error: 'timeout' (coreutils) is required. Install via: brew install coreutils"
  exit 1
fi
PASS=0
FAIL=0
TEST_CHILD_REGISTRY=$(mktemp)
export MCP_AGENTS_TEST_CHILD_REGISTRY="$TEST_CHILD_REGISTRY"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

terminate_test_child() {
  local pid="${1:-}"
  [ -n "$pid" ] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
}

cleanup_registered_test_children() {
  [ -f "$TEST_CHILD_REGISTRY" ] || return 0
  while IFS= read -r pid; do terminate_test_child "$pid"; done < "$TEST_CHILD_REGISTRY"
}

on_test_exit() {
  local status=$?
  trap - EXIT
  cleanup_registered_test_children
  rmdir "$TEST_CODEX_HOME_ROOT" "$TEST_REPO_ROOT/tmp" 2>/dev/null || true
  rm -f "$TEST_CHILD_REGISTRY"
  exit "$status"
}
trap on_test_exit EXIT

# ── Helper: run tools/list with a given --provider and check for expected tool ──
test_tools_list() {
  local label="$1"
  local provider="$2"
  local expected_tool="$3"
  local expected_timeout="${4:-}"
  local timeout_override="${5:-}"
  local server_command=(node server.js --provider "$provider")
  local output_file
  local status

  if [ -n "$timeout_override" ]; then
    server_command+=(--timeout "$timeout_override")
  fi

  echo "--- $label ---"

  output_file=$(mktemp)
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
    sleep 1
  } | $TIMEOUT_CMD 10 "${server_command[@]}" >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  rm -f "$output_file"

  if [ "$status" -ne 0 ]; then
    red "FAIL: $label (exit $status)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  elif echo "$RESPONSE" | jq -e \
    --arg tool "$expected_tool" \
    --arg timeout "$expected_timeout" \
    '.result.tools[] | select(.name == $tool) |
      if $timeout == "" then true
      else (.inputSchema.properties.timeout_ms.description | contains($timeout))
      end' >/dev/null 2>&1; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  fi
}

# ── Helper: assert the Claude provider's wrapper-owned tool schemas ──
test_claude_tools_schema() {
  local label="$1"
  local predicate="$2"
  local output_file
  local status

  echo "--- $label ---"

  output_file=$(mktemp)
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
    sleep 2
  } | $TIMEOUT_CMD 5 $SERVER --provider claude >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  rm -f "$output_file"

  if [ "$status" -eq 0 ] &&
    printf '%s\n' "$RESPONSE" | jq -e "$predicate" >/dev/null 2>&1; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (exit $status)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  fi
}

# ── Helper: full handshake then tools/list ──
test_handshake() {
  local label="$1"
  local provider="$2"
  local expected_tool="$3"
  local output_file
  local status

  echo "--- $label ---"

  output_file=$(mktemp)
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.0.1"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    sleep 1
  } | $TIMEOUT_CMD 10 $SERVER --provider "$provider" >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  rm -f "$output_file"

  if [ "$status" -ne 0 ]; then
    red "FAIL: $label (exit $status)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  elif echo "$RESPONSE" | grep -q "\"$expected_tool\""; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  fi
}

# ── Helper: full handshake → tools/call with a connectivity check ──
test_connectivity() {
  local label="$1"
  local provider="$2"
  local tool_name="$3"
  local call_timeout="${4:-120}"
  local output_file
  local status

  echo "--- $label ---"

  output_file=$(mktemp)
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.0.1"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool_name\",\"arguments\":{\"prompt\":\"This is a connectivity test. Reply with exactly: OK\"}}}"
    sleep "$call_timeout"
  } | $TIMEOUT_CMD "$((call_timeout + 10))" $SERVER --provider "$provider" >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  rm -f "$output_file"

  # Success = the tools/call (id:2) returned a non-error result whose text
  # actually starts with "OK" (the requested reply) and is short. A non-empty
  # string is not enough: an "Authentication required…" message (e.g. from an
  # unauthenticated CLI) would otherwise pass the check.
  if [ "$status" -ne 0 ]; then
    red "FAIL: $label (exit $status)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  elif echo "$RESPONSE" | jq -e 'select(.id == 2) | (.result.isError != true) and (.result.content[0].text | type == "string" and (ascii_upcase | test("^\\s*OK")) and (length < 40))' >/dev/null 2>&1; then
    local text
    text=$(echo "$RESPONSE" | jq -r 'select(.id == 2) | .result.content[0].text // empty' 2>/dev/null | head -c 120)
    green "PASS: $label → $text"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label"
    # A well-formed MCP result whose text isn't a short "OK" usually means the
    # provider CLI's JSON output shape changed and the wrapper fell back to the
    # raw blob — flag it so drift is obvious, not mysterious.
    if echo "$RESPONSE" | jq -e 'select(.id == 2) | .result.content[0].text | type == "string"' >/dev/null 2>&1; then
      echo "  ⚠ could not extract a clean answer (possible JSON shape drift or model noncompliance)"
    fi
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  fi
}

# ── Helper: test a CLI flag that should succeed (exit 0, stdout matches) ──
test_cli_flag() {
  local label="$1"
  local flag="$2"
  local expected="$3"

  echo "--- $label ---"

  set +e
  OUTPUT=$($SERVER $flag 2>/dev/null)
  EXIT_CODE=$?
  set -e

  if [ "$EXIT_CODE" -eq 0 ] && printf '%s' "$OUTPUT" | grep -Fq -- "$expected"; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (exit=$EXIT_CODE, expected '$expected' in output)"
    echo "  Output: $OUTPUT"
    FAIL=$((FAIL + 1))
  fi
}

# ── Helper: test a CLI flag that should fail (exit non-zero, stderr matches) ──
test_cli_error() {
  local label="$1"
  local flag="$2"
  local expected="$3"

  echo "--- $label ---"

  STDERR_OUTPUT=$($SERVER $flag 2>&1 >/dev/null) || true

  if echo "$STDERR_OUTPUT" | grep -q "$expected"; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (expected '$expected' in stderr)"
    echo "  Stderr: $STDERR_OUTPUT"
    FAIL=$((FAIL + 1))
  fi
}

# ── Helper: test an invalid workspace-network environment value ──
test_codex_workspace_network_env_error() {
  local label="$1"
  local value="$2"
  local expected="$3"

  echo "--- $label ---"

  STDERR_OUTPUT=$(env MCP_AGENTS_CODEX_WORKSPACE_NETWORK_ACCESS="$value" \
    $SERVER --provider codex 2>&1 >/dev/null) || true

  if echo "$STDERR_OUTPUT" | grep -q "$expected"; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (expected '$expected' in stderr)"
    echo "  Stderr: $STDERR_OUTPUT"
    FAIL=$((FAIL + 1))
  fi
}

# ========== CLI flag tests ==========

test_cli_flag "--help prints usage"         "--help"    "Usage:"
test_cli_flag "--help shows GPT-5.6 SOL default" "--help" "gpt-5.6-sol"
test_cli_flag "--help shows xhigh default"  "--help"    "xhigh"
test_cli_flag "--help shows workspace-write default" "--help" "workspace-write"
test_cli_flag "--help shows never default"  "--help"    "never"
test_cli_flag "--help shows workspace network default" "--help" "--codex-workspace-network"
test_cli_flag "--help shows codex_idle_timeout" "--help" "codex_idle_timeout"
test_cli_flag "--help shows codex_status_interval default" "--help" "codex_status_interval"
test_cli_flag "--help shows goal flag"      "--help"    "Persistent objective"
test_cli_flag "--help shows browser provider" "--help" "browser_lease_command"
test_cli_flag "--help shows browser downstream fallback" "--help" "npx chrome-devtools-mcp@latest"
test_cli_flag "--help shows provider timeout defaults" "--help" "claude 900, browser 600, gemini 300"
test_cli_flag "-h prints usage"             "-h"        "Usage:"
test_cli_flag "--version prints version"    "--version"  "mcp-agents v"
test_cli_flag "-v prints version"           "-v"        "mcp-agents v"
test_cli_error "--bogus exits with error"   "--bogus"   "unknown option"
test_cli_error "--provider without value"                  "--provider"                 "requires a value"
test_cli_error "--model without value"                     "--model"                    "requires a value"
test_cli_error "--model_reasoning_effort without value"    "--model_reasoning_effort"   "requires a value"
test_cli_error "--sandbox_mode without value"              "--sandbox_mode"             "requires a value"
test_cli_error "--approval_policy without value"           "--approval_policy"          "requires a value"
test_cli_error "--codex-workspace-network without value"    "--codex-workspace-network"   "requires a value"
test_cli_error "--codex-workspace-network invalid value"    "--codex-workspace-network maybe" "must be true or false"
test_cli_error "--codex-workspace-network invalid inline"   "--codex-workspace-network=maybe" "must be true or false"
test_codex_workspace_network_env_error \
  "workspace network env rejects invalid value" "maybe" "must be true or false"
test_cli_error "--goal without value"                      "--goal"                     "requires a value"
test_cli_error "--timeout without value"                    "--timeout"                  "requires a value"
test_cli_error "--timeout with zero"                        "--timeout 0"                "must be a positive number"
test_cli_error "--timeout with negative"                    "--timeout -5"               "must be a positive number"
test_cli_error "--timeout with non-number"                  "--timeout abc"              "must be a positive number"
test_cli_error "--codex_idle_timeout without value"         "--codex_idle_timeout"       "requires a value"
test_cli_error "--codex_idle_timeout non-number"            "--codex_idle_timeout abc"   "non-negative number"
test_cli_error "--codex_idle_timeout negative"              "--codex_idle_timeout -1"    "non-negative number"
test_cli_error "--codex_status_interval without value"      "--codex_status_interval"     "requires a value"
test_cli_error "--codex_status_interval non-number"         "--codex_status_interval abc" "non-negative number"
test_cli_error "--codex_status_interval negative"           "--codex_status_interval -1"  "non-negative number"
test_cli_error "--browser_lease_command without value"       "--provider browser --browser_lease_command" "requires a value"
test_cli_error "--browser_command without value"             "--provider browser --browser_command" "requires a value"
test_cli_error "--browser_idle_timeout rejects negative"      "--provider browser --browser_idle_timeout -1" "non-negative number"
test_cli_error "--browser_viewport rejects malformed value"   "--provider browser --browser_viewport wide" "positive WxH"
test_cli_error "--browser_app_port rejects invalid port"      "--provider browser --browser_app_port 70000" "integer from 1 to 65535"
test_cli_error "browser flags reject the Claude provider"     "--provider claude --browser_idle_timeout 1" "only valid with --provider browser"
test_cli_error "browser flags reject the Gemini provider"     "--provider gemini --browser_viewport 800x600" "only valid with --provider browser"
test_cli_error "browser flags reject the Codex provider"      "--provider codex --browser_command fake" "only valid with --provider browser"
test_cli_error "browser provider requires an injected lease helper" "--provider browser" "browser_lease_command"

# ========== Protocol tests (fast) ==========

# ---------- Ping (all providers) ----------
for p in claude gemini; do
  test_tools_list "tools/list --provider $p → ping" "$p" "ping"
done

# ---------- Claude provider ----------
test_tools_list "tools/list --provider claude → claude_code (900s default)" \
  "claude" "claude_code" "900000"
test_tools_list "tools/list --provider claude honors --timeout override" \
  "claude" "claude_code" "7000" "7"
test_handshake  "handshake --provider claude → claude_code"  "claude" "claude_code"
test_claude_tools_schema "Claude tools/list advertises the complete one-shot job API" \
  '(.result.tools | map(.name) | sort) ==
    ["claude-cancel","claude-result","claude-start","claude-status","claude_code","ping"]'
test_claude_tools_schema "Claude job tools expose closed operational schemas" \
  '(.result.tools | map({key:.name,value:.}) | from_entries) as $t |
   (($t["claude-start"].inputSchema |
      (.additionalProperties == false) and
      (.required == ["prompt","cwd"]) and
      ((.properties | keys | sort) == ["cwd","prompt"]) and
      (.properties.cwd.type == "string")) and
    ($t["claude-status"].inputSchema |
      (.additionalProperties == false) and
      (.required == ["jobId","cursor"]) and
      ((.properties | keys | sort) == ["cursor","jobId","wait_ms"]) and
      (.properties.cursor.minimum == 0) and
      (.properties.wait_ms.maximum == 60000)) and
    ($t["claude-result"].inputSchema |
      (.additionalProperties == false) and
      (.required == ["jobId"]) and
      ((.properties | keys | sort) == ["jobId","offset"]) and
      (.properties.offset.minimum == 0)) and
    ($t["claude-cancel"].inputSchema |
      (.additionalProperties == false) and
      (.required == ["jobId"]) and
      ((.properties | keys) == ["jobId"])))'
test_claude_tools_schema "legacy claude_code keeps prompt and caller timeout compatibility" \
  '(.result.tools | map(select(.name == "claude_code"))[0].inputSchema) as $s |
   ($s.additionalProperties == true) and
   ($s.required == ["prompt"]) and
   (($s.properties | keys | sort) == ["prompt","timeout_ms"]) and
   ($s.properties.timeout_ms.minimum == 1)'

# ---------- Gemini provider ----------
test_tools_list "tools/list --provider gemini → gemini (300s default)" \
  "gemini" "gemini" "300000"
test_handshake  "handshake --provider gemini → gemini"  "gemini" "gemini"

# ========== Integration tests (call real CLIs) ==========

# ── Helper: test codex pass-through (tools/list comes from codex itself) ──
test_codex_passthrough() {
  local label="$1"
  local output_file
  local status
  echo "--- $label ---"

  output_file=$(mktemp)
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.0.1"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    sleep 3
  } | $TIMEOUT_CMD 10 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  rm -f "$output_file"

  if [ "$status" -ne 0 ]; then
    red "FAIL: $label (exit $status)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  elif echo "$RESPONSE" | jq -e '.result.tools' >/dev/null 2>&1; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  fi
}

# ── Helper: verify codex bridge starts with an isolated runtime ──
test_codex_isolated_runtime() {
  local label="$1"
  local output_file
  local status

  echo "--- $label ---"

  output_file=$(mktemp)
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.0.1"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"codex\",\"arguments\":{\"prompt\":\"Reply with ONLY OK\",\"cwd\":\"$(pwd)\",\"sandbox\":\"read-only\",\"model_reasoning_effort\":\"max\"}}}"
    sleep 8
  } | $TIMEOUT_CMD 45 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  rm -f "$output_file"

  if [ "$status" -ne 0 ]; then
    red "FAIL: $label (exit $status)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  elif ! echo "$RESPONSE" | grep -q '"reasoning_effort":"max"'; then
    red "FAIL: $label (missing per-session max effort)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  elif echo "$RESPONSE" | grep -q '"server":"codex_apps"'; then
    red "FAIL: $label (codex_apps started despite features.apps=false)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  elif echo "$RESPONSE" | grep -Eq '"server":"(claude-code|local-claude-test|local-gemini-test|chrome-devtools|context7|aws-knowledge-mcp-server|openaiDeveloperDocs|google-dev-knowledge|github-knowledge-mcp-server)"'; then
    red "FAIL: $label (inherited MCP server started)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  elif ! echo "$RESPONSE" | jq -e 'select(.id == 2) | .result.structuredContent.content == "OK"' >/dev/null 2>&1; then
    red "FAIL: $label (codex MCP result shape unexpected — output format may have changed)"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  else
    green "PASS: $label"
    PASS=$((PASS + 1))
  fi
}

# ── Helper: verify provider shutdown kills an in-flight detached child ──
test_provider_shutdown_kills_child() {
  local label="$1"
  local tmpdir pid_file output_file status child_pid

  echo "--- $label ---"

  tmpdir=$(mktemp -d)
  pid_file="$tmpdir/claude.pid"
  output_file="$tmpdir/output.txt"

  cat >"$tmpdir/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$MCP_AGENTS_TEST_CHILD_REGISTRY"
printf '%s' "$$" > "$MCP_AGENTS_TEST_PID_FILE"
sleep 30
printf '%s\n' '{"type":"result","result":"OK","is_error":false}'
EOF
  chmod +x "$tmpdir/claude"

  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.0.1"}}}'
    sleep 0.2
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.2
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"claude_code","arguments":{"prompt":"sleep"}}}'
    sleep 1
  } | PATH="$tmpdir:$PATH" MCP_AGENTS_TEST_PID_FILE="$pid_file" \
    $TIMEOUT_CMD 5 $SERVER --provider claude >"$output_file" 2>/dev/null
  status=$?
  set -e

  if [ "$status" -ne 0 ]; then
    red "FAIL: $label (exit $status)"
    cat "$output_file"
    FAIL=$((FAIL + 1))
    terminate_test_child "$(cat "$pid_file" 2>/dev/null || true)"
    rm -rf "$tmpdir"
    return
  fi

  for _ in $(seq 1 20); do
    if [ -s "$pid_file" ]; then
      break
    fi
    sleep 0.1
  done

  if [ ! -s "$pid_file" ]; then
    red "FAIL: $label (missing child pid)"
    cat "$output_file"
    FAIL=$((FAIL + 1))
    terminate_test_child "$(cat "$pid_file" 2>/dev/null || true)"
    rm -rf "$tmpdir"
    return
  fi

  child_pid=$(cat "$pid_file")
  sleep 0.5

  if kill -0 "$child_pid" 2>/dev/null; then
    red "FAIL: $label (child still running: $child_pid)"
    FAIL=$((FAIL + 1))
    terminate_test_child "$child_pid"
  else
    green "PASS: $label"
    PASS=$((PASS + 1))
  fi

  rm -rf "$tmpdir"
}

# ── Helper: fake Claude CLI for background-job contract tests. It captures ──
# argv/cwd/stdin per process and emits deterministic stream-json, including
# fragmented, malformed, and unknown frames that the bridge must safely ignore.
write_claude_job_stub() {
  cat >"$1/claude" <<'EOF'
#!/usr/bin/env node
const fs = require("fs");
const path = require("path");

const captureDir = process.env.MCP_STUB_CLAUDE_CAPTURE_DIR;
const base = path.join(captureDir, String(process.pid));
const argv = process.argv.slice(2);
const streaming = argv.includes("stream-json");
fs.appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${process.pid}\n`);
fs.writeFileSync(`${base}.json`, JSON.stringify({
  pid: process.pid,
  argv,
  cwd: process.cwd(),
  streaming,
}));

let input = "";
let prompt = "";
let started = false;
const timers = [];
const later = (delay, fn) => timers.push(setTimeout(fn, delay));
const appendSignal = (value) =>
  fs.appendFileSync(`${base}.signals`, `${value}\n`);
const emit = (value) =>
  process.stdout.write(`${JSON.stringify(value)}\n`);
const emitSplit = (value, onFlushed = () => {}) => {
  const line = `${JSON.stringify(value)}\n`;
  // Fragment only inside the ASCII JSON prefix. Splitting a JS string between
  // UTF-16 surrogate halves would make the stub itself corrupt astral text.
  const splitAt = Math.min(17, line.length - 1);
  process.stdout.write(line.slice(0, splitAt));
  later(8, () => process.stdout.write(line.slice(splitAt), onFlushed));
};
const promptText = (message) => {
  const content = message?.message?.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((part) => part?.type === "text" && typeof part.text === "string")
    .map((part) => part.text)
    .join("");
};
const finishReview = () => {
  if (started) return;
  started = true;
  if (prompt.startsWith("TIMEOUT") || prompt.startsWith("HANG")) {
    emit({ type: "system", subtype: "init", session_id: `stub-${process.pid}` });
    return;
  }

  later(5, () => emitSplit({
    type: "system",
    subtype: "init",
    session_id: `stub-${process.pid}`,
  }));
  later(20, () => process.stdout.write("this is not json\n"));
  later(25, () => emit({
    type: "future_event",
    prompt: "SENTINEL_PROMPT",
    reasoning: "SENTINEL_REASONING",
  }));
  later(35, () => emit({
    type: "assistant",
    message: {
      role: "assistant",
      content: [{ type: "text", text: "SENTINEL_DRAFT" }],
    },
  }));
  later(45, () => emit({
    type: "stream_event",
    event: {
      type: "content_block_delta",
      delta: { type: "text_delta", text: "SENTINEL_PARTIAL" },
    },
  }));
  later(55, () => emit({
    type: "tool_progress",
    tool_name: "SENTINEL_TOOL",
    command: "SENTINEL_COMMAND",
    path: "/SENTINEL_PATH",
    output: "SENTINEL_OUTPUT",
    prompt: "SENTINEL_PROGRESS_PROMPT",
  }));

  let result = "CLAUDE_REVIEW_OK";
  if (prompt.startsWith("PAGE")) result = "🚀".repeat(32_780);
  if (prompt.startsWith("OVERSIZE")) {
    result = "O".repeat((10 * 1024 * 1024) + 1_024);
  }
  if (prompt.startsWith("EMPTY_THEN_OK")) {
    const attemptFile = path.join(captureDir, "empty-attempt-count");
    let attempt = 0;
    try { attempt = Number(fs.readFileSync(attemptFile, "utf8")); } catch {}
    attempt += 1;
    fs.writeFileSync(attemptFile, String(attempt));
    result = attempt === 1 ? "" : "CLAUDE_RETRY_OK";
  }
  if (prompt.startsWith("PROVIDER_ERROR")) {
    later(80, () => emitSplit(
      {
        type: "result",
        subtype: "error",
        is_error: true,
        result: "SENTINEL_PROVIDER_ERROR",
      },
      () => later(10, () => process.exit(0)),
    ));
  } else {
    later(80, () => emitSplit(
      {
        type: "result",
        subtype: "success",
        is_error: false,
        result,
      },
      () => later(10, () => process.exit(0)),
    ));
  }
};

process.on("SIGTERM", () => {
  appendSignal("SIGTERM");
  if (!prompt.startsWith("TIMEOUT")) process.exit(0);
});
process.on("SIGINT", () => {
  appendSignal("SIGINT");
  if (!prompt.startsWith("TIMEOUT")) process.exit(0);
});

process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  fs.appendFileSync(`${base}.stdin`, chunk);
  input += chunk;
  let newline;
  while ((newline = input.indexOf("\n")) !== -1) {
    const line = input.slice(0, newline);
    input = input.slice(newline + 1);
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      continue;
    }
    if (message?.type === "user" && !started) {
      prompt = promptText(message);
      finishReview();
    }
    if (
      message?.type === "control_request" &&
      message?.request?.subtype === "interrupt"
    ) {
      appendSignal("CONTROL_INTERRUPT");
      if (!prompt.startsWith("TIMEOUT")) later(10, () => process.exit(0));
    }
  }
});
process.stdin.on("end", () => {
  if (streaming) return;
  prompt = input;
  emit({
    type: "result",
    subtype: "success",
    is_error: false,
    result: "LEGACY_CLAUDE_OK",
  });
  later(10, () => process.exit(0));
});
setInterval(() => {}, 1 << 30);
EOF
  chmod +x "$1/claude"
}

# Drives the Claude wrapper-owned background tools and emits one JSON summary.
write_claude_job_driver() {
  cat >"$1/claude-job-driver.mjs" <<'EOF'
import { spawn } from "node:child_process";
import {
  mkdirSync,
  readFileSync,
  readdirSync,
} from "node:fs";

const [stubDir, serverDir, scenario] = process.argv.slice(2);
const captureDir = `${stubDir}/captures`;
mkdirSync(captureDir, { recursive: true });
const terminalStates = new Set(["completed", "failed", "canceled"]);
const child = spawn("node", ["server.js", "--provider", "claude"], {
  cwd: serverDir,
  env: {
    ...process.env,
    PATH: `${stubDir}:${process.env.PATH}`,
    MCP_STUB_CLAUDE_CAPTURE_DIR: captureDir,
    MCP_AGENTS_TEST_CLAUDE_JOB_TIMEOUT_MS:
      scenario === "timeout" ? "400" : "4000",
    MCP_AGENTS_TEST_CLAUDE_JOB_RETENTION_MS:
      scenario === "retention" ? "80" : "3600000",
    MCP_AGENTS_TEST_CLAUDE_CANCEL_TERM_MS: "35",
    MCP_AGENTS_TEST_CLAUDE_CANCEL_KILL_MS: "35",
    MCP_AGENTS_TEST_CLAUDE_MAX_ACTIVE_JOBS:
      scenario === "capacity" ? "2" : "8",
    MCP_AGENTS_TEST_CLAUDE_MAX_RETAINED_JOBS:
      scenario === "retained" ? "2" : "32",
  },
  stdio: ["pipe", "pipe", "pipe"],
});

let stdout = "";
let stderr = "";
let parseBuffer = "";
let nextId = 2;
let driverError;
const frames = [];
const pending = new Map();
const data = {
  starts: [],
  statuses: [],
  results: [],
  cancels: [],
  invalid: [],
  pings: [],
};

child.stdin.on("error", () => {});
child.stdout.setEncoding("utf8");
child.stderr.setEncoding("utf8");
child.stderr.on("data", (chunk) => { stderr += chunk; });
const send = (message) => {
  if (child.stdin.writable) {
    child.stdin.write(`${JSON.stringify(message)}\n`);
  }
};
const request = (method, params, id = nextId++) => new Promise((resolve, reject) => {
  const timer = setTimeout(() => {
    pending.delete(JSON.stringify(id));
    reject(new Error(`request ${JSON.stringify(id)} timed out`));
  }, 3_500);
  pending.set(JSON.stringify(id), {
    resolve: (frame) => {
      clearTimeout(timer);
      resolve(frame);
    },
  });
  send({ jsonrpc: "2.0", id, method, params });
});
const callTool = (name, args, id, meta) => request(
  "tools/call",
  {
    name,
    arguments: args,
    ...(meta ? { _meta: meta } : {}),
  },
  id,
);
const structured = (frame) => frame?.result?.structuredContent;
const startJob = async (prompt) => {
  const frame = await callTool("claude-start", { prompt, cwd: serverDir });
  data.starts.push(frame);
  const jobId = structured(frame)?.jobId;
  if (typeof jobId !== "string" || !jobId) {
    throw new Error(`claude-start did not return a jobId: ${JSON.stringify(frame)}`);
  }
  return { jobId, cursor: structured(frame).cursor ?? 0 };
};
const status = async (jobId, cursor, waitMs = 100) => {
  const frame = await callTool(
    "claude-status",
    { jobId, cursor, wait_ms: waitMs },
  );
  data.statuses.push(frame);
  return frame;
};
const statusUntilTerminal = async (jobId, initialCursor = 0) => {
  let cursor = initialCursor;
  for (let attempt = 0; attempt < 40; attempt += 1) {
    const frame = await status(jobId, cursor, 120);
    const value = structured(frame);
    if (!value) throw new Error(`status missing structuredContent: ${JSON.stringify(frame)}`);
    if (terminalStates.has(value.state)) return frame;
    cursor = value.cursor;
  }
  throw new Error(`job ${jobId} did not become terminal`);
};
const result = async (jobId, offset = 0) => {
  const frame = await callTool("claude-result", { jobId, offset });
  data.results.push(frame);
  return frame;
};
const cancel = async (jobId) => {
  const frame = await callTool("claude-cancel", { jobId });
  data.cancels.push(frame);
  return frame;
};
const ping = async () => {
  const frame = await callTool("ping", {});
  data.pings.push(frame);
  return frame;
};
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const waitForCaptureCount = async (expected) => {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    const count = readdirSync(captureDir)
      .filter((name) => name.endsWith(".json"))
      .length;
    if (count >= expected) return;
    await delay(20);
  }
  throw new Error(`expected ${expected} Claude captures`);
};
const capturedPidForPrompt = (expectedPrompt) => {
  for (const name of readdirSync(captureDir).filter((item) => item.endsWith(".stdin"))) {
    const base = `${captureDir}/${name.slice(0, -6)}`;
    const raw = readFileSync(`${base}.stdin`, "utf8");
    const matched = raw
      .split("\n").filter(Boolean)
      .flatMap((line) => {
        try { return [JSON.parse(line)]; } catch { return []; }
      })
      .some((message) =>
        message?.type === "user" &&
        message?.message?.content === expectedPrompt
      );
    if (matched) return JSON.parse(readFileSync(`${base}.json`, "utf8")).pid;
  }
  return undefined;
};
const pidIsAlive = (pid) => {
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

child.stdout.on("data", (chunk) => {
  const text = chunk;
  stdout += text;
  parseBuffer += text;
  let newline;
  while ((newline = parseBuffer.indexOf("\n")) !== -1) {
    const line = parseBuffer.slice(0, newline);
    parseBuffer = parseBuffer.slice(newline + 1);
    if (!line) continue;
    let frame;
    try {
      frame = JSON.parse(line);
    } catch {
      continue;
    }
    frames.push(frame);
    const waiter = pending.get(JSON.stringify(frame.id));
    if (waiter) {
      pending.delete(JSON.stringify(frame.id));
      waiter.resolve(frame);
    }
  }
});

const closed = new Promise((resolve) => {
  child.once("close", (code, signal) => resolve({ code, signal }));
});
const hardStop = setTimeout(() => {
  try { child.kill("SIGKILL"); } catch {}
}, 7_000);

try {
  await request("initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "claude-job-test", version: "0" },
  }, 1);
  send({ jsonrpc: "2.0", method: "notifications/initialized" });

  if (scenario === "lifecycle") {
    const job = await startJob("NORMAL");
    const immediate = await status(job.jobId, 0, 0);
    const terminal = await statusUntilTerminal(
      job.jobId,
      structured(immediate)?.cursor ?? job.cursor,
    );
    data.futureCursor = await status(
      job.jobId,
      (structured(terminal)?.cursor ?? 0) + 1,
      0,
    );
    await result(job.jobId);
    await ping();
    data.lifecycleJobId = job.jobId;
    data.lifecycleTerminal = terminal;
  } else if (scenario === "legacy") {
    data.legacy = await callTool("claude_code", {
      prompt: "LEGACY",
      timeout_ms: 2_000,
      model: "ignored-for-compatibility",
    });
    await ping();
  } else if (scenario === "invalid") {
    data.invalid.push(await callTool("claude-start", {
      prompt: "NORMAL",
      cwd: "relative/path",
    }));
    data.invalid.push(await callTool("claude-start", {
      prompt: "NORMAL",
      cwd: serverDir,
      timeout_ms: 1,
    }));
    data.invalid.push(await callTool("claude-status", {
      jobId: "missing-cursor",
    }));
    data.invalid.push(await callTool("claude-status", {
      jobId: "invalid-wait",
      cursor: 0,
      wait_ms: 60_001,
    }));
    await ping();
  } else if (scenario === "cancel") {
    const hanging = await startJob("HANG");
    const sibling = await startJob("NORMAL SIBLING");
    let running = await status(hanging.jobId, 0, 120);
    if ((structured(running)?.cursor ?? 0) === 0) {
      running = await status(hanging.jobId, 0, 120);
    }
    const waitCursor = structured(running)?.cursor ?? 0;
    const waiterId = "cancel-only-the-waiter";
    data.waiterId = waiterId;
    callTool(
      "claude-status",
      { jobId: hanging.jobId, cursor: waitCursor, wait_ms: 1_000 },
      waiterId,
    ).then((frame) => { data.waiterFrame = frame; }).catch(() => {});
    await delay(30);
    send({
      jsonrpc: "2.0",
      method: "notifications/cancelled",
      params: { requestId: waiterId, reason: "test waiter cancellation" },
    });
    // The MCP SDK may either deliver the handler's prompt abort result or
    // suppress the canceled request's response. Snapshot whichever observable
    // outcome occurred before the explicit job cancellation below.
    await delay(100);
    data.waiterFrameBeforeJobCancel = data.waiterFrame;
    data.afterWaiterCancel = await status(hanging.jobId, waitCursor, 0);
    const firstCancel = await cancel(hanging.jobId);
    data.hangingTerminal = await statusUntilTerminal(
      hanging.jobId,
      structured(firstCancel)?.cursor ?? waitCursor,
    );
    data.hangingPid = capturedPidForPrompt("HANG");
    data.hangingAliveAfterTerminal = pidIsAlive(data.hangingPid);
    data.secondCancel = await cancel(hanging.jobId);
    data.siblingTerminal = await statusUntilTerminal(
      sibling.jobId,
      sibling.cursor,
    );
    await result(sibling.jobId);
    await ping();
    data.hangingJobId = hanging.jobId;
    data.siblingJobId = sibling.jobId;
  } else if (scenario === "timeout") {
    const timedOut = await startJob("TIMEOUT");
    data.timeoutTerminal = await statusUntilTerminal(
      timedOut.jobId,
      timedOut.cursor,
    );
    data.timeoutPid = capturedPidForPrompt("TIMEOUT");
    data.timeoutAliveAfterTerminal = pidIsAlive(data.timeoutPid);
    const followup = await startJob("NORMAL AFTER TIMEOUT");
    data.followupTerminal = await statusUntilTerminal(
      followup.jobId,
      followup.cursor,
    );
    await result(followup.jobId);
    await ping();
  } else if (scenario === "retry") {
    const job = await startJob("EMPTY_THEN_OK");
    data.retryTerminal = await statusUntilTerminal(job.jobId, job.cursor);
    data.retryResult = await result(job.jobId);
  } else if (scenario === "provider-error") {
    const job = await startJob("PROVIDER_ERROR");
    data.providerErrorTerminal = await statusUntilTerminal(
      job.jobId,
      job.cursor,
    );
    data.providerErrorResult = await result(job.jobId);
    await ping();
  } else if (scenario === "progress") {
    const job = await startJob("HANG PROGRESS");
    data.progressStatus = await callTool(
      "claude-status",
      { jobId: job.jobId, cursor: 0, wait_ms: 500 },
      undefined,
      { progressToken: "claude-progress-token" },
    );
    data.progressHeartbeat = await callTool(
      "claude-status",
      {
        jobId: job.jobId,
        cursor: structured(data.progressStatus)?.cursor ?? 0,
        wait_ms: 30,
      },
      undefined,
      { progressToken: "claude-progress-token" },
    );
    await cancel(job.jobId);
    data.progressTerminal = await statusUntilTerminal(
      job.jobId,
      structured(data.cancels.at(-1))?.cursor ?? 0,
    );
  } else if (scenario === "disconnect") {
    const job = await startJob("HANG DISCONNECT");
    data.disconnectStatus = await status(job.jobId, 0, 500);
  } else if (scenario === "paging") {
    const job = await startJob("PAGE");
    await statusUntilTerminal(job.jobId, job.cursor);
    const first = await result(job.jobId, 0);
    const second = await result(
      job.jobId,
      structured(first)?.nextOffset ?? 0,
    );
    data.pageFirst = first;
    data.pageSecond = second;
  } else if (scenario === "oversize") {
    const job = await startJob("OVERSIZE");
    data.oversizeTerminal = await statusUntilTerminal(job.jobId, job.cursor);
    data.oversizeResult = await result(job.jobId);
    await ping();
  } else if (scenario === "retention") {
    const job = await startJob("NORMAL RETENTION");
    await statusUntilTerminal(job.jobId, job.cursor);
    await result(job.jobId);
    await delay(140);
    data.expired = await status(job.jobId, 0, 0);
    await ping();
  } else if (scenario === "capacity") {
    const first = await startJob("HANG A");
    const second = await startJob("HANG B");
    await waitForCaptureCount(2);
    data.capacityRejected = await callTool("claude-start", {
      prompt: "HANG C",
      cwd: serverDir,
    });
    await cancel(first.jobId);
    await cancel(second.jobId);
    await statusUntilTerminal(
      first.jobId,
      structured(data.cancels[0])?.cursor ?? first.cursor,
    );
    await statusUntilTerminal(
      second.jobId,
      structured(data.cancels[1])?.cursor ?? second.cursor,
    );
    await ping();
  } else if (scenario === "retained") {
    const first = await startJob("NORMAL RETAINED ONE");
    await statusUntilTerminal(first.jobId, first.cursor);
    await result(first.jobId);
    const second = await startJob("NORMAL RETAINED TWO");
    await statusUntilTerminal(second.jobId, second.cursor);
    await result(second.jobId);
    const third = await startJob("NORMAL RETAINED THREE");
    data.stillRetained = await status(second.jobId, 0, 0);
    data.evicted = await status(first.jobId, 0, 0);
    await statusUntilTerminal(third.jobId, third.cursor);
    await result(third.jobId);
  } else {
    throw new Error(`unknown scenario ${scenario}`);
  }
} catch (error) {
  driverError = error instanceof Error ? error.message : String(error);
} finally {
  await delay(50);
  try { child.stdin.end(); } catch {}
}

const closeInfo = await closed;
clearTimeout(hardStop);
const captures = readdirSync(captureDir)
  .filter((name) => name.endsWith(".json"))
  .sort()
  .map((name) => {
    const base = `${captureDir}/${name.slice(0, -5)}`;
    const meta = JSON.parse(readFileSync(`${base}.json`, "utf8"));
    let rawStdin = "";
    let signals = [];
    try { rawStdin = readFileSync(`${base}.stdin`, "utf8"); } catch {}
    try {
      signals = readFileSync(`${base}.signals`, "utf8")
        .split("\n").filter(Boolean);
    } catch {}
    const stdinParsed = rawStdin
      .split("\n")
      .filter(Boolean)
      .flatMap((line) => {
        try { return [JSON.parse(line)]; } catch { return []; }
      });
    let alive = false;
    try {
      process.kill(meta.pid, 0);
      alive = true;
    } catch {}
    return { meta, rawStdin, stdinParsed, signals, alive };
  });

if (scenario === "paging") {
  const pageMetrics = (frame) => {
    const contentText = frame?.result?.content?.[0]?.text ?? "";
    const structuredText = frame?.result?.structuredContent?.text ?? "";
    return {
      contentCodePoints: Array.from(contentText).length,
      structuredCodePoints: Array.from(structuredText).length,
      equal: contentText === structuredText,
      allRocket: Array.from(contentText).every((char) => char === "🚀"),
      offset: frame?.result?.structuredContent?.offset,
      nextOffset: frame?.result?.structuredContent?.nextOffset,
      endOffset: frame?.result?.structuredContent?.endOffset,
      done: frame?.result?.structuredContent?.done,
    };
  };
  data.pageMetrics = [
    pageMetrics(data.pageFirst),
    pageMetrics(data.pageSecond),
  ];
  for (const frame of frames) {
    const content = frame?.result?.content?.[0];
    if (typeof content?.text === "string" && content.text.length > 1_000) {
      content.text = `[omitted ${Array.from(content.text).length} code points]`;
    }
    const resultText = frame?.result?.structuredContent;
    if (typeof resultText?.text === "string" && resultText.text.length > 1_000) {
      resultText.text =
        `[omitted ${Array.from(resultText.text).length} code points]`;
    }
  }
}

process.stdout.write(`${JSON.stringify({
  scenario,
  driverError,
  closeInfo,
  frames,
  captures,
  data,
  stderr,
  rawParseTail: parseBuffer,
})}\n`);
EOF
}

test_claude_job() {
  local label="$1"
  local scenario="$2"
  local predicate="$3"
  local tmpdir
  local status
  local summary
  local ok=1

  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  write_claude_job_stub "$tmpdir"
  write_claude_job_driver "$tmpdir"

  set +e
  summary=$(
    $TIMEOUT_CMD 9 node "$tmpdir/claude-job-driver.mjs" \
      "$tmpdir" "$(pwd)" "$scenario" 2>/dev/null
  )
  status=$?
  set -e

  [ "$status" -eq 0 ] || ok=0
  printf '%s' "$summary" | jq -e \
    "(.driverError == null) and (.closeInfo.code == 0) and ($predicate)" \
    >/dev/null 2>&1 || ok=0

  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  Summary: ${summary:0:12000}"
    FAIL=$((FAIL + 1))
  fi

  rm -rf "$tmpdir"
}

# ── Helper: stub `codex` on PATH that mirrors received stdin into a capture ──
# file, so we can assert exactly what the wrapper forwarded — no real codex.
write_codex_capture_stub() {
  cat >"$1/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then printf '%s\n' "${MCP_STUB_CODEX_VERSION:-codex-cli 0.145.0}"; exit 0; fi
printf '%s\n' "$$" >> "$MCP_AGENTS_TEST_CHILD_REGISTRY"
# Stub codex mcp-server: echo each received stdin line into the capture file.
# `|| [ -n "$line" ]` also captures a final line with no trailing newline
# (exercises the wrapper's end-of-stdin partial-frame path).
while IFS= read -r line || [ -n "$line" ]; do
  printf '%s\n' "$line" >> "$MCP_AGENTS_TEST_CAPTURE"
done
EOF
  chmod +x "$1/codex"
}

# ── Helper: stub `codex` that snapshots the generated isolated config ──
# before the wrapper cleans up the temporary CODEX_HOME.
write_codex_config_stub() {
  cat >"$1/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then printf '%s\n' "${MCP_STUB_CODEX_VERSION:-codex-cli 0.145.0}"; exit 0; fi
printf '%s\n' "$$" >> "$MCP_AGENTS_TEST_CHILD_REGISTRY"
  cp "$CODEX_HOME/config.toml" "$MCP_AGENTS_TEST_CONFIG_CAPTURE"
if [ -n "${MCP_AGENTS_TEST_HOME_CAPTURE:-}" ]; then
  file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
  }
  root=${CODEX_HOME%/*}
  {
    printf 'home=%s\n' "$CODEX_HOME"
    printf 'root_mode=%s\n' "$(file_mode "$root")"
    printf 'home_mode=%s\n' "$(file_mode "$CODEX_HOME")"
    printf 'auth_mode=%s\n' "$(file_mode "$CODEX_HOME/auth.json")"
    printf 'config_mode=%s\n' "$(file_mode "$CODEX_HOME/config.toml")"
    printf 'models_mode=%s\n' "$(file_mode "$CODEX_HOME/models_cache.json")"
  } > "$MCP_AGENTS_TEST_HOME_CAPTURE"
fi
while IFS= read -r _line; do :; done
EOF
  chmod +x "$1/codex"
}

# ── Helper: verify isolated Codex homes use the private project tmp root ──
test_codex_home_location_and_permissions() {
  local label="$1"
  local tmpdir startup_cwd expected_root real_home config_capture home_capture
  local output_file status home ok

  echo "--- $label ---"

  tmpdir=$(mktemp -d)
  mkdir -p "$TEST_REPO_ROOT/tmp"
  startup_cwd=$(mktemp -d "$TEST_REPO_ROOT/tmp/codex-home-test.XXXXXX")
  expected_root="$startup_cwd/tmp/codex-homes"
  real_home="$tmpdir/real-codex"
  config_capture="$tmpdir/config.toml"
  home_capture="$tmpdir/home.txt"
  output_file="$tmpdir/output.txt"
  mkdir "$real_home"
  printf '%s' '{"token":"original"}' > "$real_home/auth.json"
  printf '%s' '{"models":[]}' > "$real_home/models_cache.json"
  chmod 0644 "$real_home/auth.json" "$real_home/models_cache.json"
  mkdir -p "$expected_root"
  chmod 0755 "$expected_root"
  write_codex_config_stub "$tmpdir"

  set +e
  (
    cd "$startup_cwd"
    {
      sleep 0.2
    } | PATH="$tmpdir:$PATH" CODEX_HOME="$real_home" \
      MCP_AGENTS_TEST_CONFIG_CAPTURE="$config_capture" \
      MCP_AGENTS_TEST_HOME_CAPTURE="$home_capture" \
      $TIMEOUT_CMD 10 node "$TEST_REPO_ROOT/server.js" --provider codex \
      >"$output_file" 2>/dev/null
  )
  status=$?
  set -e

  home=$(sed -n 's/^home=//p' "$home_capture" 2>/dev/null || true)
  ok=1
  [ "$status" -eq 0 ] || ok=0
  case "$home" in
    "$expected_root"/mcp-agents-codex-*) ;;
    *) ok=0 ;;
  esac
  grep -Fxq 'root_mode=700' "$home_capture" 2>/dev/null || ok=0
  grep -Fxq 'home_mode=700' "$home_capture" 2>/dev/null || ok=0
  grep -Fxq 'auth_mode=600' "$home_capture" 2>/dev/null || ok=0
  grep -Fxq 'config_mode=600' "$home_capture" 2>/dev/null || ok=0
  grep -Fxq 'models_mode=600' "$home_capture" 2>/dev/null || ok=0
  [ -n "$home" ] && [ ! -e "$home" ] || ok=0

  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  Home: $home"
    echo "  Capture: $(cat "$home_capture" 2>/dev/null || true)"
    echo "  Output: $(cat "$output_file")"
    FAIL=$((FAIL + 1))
  fi

  rm -rf "$tmpdir" "$startup_cwd"
}

# ── Helper: stub `codex` that simulates auth rotation and creates the stale ──
# PID-named temp file used by the old write-back implementation.
write_codex_auth_rotation_stub() {
  cat >"$1/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then printf '%s\n' "${MCP_STUB_CODEX_VERSION:-codex-cli 0.145.0}"; exit 0; fi
printf '%s\n' "$$" >> "$MCP_AGENTS_TEST_CHILD_REGISTRY"
stale="$MCP_AGENTS_TEST_REAL_CODEX_HOME/.auth.json.mcp-agents-${PPID}.tmp"
printf '%s' '{"token":"stale"}' > "$stale"
chmod 0644 "$stale"
printf '%s' '{"token":"rotated"}' > "$CODEX_HOME/auth.json"
while IFS= read -r _line; do :; done
EOF
  chmod +x "$1/codex"
}

# ── Helper: stub `codex` that simulates a manual login replacing canonical ──
# auth while an older bridge is still alive. The isolated copy deliberately
# stays unchanged; shutdown must never copy it back over the newer login.
write_codex_auth_conflict_stub() {
  cat >"$1/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then printf '%s\n' "${MCP_STUB_CODEX_VERSION:-codex-cli 0.145.0}"; exit 0; fi
printf '%s\n' "$$" >> "$MCP_AGENTS_TEST_CHILD_REGISTRY"
printf '%s' '{"token":"fresh-login"}' > "$MCP_AGENTS_TEST_REAL_CODEX_HOME/auth.json"
chmod 0600 "$MCP_AGENTS_TEST_REAL_CODEX_HOME/auth.json"
while IFS= read -r _line; do :; done
EOF
  chmod +x "$1/codex"
}

# ── Helper: verify the generated isolated Codex config is intentionally lean ──
test_codex_bridge_config() {
  local label="$1"
  local expected_network="$2"
  local server_args="$3"
  local env_network="$4"
  local source_config="${5:-}"
  local expected_fast="${6:-false}"
  local expected_agents="${7:-present}"
  local tmpdir real_home config_capture output_file error_file status expected ok
  local -a network_env

  echo "--- $label ---"

  tmpdir=$(mktemp -d)
  real_home="$tmpdir/real-codex"
  config_capture="$tmpdir/config.toml"
  output_file="$tmpdir/output.txt"
  error_file="$tmpdir/error.txt"
  mkdir "$real_home"
  if [ "$source_config" = "__read_error__" ]; then
    mkdir "$real_home/config.toml"
  elif [ -n "$source_config" ]; then
    printf '%s\n' "$source_config" > "$real_home/config.toml"
  fi
  write_codex_config_stub "$tmpdir"

  if [ "$env_network" = "__unset__" ]; then
    network_env=(-u MCP_AGENTS_CODEX_WORKSPACE_NETWORK_ACCESS)
  else
    network_env=("MCP_AGENTS_CODEX_WORKSPACE_NETWORK_ACCESS=$env_network")
  fi

  set +e
  {
    sleep 0.2
  } | env "${network_env[@]}" PATH="$tmpdir:$PATH" CODEX_HOME="$real_home" \
    MCP_AGENTS_TEST_CONFIG_CAPTURE="$config_capture" \
    $TIMEOUT_CMD 10 $SERVER --provider codex $server_args >"$output_file" 2>"$error_file"
  status=$?
  set -e

  ok=1
  [ "$status" -eq 0 ] || ok=0
  for expected in \
    'model = "gpt-5.6-sol"' \
    'model_reasoning_effort = "xhigh"' \
    'web_search = "cached"' \
    'check_for_update_on_startup = false' \
    'allow_login_shell = false' \
    '[sandbox_workspace_write]' \
    "network_access = $expected_network" \
    '[history]' \
    'persistence = "none"' \
    '[features]' \
    'apps = false' \
    'hooks = false' \
    'plugins = false' \
    'multi_agent = false' \
    'skill_mcp_dependency_install = false'
  do
    grep -Fxq "$expected" "$config_capture" 2>/dev/null || ok=0
  done
  [ "$(grep -Fxc '[sandbox_workspace_write]' "$config_capture" 2>/dev/null)" -eq 1 ] || ok=0
  [ "$(grep -Fxc '[features]' "$config_capture" 2>/dev/null)" -eq 1 ] || ok=0
  if [ "$expected_agents" = "present" ]; then
    # >= 0.145.0 (or unknown version): the [agents] off switch is emitted, and
    # `enabled = false` must live INSIDE the [agents] table (the real off
    # switch for native subagents there), not as a stray top-level key.
    [ "$(grep -Fxc '[agents]' "$config_capture" 2>/dev/null)" -eq 1 ] || ok=0
    sed -n '/^\[agents\]$/,/^\[/p' "$config_capture" | grep -Fxq 'enabled = false' || ok=0
    grep -Fq 'subagent_gate=agents_enabled' "$error_file" || ok=0
  else
    # 0.102–0.144 hard-fail parsing a boolean under [agents]; the whole table
    # must be absent and the feature flag remains the (working) off switch.
    grep -Fq '[agents]' "$config_capture" 2>/dev/null && ok=0
    grep -Fxq 'enabled = false' "$config_capture" 2>/dev/null && ok=0
    grep -Fq 'subagent_gate=feature_flag_only' "$error_file" || ok=0
  fi

  if [ "$expected_fast" = "true" ]; then
    [ "$(grep -Fxc 'service_tier = "fast"' "$config_capture" 2>/dev/null)" -eq 1 ] || ok=0
    [ "$(grep -Fxc 'fast_mode = true' "$config_capture" 2>/dev/null)" -eq 1 ] || ok=0
    sed '/^\[/,$d' "$config_capture" | grep -Fxq 'service_tier = "fast"' || ok=0
    sed -n '/^\[features\]$/,/^\[/p' "$config_capture" | grep -Fxq 'fast_mode = true' || ok=0
    grep -Fq 'fast_mode_opt_in=true' "$error_file" || ok=0
  else
    [ "$(grep -Fxc 'service_tier = "fast"' "$config_capture" 2>/dev/null)" -eq 0 ] || ok=0
    [ "$(grep -Fxc 'fast_mode = true' "$config_capture" 2>/dev/null)" -eq 0 ] || ok=0
    grep -Fq 'fast_mode_opt_in=false' "$error_file" || ok=0
  fi

  grep -Fq 'do_not_copy' "$config_capture" 2>/dev/null && ok=0
  grep -Fq 'mcp_servers.sentinel' "$config_capture" 2>/dev/null && ok=0
  if [ "$source_config" = "__read_error__" ]; then
    grep -Fq 'failed to read source Codex Fast-mode config' "$error_file" || ok=0
  fi

  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  Config:"
    sed 's/^/    /' "$config_capture" 2>/dev/null || true
    echo "  Output: $(cat "$output_file")"
    echo "  Error: $(cat "$error_file")"
    FAIL=$((FAIL + 1))
  fi

  rm -rf "$tmpdir"
}

# ── Helper: verify rotated auth write-back does not reuse stale broad-mode temp files ──
test_codex_auth_persistence_secure_temp() {
  local label="$1"
  local tmpdir real_home output_file status content mode ok

  echo "--- $label ---"

  tmpdir=$(mktemp -d)
  real_home="$tmpdir/real-codex"
  output_file="$tmpdir/output.txt"
  mkdir "$real_home"
  printf '%s' '{"token":"original"}' > "$real_home/auth.json"
  chmod 0644 "$real_home/auth.json"
  write_codex_auth_rotation_stub "$tmpdir"

  set +e
  {
    sleep 0.2
  } | PATH="$tmpdir:$PATH" CODEX_HOME="$real_home" MCP_AGENTS_TEST_REAL_CODEX_HOME="$real_home" \
    $TIMEOUT_CMD 10 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e

  content=$(cat "$real_home/auth.json" 2>/dev/null || true)
  mode=$(stat -c '%a' "$real_home/auth.json" 2>/dev/null || stat -f '%Lp' "$real_home/auth.json" 2>/dev/null || true)
  ok=1
  [ "$status" -eq 0 ] || ok=0
  [ "$content" = '{"token":"rotated"}' ] || ok=0
  [ "$mode" = "600" ] || ok=0

  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status mode=${mode:-<missing>})"
    echo "  auth.json: $content"
    echo "  Output: $(cat "$output_file")"
    FAIL=$((FAIL + 1))
  fi

  rm -rf "$tmpdir"
}

# ── Helper: verify an older isolated auth snapshot cannot clobber a newer ──
# canonical login when the bridge shuts down.
test_codex_auth_persistence_conflict() {
  local label="$1"
  local tmpdir real_home output_file status content ok

  echo "--- $label ---"

  tmpdir=$(mktemp -d)
  real_home="$tmpdir/real-codex"
  output_file="$tmpdir/output.txt"
  mkdir "$real_home"
  printf '%s' '{"token":"original"}' > "$real_home/auth.json"
  chmod 0600 "$real_home/auth.json"
  write_codex_auth_conflict_stub "$tmpdir"

  set +e
  {
    sleep 0.2
  } | PATH="$tmpdir:$PATH" CODEX_HOME="$real_home" MCP_AGENTS_TEST_REAL_CODEX_HOME="$real_home" \
    $TIMEOUT_CMD 10 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e

  content=$(cat "$real_home/auth.json" 2>/dev/null || true)
  ok=1
  [ "$status" -eq 0 ] || ok=0
  [ "$content" = '{"token":"fresh-login"}' ] || ok=0

  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  auth.json: $content"
    echo "  Output: $(cat "$output_file")"
    FAIL=$((FAIL + 1))
  fi

  rm -rf "$tmpdir"
}

# ── Helper: node stub `codex` mcp-server for the watchdog tests. Answers ──
# initialize, emits one event for tools/call, then per MCP_STUB_MODE either
# stalls (stays silent → exercises the idle watchdog) or dies (process.exit →
# exercises the child-death path). No real codex needed.
write_codex_watchdog_stub() {
  cat >"$1/codex" <<'EOF'
#!/usr/bin/env node
if (process.argv[2] === "--version") { process.stdout.write(`${process.env.MCP_STUB_CODEX_VERSION || "codex-cli 0.145.0"}\n`); process.exit(0); }
const MODE = process.env.MCP_STUB_MODE || "stall";
require("fs").appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${process.pid}\n`);
// Record our pid so the test can assert the wrapper actually killed us on
// teardown (no orphaned stalled codex), mirroring the claude shutdown test.
if (process.env.MCP_AGENTS_TEST_PID_FILE) {
  try { require("fs").writeFileSync(process.env.MCP_AGENTS_TEST_PID_FILE, String(process.pid)); } catch {}
}
let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (d) => {
  buf += d;
  let nl;
  while ((nl = buf.indexOf("\n")) !== -1) {
    const line = buf.slice(0, nl); buf = buf.slice(nl + 1);
    let m; try { m = JSON.parse(line); } catch { continue; }
    if (m.method === "initialize") {
      process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: m.id, result: { protocolVersion: "2024-11-05", capabilities: {}, serverInfo: { name: "stub", version: "0" } } }) + "\n");
    } else if (m.method === "tools/call") {
      process.stdout.write(JSON.stringify({ jsonrpc: "2.0", method: "codex/event", params: { msg: "working" } }) + "\n");
      if (MODE === "die") process.exit(0); // codex dies without responding
      // late: stall past the idle watchdog, THEN answer — the "zombie writer finally
      // reports back" case, which must settle the abandonment record rather than leave
      // the count climbing forever.
      const lateMs = Number(process.env.MCP_STUB_LATE_MS || 0);
      if (lateMs > 0) {
        setTimeout(() => {
          process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: m.id, result: { content: [{ type: "text", text: "late" }] } }) + "\n");
        }, lateMs);
      }
      // stall: emit nothing further → idle watchdog must fire
    }
  }
});
// Exit when the bridge closes our stdin so a stall case can shut down cleanly
// once the client disconnects (the idle watchdog no longer kills us).
process.stdin.on("end", () => process.exit(0));
setInterval(() => {}, 1 << 30);
EOF
  chmod +x "$1/codex"
}

# ── Helper: drive initialize + tools/call(id:2) at a stub codex, asserting the ──
# wrapper synthesizes a JSON-RPC -32001 error for the open id:2 (no hang).
#   $1 label, $2 MCP_STUB_MODE (stall|die), $3 extra server args
# ── Helper: abandon a turn via the idle watchdog, then peek at the ledger ────
# codex-peek's abandonedTurnsProcessWide is the ONLY thing that reports a turn the
# wrapper stopped waiting for while Codex may still be writing. Without this case, the
# noteAbandonedTurn / noteAbandonedTurnSettled bookkeeping could be deleted outright and
# the suite would stay green — which is exactly the "reports nothing, so nothing is
# running" inversion the tool exists to prevent.
#   $1 label, $2 tool name to abandon (codex | codex-start), $3 jq predicate over id:9,
#   $4 optional MCP_STUB_LATE_MS — when set, the stub answers AFTER being abandoned, so
#      the predicate pins the SETTLEMENT half of the ledger rather than the recording half
test_codex_abandoned_ledger() {
  local label="$1" tool="$2" predicate="$3" late_ms="${4:-0}"
  local tmpdir output_file status RESPONSE ok
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  output_file="$tmpdir/out.txt"
  write_codex_watchdog_stub "$tmpdir"
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool\",\"arguments\":{\"prompt\":\"hi\",\"cwd\":\"/tmp/abandon-workspace\",\"sandbox\":\"workspace-write\"}}}"
    sleep 4
    if [ "$late_ms" -gt 0 ]; then sleep 4; fi
    printf '%s\n' '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"codex-peek","arguments":{}}}'
    sleep 1.5
  } | PATH="$tmpdir:$PATH" MCP_STUB_MODE=stall MCP_STUB_LATE_MS="$late_ms" \
    $TIMEOUT_CMD 25 $SERVER --provider codex --codex_idle_timeout 2 >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  ok=1
  echo "$RESPONSE" | jq -e "$predicate" >/dev/null 2>&1 || ok=0
  if [ "$ok" -eq 1 ]; then green "PASS: $label"; PASS=$((PASS + 1)); else
    red "FAIL: $label (status=$status)"; echo "  Response: $RESPONSE"; FAIL=$((FAIL + 1)); fi
  rm -rf "$tmpdir"
}

run_codex_watchdog_case() {
  local label="$1" mode="$2" extra="$3" expected_status="$4"
  local tmpdir output_file pid_file status RESPONSE child_pid
  local resp_ok=0 child_ok=0
  echo "--- $label ---"

  tmpdir=$(mktemp -d)
  output_file="$tmpdir/out.txt"
  pid_file="$tmpdir/codex.pid"
  write_codex_watchdog_stub "$tmpdir"

  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"codex","arguments":{"prompt":"hi","cwd":"/tmp","sandbox":"read-only","model_reasoning_effort":"xhigh"}}}'
    sleep 4
  } | PATH="$tmpdir:$PATH" MCP_STUB_MODE="$mode" MCP_AGENTS_TEST_PID_FILE="$pid_file" \
    $TIMEOUT_CMD 12 $SERVER --provider codex $extra >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  child_pid=$(cat "$pid_file" 2>/dev/null || true)
  sleep 0.3 # allow the group SIGKILL to take effect before the liveness check

  # The wrapper must surface for the still-open id:2 EXACTLY one error frame
  # that is the -32001 idle/teardown error, and NO result frame for it (no
  # double-respond, no malformed result+error frame), and it must NOT have
  # errored the already-answered id:1.
  if echo "$RESPONSE" | jq -se '
      (map(select(.id == 1 and has("error"))) | length == 0) and
      (map(select(.id == 2 and has("result"))) | length == 0) and
      (map(select(.id == 2 and has("error"))) | length == 1) and
      (map(select(.id == 2 and (.error.code? == -32001))) | length == 1)
    ' >/dev/null 2>&1; then
    resp_ok=1
  fi
  # The wrapper must also tear codex down (no orphaned stalled child).
  if [ -n "$child_pid" ] && ! kill -0 "$child_pid" 2>/dev/null; then
    child_ok=1
  fi

  # Exact exit code, not just "not a timeout": under the per-request timeout
  # contract the idle watchdog fails ONLY the stalled call and keeps the bridge
  # connected, so a stall now exits 0 when the client closes stdin (NOT exit 1
  # at the timeout — that would be the old whole-process teardown regression);
  # die exits with codex's own clean code (0). A different code means a crash.
  if [ "$status" -eq "$expected_status" ] && [ "$resp_ok" -eq 1 ] && [ "$child_ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status want=$expected_status resp_ok=$resp_ok child_ok=$child_ok)"
    echo "  Response: $RESPONSE"
    if [ "$child_ok" -ne 1 ]; then
      echo "  codex stub still alive (orphan): ${child_pid:-<no pid>}"
      terminate_test_child "$child_pid"
    fi
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

# ── Helper: an accepted Codex call requiring no wrapper transformation is ──
# forwarded byte-for-byte (no JSON re-serialization), preserving MCP stdio
# framing exactly.
test_codex_call_passes_through_unmodified() {
  local label="$1"
  local tool_name="$2"
  local arguments_json="$3"
  local tmpdir capture output_file status input captured
  echo "--- $label ---"

  tmpdir=$(mktemp -d)
  capture="$tmpdir/codex_stdin.txt"
  output_file="$tmpdir/output.txt"
  : >"$capture"
  write_codex_capture_stub "$tmpdir"

  input="{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool_name\",\"arguments\":$arguments_json}}"

  set +e
  {
    printf '%s\n' "$input"
    sleep 0.5
  } | PATH="$tmpdir:$PATH" MCP_AGENTS_TEST_CAPTURE="$capture" \
    $TIMEOUT_CMD 10 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e

  captured=$(grep '"method":"tools/call"' "$capture" 2>/dev/null | tail -1)
  if [ "$status" -eq 0 ] && [ "$captured" = "$input" ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  Expected: $input"
    echo "  Captured: $captured"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

# ── Helper: drive one tools/call (with the given `arguments` JSON) through a ──
# capture-stub codex under the given server args, then assert a jq predicate
# over the forwarded call's parsed JSON-RPC message. Proves wrapper-only arg
# sanitization/translation without needing a real Codex session.
#   $1 label, $2 extra server args, $3 arguments JSON, $4 jq predicate,
#   $5 tool name (optional, default "codex")
test_codex_call_transform() {
  local label="$1" server_args="$2" arguments_json="$3" predicate="$4"
  local tool_name="${5:-codex}"
  local tmpdir capture output_file status call_line
  echo "--- $label ---"

  tmpdir=$(mktemp -d)
  capture="$tmpdir/codex_stdin.txt"
  output_file="$tmpdir/output.txt"
  : >"$capture"
  write_codex_capture_stub "$tmpdir"

  set +e
  {
    printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool_name\",\"arguments\":$arguments_json}}"
    sleep 0.5
  } | PATH="$tmpdir:$PATH" MCP_AGENTS_TEST_CAPTURE="$capture" \
    $TIMEOUT_CMD 10 $SERVER --provider codex $server_args >"$output_file" 2>/dev/null
  status=$?
  set -e

  call_line=$(grep '"method":"tools/call"' "$capture" 2>/dev/null | tail -1 || true)
  if [ "$status" -eq 0 ] && [ -n "$call_line" ] && \
     echo "$call_line" | jq -e "$predicate" >/dev/null 2>&1; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  Forwarded: $call_line"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

# ── Helper: assert a strict-contract violation returns one redacted -32602 and ──
# never reaches native Codex.
#   $1 label, $2 arguments JSON, $3 jq predicate over the error frame,
#   $4 tool name (optional, default "codex")
test_codex_rejects_call() {
  local label="$1" arguments_json="$2" predicate="$3"
  local tool_name="${4:-codex}"
  local tmpdir capture output_file status response call_line ok
  echo "--- $label ---"

  tmpdir=$(mktemp -d)
  capture="$tmpdir/codex_stdin.txt"
  output_file="$tmpdir/output.txt"
  : >"$capture"
  write_codex_capture_stub "$tmpdir"

  set +e
  {
    printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool_name\",\"arguments\":$arguments_json}}"
    sleep 0.5
  } | PATH="$tmpdir:$PATH" MCP_AGENTS_TEST_CAPTURE="$capture" \
    $TIMEOUT_CMD 10 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e

  response=$(cat "$output_file")
  call_line=$(grep '"method":"tools/call"' "$capture" 2>/dev/null | tail -1 || true)
  ok=1
  [ "$status" -eq 0 ] || ok=0
  [ -z "$call_line" ] || ok=0
  echo "$response" | jq -e "select(.id == 2) | (.error.code == -32602) and ($predicate)" >/dev/null 2>&1 || ok=0
  if [[ "$arguments_json" == *"STRICT_SECRET"* ]] && [[ "$response" == *"STRICT_SECRET"* ]]; then
    ok=0
  fi

  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  Forwarded: $call_line"
    echo "  Response: $response"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

# ── Helper: strict local errors share the generated-frame queue safely. ──
# Exercises partial native stdout, concurrent valid work, cancellation before a
# queued local response can flush, and invalid notifications (which get dropped).
test_codex_local_response_lifecycle() {
  local label="$1" tmpdir status out
  echo "--- $label ---"
  tmpdir=$(mktemp -d)

  cat >"$tmpdir/codex" <<'EOF'
#!/usr/bin/env node
if (process.argv[2] === "--version") { process.stdout.write(`${process.env.MCP_STUB_CODEX_VERSION || "codex-cli 0.145.0"}\n`); process.exit(0); }
const fs = require("fs");
const mode = process.env.MCP_STUB_LOCAL_MODE;
const capture = process.env.MCP_STUB_LOCAL_CAPTURE;
fs.appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${process.pid}\n`);

const send = (message) => process.stdout.write(`${JSON.stringify(message)}\n`);
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  input += chunk;
  let newline;
  while ((newline = input.indexOf("\n")) !== -1) {
    const line = input.slice(0, newline);
    input = input.slice(newline + 1);
    let message;
    try { message = JSON.parse(line); } catch { continue; }
    fs.appendFileSync(capture, `${JSON.stringify(message)}\n`);
    if (message.method === "initialize") {
      send({ jsonrpc: "2.0", id: message.id, result: { protocolVersion: "2024-11-05", capabilities: {}, serverInfo: { name: "local-stub", version: "0" } } });
      if (mode === "partial" || mode === "cancel") {
        setTimeout(() => process.stdout.write('{"jsonrpc":"2.0","method":"codex/event","params":{"marker":"LOCAL_PART'), 25);
        setTimeout(() => process.stdout.write('IAL"}}\n'), 250);
      }
    } else if (message.method === "tools/call") {
      setTimeout(() => send({ jsonrpc: "2.0", id: message.id, result: { content: [{ type: "text", text: "VALID" }] } }), 40);
    }
  }
});
process.stdin.on("end", () => setTimeout(() => process.exit(0), 350));
setInterval(() => {}, 1 << 30);
EOF
  chmod +x "$tmpdir/codex"

  cat >"$tmpdir/driver.mjs" <<'EOF'
import { spawn } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";

const [stubDir, serverDir, mode = "async"] = process.argv.slice(2);
const invalid = (id) => ({
  jsonrpc: "2.0",
  ...(id === undefined ? {} : { id }),
  method: "tools/call",
  params: { name: "codex", arguments: { prompt: "invalid" } },
});
const valid = {
  jsonrpc: "2.0",
  id: 3,
  method: "tools/call",
  params: { name: "codex", arguments: { prompt: "valid", cwd: serverDir, sandbox: "read-only", model_reasoning_effort: "xhigh" } },
};

const run = (mode) => new Promise((resolve) => {
  const capture = `${stubDir}/${mode}.jsonl`;
  writeFileSync(capture, "");
  const child = spawn("node", ["server.js", "--provider", "codex"], {
    cwd: serverDir,
    env: { ...process.env, PATH: `${stubDir}:${process.env.PATH}`, MCP_STUB_LOCAL_MODE: mode, MCP_STUB_LOCAL_CAPTURE: capture },
    stdio: ["pipe", "pipe", "pipe"],
  });
  let output = "";
  let parseBuffer = "";
  let started = false;
  child.stdin.on("error", () => {});
  child.stderr.resume();
  const send = (message) => child.stdin.write(`${JSON.stringify(message)}\n`);
  child.stdout.on("data", (chunk) => {
    output += chunk.toString();
    parseBuffer += chunk.toString();
    let newline;
    while ((newline = parseBuffer.indexOf("\n")) !== -1) {
      const line = parseBuffer.slice(0, newline);
      parseBuffer = parseBuffer.slice(newline + 1);
      let frame;
      try { frame = JSON.parse(line); } catch { continue; }
      if (frame.id !== 1 || !frame.result || started) continue;
      started = true;
      if (mode === "partial" || mode === "cancel") {
        setTimeout(() => send(invalid(2)), 75);
        if (mode === "cancel") {
          setTimeout(() => send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 2 } }), 125);
        }
      } else if (mode === "concurrent") {
        send(invalid(2));
        send(valid);
      } else if (mode === "delivered") {
        send(invalid(2));
        setTimeout(() => send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 2 } }), 75);
      } else {
        send(invalid(undefined));
        send(valid);
      }
      setTimeout(() => child.stdin.end(), 450);
    }
  });
  send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "local-test", version: "0" } } });
  child.once("close", (code) => {
    const lines = output.split("\n").filter(Boolean);
    let parseErrors = 0;
    const frames = lines.flatMap((line) => {
      try { return [JSON.parse(line)]; } catch { parseErrors += 1; return []; }
    });
    const captured = readFileSync(capture, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
    resolve({ mode, code, parseErrors, frames, captured });
  });
});

const results = [];
for (const mode of ["partial", "concurrent", "cancel", "delivered", "notification"]) results.push(await run(mode));
const byMode = Object.fromEntries(results.map((result) => [result.mode, result]));
const frames = (mode, predicate) => byMode[mode].frames.filter(predicate);
const capturedCalls = (mode) => byMode[mode].captured.filter((message) => message.method === "tools/call");
const capturedCancels = (mode) => byMode[mode].captured.filter((message) => message.method === "notifications/cancelled");
const partialMarker = byMode.partial.frames.findIndex((frame) => frame.params?.marker === "LOCAL_PARTIAL");
const partialError = byMode.partial.frames.findIndex((frame) => frame.id === 2 && frame.error?.code === -32602);
const ok = results.every((result) => result.code === 0 && result.parseErrors === 0) &&
  partialMarker >= 0 && partialError > partialMarker && frames("partial", (frame) => frame.id === 2).length === 1 && capturedCalls("partial").length === 0 &&
  frames("concurrent", (frame) => frame.id === 2 && frame.error?.code === -32602).length === 1 && frames("concurrent", (frame) => frame.id === 3 && frame.result).length === 1 && capturedCalls("concurrent").map((message) => message.id).join(",") === "3" &&
  frames("cancel", (frame) => frame.id === 2).length === 0 && capturedCalls("cancel").length === 0 && capturedCancels("cancel").length === 0 &&
  frames("delivered", (frame) => frame.id === 2 && frame.error?.code === -32602).length === 1 && capturedCalls("delivered").length === 0 && capturedCancels("delivered").length === 0 &&
  frames("notification", (frame) => frame.error?.code === -32602).length === 0 && frames("notification", (frame) => frame.id === 3 && frame.result).length === 1 && capturedCalls("notification").map((message) => message.id).join(",") === "3";
process.stdout.write(`${ok ? "LOCAL_OK" : "LOCAL_FAIL"}\n${JSON.stringify(results)}\n`);
process.exit(ok ? 0 : 1);
EOF

  set +e
  out=$($TIMEOUT_CMD 20 node "$tmpdir/driver.mjs" "$tmpdir" "$(pwd)" 2>/dev/null)
  status=$?
  set -e
  if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -Fq "LOCAL_OK"; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  Output: $out"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

# ── Helper: a per-call sandbox=workspace-write + absolute cwd actually grants ──
# writes end-to-end (real codex). Proves the read-only symptom is fixed.
test_codex_percall_write() {
  local label="$1"
  local probe_dir probe_file output_file status RESPONSE shape_ok
  echo "--- $label ---"

  probe_dir=$(mktemp -d)
  probe_file="$probe_dir/mcp_agents_probe.txt"
  output_file=$(mktemp)

  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.0.1"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"codex\",\"arguments\":{\"prompt\":\"Create a file named mcp_agents_probe.txt containing exactly OK in your current working directory, then reply with only OK.\",\"sandbox\":\"workspace-write\",\"cwd\":\"$probe_dir\",\"model_reasoning_effort\":\"xhigh\"}}}"
    sleep 30
  } | $TIMEOUT_CMD 50 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  rm -f "$output_file"

  # Two independent checks: the file proves per-call sandbox/cwd granted writes,
  # and the live JSON-shape assertion verifies codex's MCP result envelope still
  # matches what the bridge depends on (so codex output-format drift is caught).
  shape_ok=0
  if echo "$RESPONSE" | jq -e 'select(.id == 2) | (.result.isError != true) and (.result.structuredContent.content | type == "string")' >/dev/null 2>&1; then
    shape_ok=1
  fi

  if [ "$status" -eq 0 ] && [ -f "$probe_file" ] && [ "$shape_ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label"
    [ "$status" -eq 0 ] || echo "  server exited non-zero ($status)"
    [ -f "$probe_file" ] || echo "  probe file not created — per-call sandbox/cwd did not grant writes"
    [ "$shape_ok" -eq 1 ] || echo "  ⚠ codex MCP result shape unexpected — output format may have changed"
    echo "  Response: $RESPONSE"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$probe_dir"
}

# ── Helper: node stub `codex` mcp-server for tools/list schema-rewrite ──
# tests. Answers initialize, then on tools/list emits a result with codex +
# codex-reply tools (real schema shapes) per MCP_STUB_TLMODE — exercising the
# wrapper's contained-latch rewrite paths. No real codex needed.
write_codex_toolslist_stub() {
  cat >"$1/codex" <<'EOF'
#!/usr/bin/env node
if (process.argv[2] === "--version") { process.stdout.write(`${process.env.MCP_STUB_CODEX_VERSION || "codex-cli 0.145.0"}\n`); process.exit(0); }
const MODE = process.env.MCP_STUB_TLMODE || "normal";
require("fs").appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${process.pid}\n`);
const SENTINEL = '{"jsonrpc":"2.0","method":"codex/event","params":{"marker":"PASSTHROUGH_SENTINEL"}}';
const STRADDLE = '{"jsonrpc":"2.0","method":"codex/event","params":{"marker":"STRADDLE_SENTINEL"}}';
const STRADDLE_HEAD = STRADDLE.slice(0, 40);   // emitted on initialize, NO newline (orphan head)
const STRADDLE_TAIL = STRADDLE.slice(40);      // emitted on tools/list, completes the frame
function tools(withGoal, withEffort) {
  const codex = {
    name: "codex",
    title: "Native Codex title",
    description: "Run a Codex session. Accepts configuration parameters matching the Codex Config struct.",
    annotations: { readOnlyHint: false },
    outputSchema: { type: "object", properties: { threadId: { type: "string" } } },
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["prompt"],
      properties: {
        "approval-policy": { type: "string" },
        "base-instructions": { type: "string" },
        "compact-prompt": { type: "string" },
        config: { type: "object" },
        cwd: { type: "string" },
        "developer-instructions": { type: "string" },
        model: { type: "string" },
        prompt: { type: "string" },
        sandbox: { type: "string" },
        future_upstream_setting: { type: "string" },
      },
    },
  };
  if (withGoal) codex.inputSchema.properties.goal = { type: "string", description: "STUB_OWN_GOAL_DESC" };
  const reply = {
    name: "codex-reply",
    description: "Continue a Codex session.",
    inputSchema: {
      type: "object",
      required: ["prompt"],
      properties: {
        conversationId: { type: "string" },
        threadId: { type: "string" },
        prompt: { type: "string" },
        future_reply_setting: { type: "boolean" },
      },
    },
  };
  if (withEffort) {
    const drifted = { type: "string", enum: ["low", "xhigh", "max", "ultra"], description: "STUB_DRIFTED_EFFORT_DESC" };
    codex.inputSchema.properties.model_reasoning_effort = { ...drifted };
    reply.inputSchema.properties.model_reasoning_effort = { ...drifted };
  }
  return [codex, reply];
}
const resultLine = (id, withGoal, withEffort = false) => JSON.stringify({ jsonrpc: "2.0", id, result: { tools: tools(withGoal, withEffort) } });
function onToolsList(id) {
  if (MODE === "havegoal") { process.stdout.write(resultLine(id, true) + "\n"); return; }
  if (MODE === "haveeffort") { process.stdout.write(resultLine(id, false, true) + "\n"); return; }
  if (MODE === "noctools") { process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result: { tools: [{ name: "ping", inputSchema: { type: "object", properties: {} } }] } }) + "\n"); return; }
  if (MODE === "error") { process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32601, message: "no" } }) + "\n"); return; }
  if (MODE === "interleaved") { process.stdout.write(SENTINEL + "\n"); process.stdout.write(resultLine(id, false) + "\n"); return; }
  if (MODE === "split") { const s = resultLine(id, false); const cut = Math.floor(s.length / 2); process.stdout.write(s.slice(0, cut)); setTimeout(() => process.stdout.write(s.slice(cut) + "\n"), 40); return; }
  if (MODE === "straddle") { process.stdout.write(STRADDLE_TAIL + "\n"); process.stdout.write(resultLine(id, false) + "\n"); return; }
  if (MODE === "partialdie") { const s = resultLine(id, false); process.stdout.write(s.slice(0, Math.floor(s.length / 2)), () => process.exit(0)); return; }
  if (MODE === "nonewlinedie") { process.stdout.write(resultLine(id, false), () => process.exit(0)); return; }
  if (MODE === "bp") { process.stdout.write(JSON.stringify({ jsonrpc: "2.0", method: "codex/event", params: { pad: "x".repeat(200000) } }) + "\n"); process.stdout.write(resultLine(id, false) + "\n"); return; }
  if (MODE === "trailpartialdie") { process.stdout.write(resultLine(id, false) + '\n{"jsonrpc":"2.0","method":"codex/event","params":{"marker":"TRAILING_HEAD', () => process.exit(0)); return; } // result + a NON-tools/list partial head (no newline) then die
  if (MODE === "cancelpartial") { process.stdout.write('{"jsonrpc":"2.0","method":"codex/event","params":{"marker":"CANCEL_PARTIAL'); setTimeout(() => process.exit(0), 900); return; } // a withheld NON-tools/list partial; the driver cancels the tools/list, then we die
  if (MODE === "oversized") { const big = JSON.stringify({ jsonrpc: "2.0", method: "codex/event", params: { marker: "OVERSIZED_MARKER", pad: "x".repeat(11 * 1024 * 1024) } }); process.stdout.write(big + "\n"); process.stdout.write(resultLine(id, false) + "\n", () => setTimeout(() => process.exit(0), 100)); return; }
  process.stdout.write(resultLine(id, false) + "\n"); // normal
}
let buf = "";
let exitTimer;
process.stdin.setEncoding("utf8");
process.stdin.on("data", (d) => {
  buf += d;
  let nl;
  while ((nl = buf.indexOf("\n")) !== -1) {
    const line = buf.slice(0, nl); buf = buf.slice(nl + 1);
    let m; try { m = JSON.parse(line); } catch { continue; }
    if (m.method === "initialize") {
      process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: m.id, result: { protocolVersion: "2024-11-05", capabilities: {}, serverInfo: { name: "stub", version: "0" } } }) + "\n");
      if (MODE === "straddle") process.stdout.write(STRADDLE_HEAD); // orphan head, no newline -> wire mid-frame
    } else if (m.method === "tools/list") {
      onToolsList(m.id);
      // Exit shortly after the LAST response so the wrapper (which waits on codex)
      // can shut down cleanly — the response was already observed, so finalize
      // synthesizes no -32001. partialdie/nonewlinedie self-exit; bp is driver-killed.
      if (MODE !== "partialdie" && MODE !== "nonewlinedie" && MODE !== "bp" && MODE !== "trailpartialdie" && MODE !== "oversized" && MODE !== "cancelpartial") {
        clearTimeout(exitTimer);
        exitTimer = setTimeout(() => process.exit(0), 500);
      }
    }
  }
});
process.stdin.on("end", () => process.exit(0));
setInterval(() => {}, 1 << 30);
EOF
  chmod +x "$1/codex"
}

# ── Helper: drive initialize + tools/list(id:2) at the stub under MCP_STUB_TLMODE ──
# and assert a jq predicate over the wrapper's stdout (plus an optional byte-for-byte grep).
#   $1 label, $2 stub mode, $3 jq predicate, $4 optional grep -F string
test_codex_toolslist_rewrite() {
  local label="$1" mode="$2" predicate="$3" grep_str="${4:-}"
  local tmpdir output_file status RESPONSE ok
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  output_file="$tmpdir/out.txt"
  write_codex_toolslist_stub "$tmpdir"
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    # Keep stdin open until the response this helper asserts has actually
    # crossed the transport; fixed sleeps make startup load an unrelated cause
    # of failure for every framing mode routed through this helper.
    for _ in $(seq 1 200); do
      grep -Fq '"id":2,' "$output_file" 2>/dev/null && break
      sleep 0.05
    done
  } | PATH="$tmpdir:$PATH" MCP_STUB_TLMODE="$mode" \
    $TIMEOUT_CMD 12 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  ok=1
  [ "$status" -eq 0 ] || ok=0
  echo "$RESPONSE" | jq -e "$predicate" >/dev/null 2>&1 || ok=0
  if [ -n "$grep_str" ]; then printf '%s' "$RESPONSE" | grep -Fq "$grep_str" || ok=0; fi
  if [ "$ok" -eq 1 ]; then green "PASS: $label"; PASS=$((PASS + 1)); else
    red "FAIL: $label (status=$status)"; echo "  Response: $RESPONSE"; FAIL=$((FAIL + 1)); fi
  rm -rf "$tmpdir"
}

# ── Helper: a stub that parks a `codex` call in flight ──────────────────────
# Answers initialize/tools/list, then for tools/call name=codex emits one
# codex/event (so the wrapper learns the thread) and NEVER responds — the shape
# of a long build, which is exactly when codex-peek has to answer.
write_codex_inflight_stub() {
  cat >"$1/codex" <<'EOF'
#!/usr/bin/env node
if (process.argv[2] === "--version") { process.stdout.write("codex-cli 0.145.0\n"); process.exit(0); }
require("fs").appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${process.pid}\n`);
const send = (o) => process.stdout.write(`${JSON.stringify(o)}\n`);
let buf = "";
process.stdin.on("data", (chunk) => {
  buf += chunk;
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl); buf = buf.slice(nl + 1);
    if (!line.trim()) continue;
    let msg; try { msg = JSON.parse(line); } catch { continue; }
    if (msg.method === "initialize") {
      send({ jsonrpc: "2.0", id: msg.id, result: { protocolVersion: "2024-11-05", capabilities: {}, serverInfo: { name: "codex", version: "0" } } });
    } else if (msg.method === "tools/list") {
      send({ jsonrpc: "2.0", id: msg.id, result: { tools: [
        { name: "codex", description: "Run a Codex session.", inputSchema: { type: "object", required: ["prompt"], properties: { prompt: { type: "string" }, cwd: { type: "string" }, sandbox: { type: "string" } } } },
        { name: "codex-reply", description: "Continue a Codex session.", inputSchema: { type: "object", required: ["prompt"], properties: { prompt: { type: "string" }, threadId: { type: "string" } } } },
      ] } });
    } else if (msg.method === "tools/call" && msg.params &&
               (msg.params.name === "codex" || msg.params.name === "codex-reply")) {
      // One event, correlated, then silence: the turn stays in flight. A reply carries
      // the thread it continues, which is how the wrapper recovers its workspace.
      const thread = (msg.params.arguments && msg.params.arguments.threadId) ||
        "0199aaaa-bbbb-cccc-dddd-eeeeffff0000";
      send({ jsonrpc: "2.0", method: "codex/event", params: { _meta: { requestId: msg.id, threadId: thread }, msg: { type: "task_started" } } });
    }
  }
});
process.stdin.on("end", () => process.exit(0));
EOF
  chmod +x "$1/codex"
}

# ── Helper: park a codex turn, then assert a jq predicate over a codex-peek ──
#   $1 label, $2 peek arguments (JSON object), $3 jq predicate over the id:4 result
test_codex_peek() {
  local label="$1" peek_args="$2" predicate="$3"
  local tmpdir output_file status RESPONSE ok
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  output_file="$tmpdir/out.txt"
  write_codex_inflight_stub "$tmpdir"
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    sleep 0.5
    printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"codex","arguments":{"prompt":"build it","cwd":"/tmp/peek-workspace","sandbox":"workspace-write"}}}'
    sleep 2
    printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"codex-peek\",\"arguments\":$peek_args}}"
    sleep 1.2
  } | PATH="$tmpdir:$PATH" $TIMEOUT_CMD 15 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  ok=1
  [ "$status" -eq 0 ] || ok=0
  echo "$RESPONSE" | jq -e "$predicate" >/dev/null 2>&1 || ok=0
  if [ "$ok" -eq 1 ]; then green "PASS: $label"; PASS=$((PASS + 1)); else
    red "FAIL: $label (status=$status)"; echo "  Response: $RESPONSE"; FAIL=$((FAIL + 1)); fi
  rm -rf "$tmpdir"
}

# ── Helper: park a codex turn, then a codex-reply on the SAME thread, then peek ──
# The reply carries no cwd, so its workspace can only come from the thread map — the
# bookkeeping this feature added, and the part a fresh-turn-only test cannot reach.
#   $1 label, $2 jq predicate over the id:5 result
test_codex_peek_reply() {
  local label="$1" predicate="$2"
  local tmpdir output_file status RESPONSE ok
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  output_file="$tmpdir/out.txt"
  write_codex_inflight_stub "$tmpdir"
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    sleep 0.5
    printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"codex","arguments":{"prompt":"build it","cwd":"/tmp/peek-workspace","sandbox":"workspace-write"}}}'
    sleep 0.8
    printf '%s\n' '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"codex-reply","arguments":{"prompt":"carry on","threadId":"0199aaaa-bbbb-cccc-dddd-eeeeffff0000"}}}'
    sleep 0.8
    printf '%s\n' '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"codex-peek","arguments":{}}}'
    sleep 1.2
  } | PATH="$tmpdir:$PATH" $TIMEOUT_CMD 18 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  ok=1
  [ "$status" -ne 0 ] && ok=0
  echo "$RESPONSE" | jq -e "$predicate" >/dev/null 2>&1 || ok=0
  if [ "$ok" -eq 1 ]; then green "PASS: $label"; PASS=$((PASS + 1)); else
    red "FAIL: $label (status=$status)"; echo "  Response: $RESPONSE"; FAIL=$((FAIL + 1)); fi
  rm -rf "$tmpdir"
}

# ── Helper: dispatch a BACKGROUND job, then peek ────────────────────────────
# A job's native request runs under the wrapper's private id namespace; the row must
# be addressed by jobId and must not hand that private id out.
#   $1 label, $2 jq predicate over the id:4 result
test_codex_peek_job() {
  local label="$1" predicate="$2"
  local tmpdir output_file status RESPONSE ok
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  output_file="$tmpdir/out.txt"
  write_codex_inflight_stub "$tmpdir"
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    sleep 0.5
    printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"codex-start","arguments":{"prompt":"build it","cwd":"/tmp/job-workspace","sandbox":"workspace-write"}}}'
    sleep 1.0
    printf '%s\n' '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"codex-peek","arguments":{}}}'
    sleep 1.2
  } | PATH="$tmpdir:$PATH" $TIMEOUT_CMD 18 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  ok=1
  [ "$status" -ne 0 ] && ok=0
  echo "$RESPONSE" | jq -e "$predicate" >/dev/null 2>&1 || ok=0
  if [ "$ok" -eq 1 ]; then green "PASS: $label"; PASS=$((PASS + 1)); else
    red "FAIL: $label (status=$status)"; echo "  Response: $RESPONSE"; FAIL=$((FAIL + 1)); fi
  rm -rf "$tmpdir"
}

# ── Helper: two tools/list calls (id:2, id:3) in one session — both rewritten ──
# (latch re-entry).
test_codex_toolslist_reentry() {
  local label="$1" tmpdir output_file status RESPONSE ok
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  output_file="$tmpdir/out.txt"
  write_codex_toolslist_stub "$tmpdir"
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    sleep 0.2
    printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}'
    sleep 1
  } | PATH="$tmpdir:$PATH" MCP_STUB_TLMODE="normal" \
    $TIMEOUT_CMD 12 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e
  RESPONSE=$(cat "$output_file")
  ok=1
  [ "$status" -eq 0 ] || ok=0
  echo "$RESPONSE" | jq -e 'select(.id==2) | (.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal.type=="string")' >/dev/null 2>&1 || ok=0
  echo "$RESPONSE" | jq -e 'select(.id==3) | (.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal.type=="string")' >/dev/null 2>&1 || ok=0
  if [ "$ok" -eq 1 ]; then green "PASS: $label"; PASS=$((PASS + 1)); else
    red "FAIL: $label (status=$status)"; echo "  Response: $RESPONSE"; FAIL=$((FAIL + 1)); fi
  rm -rf "$tmpdir"
}

# ── Helper: backpressure regression (Finding 1). A node driver pauses reading ──
# the wrapper's stdout so a large stub burst backpressures it, then resumes and
# asserts BOTH tools/list results survive (no complete frame stranded).
test_codex_toolslist_backpressure() {
  local label="$1" tmpdir status out
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  write_codex_toolslist_stub "$tmpdir"
  cat >"$tmpdir/driver.mjs" <<'EOF'
import { spawn } from "node:child_process";
const stubDir = process.argv[2], serverDir = process.argv[3];
const child = spawn("node", ["server.js", "--provider", "codex"], {
  cwd: serverDir,
  env: { ...process.env, PATH: stubDir + ":" + process.env.PATH, MCP_STUB_TLMODE: "bp" },
  stdio: ["pipe", "pipe", "pipe"],
});
let out = "";
let err = "";
child.stdout.pause();                                   // induce backpressure: stop reading
child.stdout.on("data", (d) => { out += d.toString(); });
child.stdin.on("error", () => {});
child.stderr.on("data", (data) => { err += data.toString(); });
const send = (o) => { try { child.stdin.write(JSON.stringify(o) + "\n"); } catch {} };
send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "t", version: "0" } } });
setTimeout(() => send({ jsonrpc: "2.0", method: "notifications/initialized" }), 120);
setTimeout(() => { send({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} }); send({ jsonrpc: "2.0", id: 3, method: "tools/list", params: {} }); }, 240);
setTimeout(() => child.stdout.resume(), 800);           // stay paused while the stub bursts -> backpressure
setTimeout(() => {
  let ok2 = false, ok3 = false;
  for (const line of out.split("\n")) {
    if (!line.trim()) continue;
    let m; try { m = JSON.parse(line); } catch { continue; }
    const hasGoal = m.result?.tools?.find((t) => t.name === "codex")?.inputSchema?.properties?.goal?.type === "string";
    if (m.id === 2 && hasGoal) ok2 = true;
    if (m.id === 3 && hasGoal) ok3 = true;
  }
  const ok = ok2 && ok3;
  process.stdout.write(ok ? "BP_OK\n" : `BP_FAIL ok2=${ok2} ok3=${ok3}\n`);
  child.once("close", () => process.exit(ok ? 0 : 1));
  try { child.stdin.end(); } catch {}
  setTimeout(() => { try { child.kill("SIGTERM"); } catch {} }, 1000);
}, 1800);
process.once("SIGTERM", () => {
  child.once("close", () => process.exit(124));
  try { child.kill("SIGTERM"); } catch {}
});
EOF
  set +e
  out=$($TIMEOUT_CMD 15 node "$tmpdir/driver.mjs" "$tmpdir" "$(pwd)" 2>/dev/null)
  status=$?
  set -e
  if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -Fq "BP_OK"; then
    green "PASS: $label"; PASS=$((PASS + 1)); else
    red "FAIL: $label (status=$status, out=$out)"; FAIL=$((FAIL + 1)); fi
  rm -rf "$tmpdir"
}

# ── Helper: like test_codex_toolslist_rewrite but reads the captured FILE ──
# tolerates an unparseable trailing partial or a multi-MB frame: it extracts the
# id:2 result line for jq and greps the file for a marker.
#   $1 label, $2 mode, $3 jq predicate over the id:2 result line, $4 grep -F marker
test_codex_toolslist_file() {
  local label="$1" mode="$2" predicate="$3" grep_str="$4"
  local tmpdir output_file status idline ok
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  output_file="$tmpdir/out.txt"
  write_codex_toolslist_stub "$tmpdir"
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    # The oversized mode writes more than 10 MiB before id 2. Polling for the
    # actual response boundary makes stdin lifetime depend on transport output,
    # not scheduler luck while a busy host drains that burst.
    for _ in $(seq 1 200); do
      grep -Fq '"id":2,' "$output_file" 2>/dev/null && break
      sleep 0.05
    done
  } | PATH="$tmpdir:$PATH" MCP_STUB_TLMODE="$mode" \
    $TIMEOUT_CMD 25 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e
  ok=1
  [ "$status" -eq 0 ] || ok=0
  idline=$(grep -F '"id":2,' "$output_file" 2>/dev/null | tail -1)
  printf '%s' "$idline" | jq -e "$predicate" >/dev/null 2>&1 || ok=0
  if [ -n "$grep_str" ]; then grep -Fq "$grep_str" "$output_file" || ok=0; fi
  if [ "$ok" -eq 1 ]; then green "PASS: $label"; PASS=$((PASS + 1)); else
    red "FAIL: $label (status=$status)"; echo "  idline: ${idline:0:200}"; FAIL=$((FAIL + 1)); fi
  rm -rf "$tmpdir"
}

# ── Helper: cancel a tools/list while a NON-tools/list partial is withheld in ──
# buffer mode, then let codex die — the partial must be forwarded raw on the
# cancel (return-to-raw), not byte-lost at finalize.
test_codex_toolslist_cancel() {
  local label="$1" tmpdir output_file status ok
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  output_file="$tmpdir/out.txt"
  write_codex_toolslist_stub "$tmpdir"
  set +e
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    sleep 0.3
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    sleep 0.4
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}'
    # Cancellation is supposed to flush the withheld partial immediately. Keep
    # stdin open until that observable marker arrives so process startup load
    # cannot turn this into an unrelated early-EOF failure.
    for _ in $(seq 1 160); do
      grep -Fq "CANCEL_PARTIAL" "$output_file" 2>/dev/null && break
      sleep 0.05
    done
  } | PATH="$tmpdir:$PATH" MCP_STUB_TLMODE="cancelpartial" \
    $TIMEOUT_CMD 12 $SERVER --provider codex >"$output_file" 2>/dev/null
  status=$?
  set -e
  ok=1
  [ "$status" -eq 0 ] || ok=0
  grep -Fq "CANCEL_PARTIAL" "$output_file" || ok=0
  if [ "$ok" -eq 1 ]; then green "PASS: $label"; PASS=$((PASS + 1)); else
    red "FAIL: $label (status=$status)"; echo "  out: $(cat "$output_file")"; FAIL=$((FAIL + 1)); fi
  rm -rf "$tmpdir"
}

# ── Helper: Codex lifecycle stub for per-request liveness/recovery tests. ──
write_codex_lifecycle_stub() {
  cat >"$1/codex" <<'EOF'
#!/usr/bin/env node
if (process.argv[2] === "--version") { process.stdout.write(`${process.env.MCP_STUB_CODEX_VERSION || "codex-cli 0.145.0"}\n`); process.exit(0); }
const fs = require("fs");
const mode = process.env.MCP_STUB_LIFECYCLE_MODE;
fs.appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${process.pid}\n`);
fs.writeFileSync(process.env.MCP_AGENTS_TEST_PID_FILE, String(process.pid));

const timers = [];
const threadId = (id) => typeof id === "number"
  ? `00000000-0000-4000-8000-${String(id).padStart(12, "0")}`
  : "00000000-0000-4000-8000-999999999999";
const send = (message, callback) => process.stdout.write(`${JSON.stringify(message)}\n`, callback);
const eventMessage = (requestId, type, extra = {}) => ({
  jsonrpc: "2.0",
  method: "codex/event",
  params: {
    _meta: { requestId, threadId: threadId(requestId) },
    id: `event-${requestId}-${type}`,
    msg: { type, ...extra },
  },
});
const event = (requestId, type, extra = {}, callback) =>
  send(eventMessage(requestId, type, extra), callback);
const resultMessage = (id, content) => ({
  jsonrpc: "2.0",
  id,
  result: {
    content: [{ type: "text", text: content }],
    structuredContent: { threadId: threadId(id), content },
  },
});
const result = (id, content) => send(resultMessage(id, content));
const authFailureMessage =
  "Your access token could not be refreshed because your refresh token was revoked. " +
  "Please log out and sign in again.";
const authFailureEvent = (requestId) => eventMessage(requestId, "error", {
  message: authFailureMessage,
  codex_error_info: "unauthorized",
});
const authFailureResult = (id) => ({
  jsonrpc: "2.0",
  id,
  result: {
    isError: true,
    content: [{ type: "text", text: authFailureMessage }],
    structuredContent: { threadId: threadId(id), content: authFailureMessage },
  },
});
const later = (delay, fn) => timers.push(setTimeout(fn, delay));
const every = (delay, fn) => timers.push(setInterval(fn, delay));

function startCall(id, prompt) {
  if (mode !== "asyncwaitcancel") {
    event(id, "session_configured", { thread_id: threadId(id) });
  }
  switch (mode) {
    case "stderr":
      every(30, () => process.stderr.write("still noisy\n"));
      break;
    case "authfailure":
    case "asyncauthfailure":
      // Codex 0.147 validates refresh_token_invalidated internally and emits a
      // typed, correlated unauthorized event followed by an isError tool result.
      // Coalesce both frames to prove the wrapper catches them before forwarding.
      later(30, () => {
        if (process.env.MCP_AGENTS_TEST_MUTATE_ISOLATED_AUTH === "1") {
          fs.writeFileSync(`${process.env.CODEX_HOME}/auth.json`, '{"token":"known-invalidated"}');
        }
        process.stdout.write(
          `${JSON.stringify(authFailureEvent(id))}\n${JSON.stringify(authFailureResult(id))}\n`,
        );
      });
      break;
    case "authconcurrent":
      if (id === 2) {
        later(30, () => process.stdout.write(
          `${JSON.stringify(authFailureEvent(id))}\n${JSON.stringify(authFailureResult(id))}\n`,
        ));
      } else {
        later(120, () => result(id, "ALREADY_RUNNING_SURVIVED"));
      }
      break;
    case "authtextsuccess":
      later(30, () => result(id, `ordinary output mentions: ${authFailureMessage}`));
      break;
    case "authunterminatedexit":
      later(30, () => process.stdout.write(
        `${JSON.stringify(authFailureEvent(id))}\n${JSON.stringify(authFailureResult(id))}`,
        () => process.exit(0),
      ));
      break;
    case "authcancelunterminatedexit":
      // The client has already canceled and the bridge has settled this id into
      // late-response suppression before Codex reports the auth failure. Exit
      // without a delimiter to exercise finalize's correlated-event path.
      later(220, () => {
        if (process.env.MCP_AGENTS_TEST_MUTATE_ISOLATED_AUTH === "1") {
          fs.writeFileSync(`${process.env.CODEX_HOME}/auth.json`, '{"token":"known-invalidated"}');
        }
        process.stdout.write(JSON.stringify(authFailureEvent(id)), () => process.exit(0));
      });
      break;
    case "unrelated":
      every(30, () => event(999, "agent_message_content_delta", { delta: "noise" }));
      break;
    case "survive":
      // id 2 stalls (idles out); a later id 3 must still get a real result,
      // proving the transport survived the first call's per-request timeout.
      if (id === 3) later(20, () => result(id, "SURVIVED"));
      break;
    case "gracehang": {
      // Enter terminal grace via task_complete, then leave a partial
      // (unterminated) frame and go silent forever. synthesizeTerminalResult must
      // then defer (no safe boundary) and beginTerminalGrace clears idleTimer —
      // so ONLY the immutable hard deadline can bound this call. It must fire a
      // bounded teardown at the hard deadline, never silently no-op and hang.
      const partial = JSON.stringify(eventMessage(id, "warning", { message: "SAFE" }));
      process.stdout.write(
        `${JSON.stringify(eventMessage(id, "task_complete", { last_agent_message: "GRACE" }))}\n${partial.slice(0, partial.length - 5)}`,
      );
      break;
    }
    case "flushstall":
      // id 2 idles out at ~300ms and is CLEANLY suppressed (buffer mode latches
      // while lastForwardedByteWasNewline is still true). Only THEN (350ms) do we
      // leave a partial, unterminated native frame that never completes and never
      // exits — canInjectGeneratedFrame() stays false forever, so the local
      // codex-status response the driver queues later can never flush. The
      // session-level delivery backstop must escalate to a bounded teardown.
      later(350, () => process.stdout.write(
        '{"jsonrpc":"2.0","method":"codex/event","params":{"msg":"STUCK_PARTIAL"',
      ));
      break;
    case "progressstall":
      // Start progress (so armProgressWait emits "still running" heartbeats with
      // idle disabled), then leave a partial, unterminated frame and freeze. Each
      // heartbeat queues a progress frame that cannot flush. With IN-PLACE progress
      // coalescing the flush-stall backstop's arm time survives every heartbeat and
      // it fires; a remove-then-push coalesce would reset it each heartbeat and the
      // wedged request would never be bounded by the backstop.
      event(id, "task_started");
      later(200, () => process.stdout.write(
        '{"jsonrpc":"2.0","method":"codex/event","params":{"msg":"STUCK_PROGRESS"',
      ));
      break;
    case "gracesafe":
      // Clean terminal event early → terminal_grace with CLEAN framing. With a hard
      // deadline shorter than the terminal grace, hardTimer fires while still in
      // terminal_grace. armEntryHard must then settle it via synthesizeTerminalResult
      // (safe, no teardown) rather than finalize()-ing the whole bridge — proven by
      // the transport surviving to answer a follow-up call (id 3).
      later(40, () => event(id, "task_complete", { last_agent_message: "DONE" }));
      break;
    case "progress":
      event(id, "item_started", { item: { type: "AgentMessage", id: `commentary-${id}`, phase: "commentary" } });
      for (const delay of [100, 200, 300, 400, 500, 600, 700]) {
        later(delay, () => event(id, "agent_message_content_delta", { item_id: `commentary-${id}`, delta: "." }));
      }
      later(780, () => result(id, `PROGRESS_${id}`));
      break;
    case "tokens":
      event(id, "task_started");
      later(100, () => result(id, `TOKEN_${id}`));
      break;
    case "visibility": {
      event(id, "item_started", { item: { type: "AgentMessage", id: "commentary-safe", phase: "commentary" } });
      later(20, () => event(id, "agent_message_content_delta", { item_id: "commentary-safe", delta: "Working\n on \u0000 tests 🚀" }));
      later(40, () => event(id, "item_started", { item: { type: "AgentMessage", id: "final-secret", phase: "final_answer" } }));
      later(50, () => event(id, "agent_message_content_delta", { item_id: "final-secret", delta: "SENTINEL_FINAL" }));
      later(60, () => event(id, "agent_message_content_delta", { item_id: "unknown", delta: "SENTINEL_UNKNOWN" }));
      later(70, () => event(id, "agent_message", { phase: "final_answer", message: "SENTINEL_FINAL_COMPLETE" }));
      later(80, () => event(id, "agent_message", { message: "SENTINEL_PHASELESS" }));
      later(90, () => event(id, "item_started", { item: { type: "agent_message", id: "wrong-case", phase: "commentary" } }));
      later(95, () => event(id, "agent_message_content_delta", { item_id: "wrong-case", delta: "SENTINEL_WRONG_TYPE" }));
      later(100, () => event(id, "plan_update", { plan: [{ step: "Verify bridge", status: "in_progress" }] }));
      later(150, () => event(id, "exec_command_begin", { command: "SENTINEL_COMMAND" }));
      later(200, () => event(id, "exec_command_end", { exit_code: 7, output: "SENTINEL_OUTPUT" }));
      later(250, () => event(id, "patch_apply_begin", { changes: { "/SENTINEL_PATH_A": {}, "/SENTINEL_PATH_B": {} } }));
      later(300, () => event(id, "mcp_tool_call_begin", { invocation: { server: "safe-server", tool: "safe-tool", arguments: { secret: "SENTINEL_ARGUMENT" } } }));
      later(350, () => event(id, "web_search_end", { query: "SENTINEL_QUERY" }));
      later(400, () => event(id, "raw_response_item", { prompt: "SENTINEL_PROMPT", reasoning: "SENTINEL_REASONING" }));
      later(420, () => event(id, "item_completed", { item: { type: "AgentMessage", id: "completed-safe", phase: "commentary", content: [{ type: "Text", text: "Completed commentary" }] } }));
      later(440, () => event(id, "item_completed", { item: { type: "AgentMessage", id: "completed-final", phase: "final_answer", content: [{ type: "Text", text: "SENTINEL_COMPLETED_FINAL" }] } }));
      later(470, () => event(id, "agent_message", { phase: "commentary", message: "🚀".repeat(250) }));
      later(505, () => event(id, "sub_agent_activity", { agent_id: "SENTINEL_AGENT", detail: "SENTINEL_ACTIVITY" }));
      later(550, () => result(id, "VISIBLE"));
      break;
    }
    case "coalesce":
      event(id, "task_started");
      later(10, () => event(id, "exec_command_begin", { command: "SENTINEL_COALESCE" }));
      later(20, () => event(id, "plan_update", { plan: [{ step: "Old status", status: "in_progress" }] }));
      later(30, () => event(id, "plan_update", { plan: [{ step: "Latest status", status: "in_progress" }] }));
      later(40, () => event(id, "plan_update", { plan: [{ step: "Latest status", status: "in_progress" }] }));
      later(140, () => result(id, "COALESCED"));
      break;
    case "async":
      event(id, "item_started", { item: { type: "AgentMessage", id: `async-commentary-${id}`, phase: "commentary" } });
      later(30, () => event(id, "agent_message_content_delta", { item_id: `async-commentary-${id}`, delta: "Inspecting the " }));
      later(80, () => event(id, "agent_message_content_delta", { item_id: `async-commentary-${id}`, delta: "bridge 🚀\n" }));
      later(120, () => event(id, "item_completed", { item: { type: "AgentMessage", id: `async-commentary-${id}`, phase: "commentary", content: [{ type: "Text", text: "Inspecting the bridge 🚀\n" }] } }));
      later(150, () => event(id, "plan_update", { plan: [{ step: "Finish async verification", status: "in_progress" }] }));
      later(260, () => result(id, "ASYNC_RESULT"));
      break;
    case "asyncfallback":
      event(id, "agent_message", { phase: "commentary", message: "Fallback commentary" });
      later(80, () => event(id, "task_complete", { last_agent_message: "FALLBACK_RESULT" }));
      later(260, () => result(id, "LATE_PRIVATE_RESULT"));
      break;
    case "asyncabort":
      event(id, "task_started");
      later(40, () => event(id, "turn_aborted", { last_agent_message: "MUST_NOT_SUCCEED" }));
      break;
    case "asyncabortnative":
      event(id, "task_started");
      later(40, () => event(id, "turn_aborted", { last_agent_message: "MUST_NOT_SUCCEED" }));
      later(60, () => result(id, "MUST_NOT_COMPLETE_AFTER_ABORT"));
      break;
    case "asyncabortexit":
      event(id, "task_started");
      later(40, () => event(
        id,
        "turn_aborted",
        { last_agent_message: "MUST_NOT_SUCCEED" },
        () => process.exit(0),
      ));
      break;
    case "asyncabortcancel":
      event(id, "task_started");
      later(30, () => event(id, "turn_aborted"));
      break;
    case "asynccancel":
      event(id, "task_started");
      later(30, () => event(id, "agent_message", { phase: "commentary", message: "Waiting for cancellation" }));
      break;
    case "asynccancelabort":
      event(id, "task_started");
      later(50, () => event(id, "turn_aborted"));
      break;
    case "asynccancelcomplete":
      event(id, "task_started");
      later(50, () => event(id, "task_complete", { last_agent_message: "COMPLETE_BUILD" }));
      break;
    case "asyncprivacy":
      event(id, "item_started", { item: { type: "AgentMessage", id: `private-safe-${id}`, phase: "commentary" } });
      later(30, () => event(id, "agent_message_content_delta", { item_id: `private-safe-${id}`, delta: "Safe\u0000\ncommentary\u202e" }));
      later(60, () => event(id, "item_started", { item: { type: "AgentMessage", id: `private-final-${id}`, phase: "final_answer" } }));
      later(70, () => event(id, "agent_message_content_delta", { item_id: `private-final-${id}`, delta: "SENTINEL_FINAL" }));
      later(80, () => event(id, "raw_response_item", { prompt: "SENTINEL_PROMPT", reasoning: "SENTINEL_REASONING" }));
      later(90, () => event(id, "exec_command_end", { output: "SENTINEL_OUTPUT", exit_code: 0 }));
      later(100, () => event(id, "item_completed", { item: { type: "AgentMessage", id: `private-safe-${id}`, phase: "commentary", content: [{ type: "Text", text: "Safe\ncommentary" }] } }));
      later(110, () => event(id, "agent_message", { phase: "commentary", message: "SENTINEL_DUPLICATE_CHANNEL" }));
      later(220, () => result(id, "PRIVACY_RESULT"));
      break;
    case "asynctruncate":
      event(id, "item_started", { item: { type: "AgentMessage", id: `truncate-${id}`, phase: "commentary" } });
      later(30, () => event(id, "agent_message_content_delta", { item_id: `truncate-${id}`, delta: "0123456789".repeat(20) }));
      later(100, () => event(id, "item_completed", { item: { type: "AgentMessage", id: `truncate-${id}`, phase: "commentary", content: [{ type: "Text", text: "0123456789".repeat(20) }] } }));
      later(220, () => result(id, "TRUNCATE_RESULT"));
      break;
    case "asyncpage":
      event(id, "task_started");
      later(120, () => result(id, "R".repeat(32780)));
      break;
    case "asyncoversize":
      event(id, "task_started");
      later(120, () => result(id, "O".repeat((10 * 1024 * 1024) + 1024)));
      break;
    case "asyncconcurrent":
      if (typeof id === "string") {
        event(id, "agent_message", { phase: "commentary", message: "Background is active" });
        later(300, () => result(id, "BACKGROUND_RESULT"));
      } else {
        event(id, "task_started");
        later(80, () => result(id, "BLOCKING_RESULT"));
      }
      break;
    case "asyncwaitcancel":
      later(180, () => event(id, "task_started"));
      later(320, () => result(id, "WAIT_CANCEL_RESULT"));
      break;
    case "wait":
      later(650, () => event(id, "unknown_activity", { secret: "SENTINEL_WAIT" }));
      break;
    case "partial":
    case "partialstall": {
      const partial = JSON.stringify(eventMessage(id, "warning", { message: "SAFE" }));
      const splitAt = partial.length - 5;
      process.stdout.write(`${JSON.stringify(eventMessage(id, "task_started"))}\n${partial.slice(0, splitAt)}`);
      if (mode === "partial") {
        later(220, () => process.stdout.write(`${partial.slice(splitAt)}\n`));
        later(360, () => result(id, "PARTIAL"));
      }
      break;
    }
    case "settled":
      event(id, "task_started");
      later(40, () => result(id, "SETTLED"));
      later(120, () => event(id, "exec_command_begin", { command: "SENTINEL_LATE" }));
      break;
    case "terminalstop":
      event(id, "task_started");
      later(30, () => event(id, "task_complete", { last_agent_message: "DONE" }));
      later(100, () => event(id, "exec_command_begin", { command: "SENTINEL_TERMINAL" }));
      break;
    case "terminal":
      later(40, () => event(id, "task_complete", { last_agent_message: "DONE" }));
      break;
    case "suppressioncap":
      later(20, () => event(id, "task_complete", { last_agent_message: `DONE_${id}` }));
      break;
    case "aborted":
      later(40, () => event(id, "turn_aborted", { last_agent_message: "MUST_NOT_SUCCEED" }));
      break;
    case "terminalexit":
      later(40, () => event(id, "task_complete", { last_agent_message: "DONE" }, () => process.exit(0)));
      break;
    case "abortedexit":
      later(40, () => event(id, "turn_aborted", { last_agent_message: "MUST_NOT_SUCCEED" }, () => process.exit(0)));
      break;
    case "native":
      later(40, () => event(id, "turn_complete", { last_agent_message: "DONE" }));
      later(80, () => result(id, "NATIVE"));
      break;
    case "nativeabort":
      later(40, () => event(id, "turn_aborted"));
      later(80, () => result(id, "NATIVE_AFTER_ABORT"));
      break;
    case "late":
      later(40, () => event(id, "task_complete", { last_agent_message: "DONE" }));
      later(220, () => result(id, "LATE"));
      break;
    case "reuse":
      later(40, () => event(id, "task_complete", { last_agent_message: "DONE" }));
      later(300, () => result(id, "LATE"));
      break;
    case "hard":
      event(id, "task_started");
      every(30, () => event(id, "exec_command_begin", { command: "SENTINEL_HARD" }));
      break;
    case "cancel":
      event(id, "task_started");
      every(30, () => event(id, "exec_command_begin", { command: "SENTINEL_CANCEL" }));
      break;
    case "cancelconfirmedlate": {
      if (id !== 2) {
        later(20, () => result(id, "SURVIVED_CONFIRMED_CANCEL"));
        break;
      }
      event(id, "task_started");
      const before = JSON.stringify(eventMessage(id, "warning", { message: "BEFORE_CONFIRM" }));
      const beforeSplit = before.length - 5;
      const after = JSON.stringify(eventMessage(id, "warning", { message: "AFTER_CONFIRM" }));
      const afterSplit = after.length - 5;
      later(100, () => process.stdout.write(before.slice(0, beforeSplit)));
      later(180, () => process.stdout.write(
        `${before.slice(beforeSplit)}\n${JSON.stringify(eventMessage(id, "turn_aborted"))}\n${after.slice(0, afterSplit)}`,
      ));
      later(230, () => process.stdout.write(`${after.slice(afterSplit)}\n`));
      break;
    }
    case "cancelconfirmedwedge": {
      event(id, "task_started");
      const before = JSON.stringify(eventMessage(id, "warning", { message: "BEFORE_WEDGED_CONFIRM" }));
      const beforeSplit = before.length - 5;
      const after = JSON.stringify(eventMessage(id, "warning", { message: "AFTER_WEDGED_CONFIRM" }));
      const afterSplit = after.length - 5;
      // Cancellation arrives while `before` is partial. Its first grace expires
      // before this chunk supplies a boundary and the abort acknowledgement, then
      // `after` keeps the stream wedged through the confirmation-specific grace.
      later(40, () => process.stdout.write(before.slice(0, beforeSplit)));
      later(180, () => process.stdout.write(
        `${before.slice(beforeSplit)}\n${JSON.stringify(eventMessage(id, "turn_aborted"))}\n` +
        after.slice(0, afterSplit),
      ));
      break;
    }
    case "canceldoubleterminal": {
      if (id !== 2) {
        later(20, () => result(id, "SURVIVED_DOUBLE_TERMINAL"));
        break;
      }
      event(id, "task_started");
      const trailing = JSON.stringify(eventMessage(id, "warning", { message: "AFTER_TERMINALS" }));
      const splitAt = trailing.length - 5;
      later(80, () => process.stdout.write(
        `${JSON.stringify(eventMessage(id, "task_complete"))}\n` +
        `${JSON.stringify(eventMessage(id, "turn_complete"))}\n${trailing.slice(0, splitAt)}`,
      ));
      later(130, () => process.stdout.write(`${trailing.slice(splitAt)}\n`));
      break;
    }
    case "cancelcoalesced":
      if (prompt === "REUSED") {
        later(20, () => result(id, "REUSED_AFTER_COALESCED_CANCEL"));
        break;
      }
      event(id, "task_started");
      later(80, () => process.stdout.write(
        `${JSON.stringify(eventMessage(id, "turn_aborted"))}\n` +
        `${JSON.stringify(resultMessage(id, "SUPPRESSED_NATIVE_CANCEL_RESULT"))}\n`,
      ));
      break;
    case "cancelcoalescedunsafe": {
      if (prompt === "REUSED") {
        later(20, () => result(id, "REUSED_AFTER_UNSAFE_CANCEL"));
        break;
      }
      event(id, "task_started");
      const partial = JSON.stringify(eventMessage(id, "warning", { message: "MID_FRAME_CANCEL" }));
      const splitAt = partial.length - 5;
      later(40, () => process.stdout.write(partial.slice(0, splitAt)));
      later(80, () => process.stdout.write(
        `${partial.slice(splitAt)}\n${JSON.stringify(eventMessage(id, "turn_aborted"))}\n` +
        `${JSON.stringify(resultMessage(id, "ALREADY_FORWARDED_CANCEL_RESULT"))}\n`,
      ));
      break;
    }
    case "clientgone":
      // Keeps working forever and deliberately ignores stdin EOF, standing in
      // for a codex mid-turn that does not wind down when the client vanishes.
      event(id, "task_started");
      every(30, () => event(id, "exec_command_begin", { command: "SENTINEL_GONE" }));
      break;
  }
}

let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (data) => {
  buf += data;
  let newline;
  while ((newline = buf.indexOf("\n")) !== -1) {
    const line = buf.slice(0, newline); buf = buf.slice(newline + 1);
    let message; try { message = JSON.parse(line); } catch { continue; }
    if (message.method === "initialize") {
      send({ jsonrpc: "2.0", id: message.id, result: { protocolVersion: "2024-11-05", capabilities: {}, serverInfo: { name: "lifecycle-stub", version: "0" } } });
    } else if (message.method === "tools/call") {
      fs.appendFileSync(process.env.MCP_AGENTS_TEST_CALL_CAPTURE, `${JSON.stringify({ id: message.id, prompt: message.params?.arguments?.prompt })}\n`);
      startCall(message.id, message.params?.arguments?.prompt);
    } else if (message.method === "ping") {
      send({ jsonrpc: "2.0", id: message.id, result: {} });
    }
  }
});
process.stdin.on("end", () => { if (mode !== "clientgone") process.exit(0); });
setInterval(() => {}, 1 << 30);
EOF
  chmod +x "$1/codex"
}

# Drives one lifecycle mode and emits a single JSON summary for jq assertions.
write_codex_lifecycle_driver() {
  cat >"$1/driver.mjs" <<'EOF'
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";

const [stubDir, serverDir, mode, idle, hard, settle, terminal, cancel, progressConfig, flushStall] = process.argv.slice(2);
const [progress, wait = "10000"] = progressConfig.split(",");
const pidFile = `${stubDir}/codex.pid`;
const callFile = `${stubDir}/calls.jsonl`;
const started = Date.now();
const child = spawn("node", ["server.js", "--provider", "codex", "--codex_idle_timeout", idle, "--timeout", hard], {
  cwd: serverDir,
  env: {
    ...process.env,
    PATH: `${stubDir}:${process.env.PATH}`,
    MCP_STUB_LIFECYCLE_MODE: mode,
    MCP_AGENTS_TEST_PID_FILE: pidFile,
    MCP_AGENTS_TEST_CALL_CAPTURE: callFile,
    MCP_AGENTS_CODEX_TERMINAL_GRACE_MS: terminal,
    MCP_AGENTS_CODEX_CANCEL_GRACE_MS: cancel,
    MCP_AGENTS_CODEX_CLIENT_GONE_GRACE_MS: String(Number(cancel) * 2),
    MCP_AGENTS_CODEX_PROGRESS_INTERVAL_MS: progress,
    MCP_AGENTS_CODEX_WAIT_INTERVAL_MS: wait,
    MCP_AGENTS_TEST_TIMER_AUDIT: "1",
    ...(flushStall ? { MCP_AGENTS_CODEX_FLUSH_STALL_MS: flushStall } : {}),
  },
  stdio: ["pipe", "pipe", "pipe"],
});
let out = "";
let err = "";
let parseBuf = "";
let scenarioStarted = false;
let reuseSent = false;
let surviveSent = false;
let bootTimer;
let pingTimer;
let settleTimer;
let fallbackTimer;
child.stdin.on("error", () => {});
child.stderr.on("data", (data) => { err += data.toString(); });
const send = (message) => {
  if (child.stdin.writable) child.stdin.write(`${JSON.stringify(message)}\n`);
};
const call = (id, token, prompt = `call ${id}`) => send({
  jsonrpc: "2.0",
  id,
  method: "tools/call",
  params: {
    name: "codex",
    arguments: {
      prompt,
      cwd: serverDir,
      sandbox: "read-only",
      model_reasoning_effort: "xhigh",
    },
    ...(token === undefined ? {} : { _meta: { progressToken: token } }),
  },
});

const startScenario = () => {
  if (scenarioStarted) return;
  scenarioStarted = true;
  send({ jsonrpc: "2.0", method: "notifications/initialized" });
  if (mode === "progress") {
    call(2);
    call(3, "progress-3");
  } else if (mode === "tokens") {
    call(2, "string-token");
    call(3, 42);
    call(4);
    call(5, { invalid: true });
  } else if (["cancel", "cancelconfirmedlate", "cancelconfirmedwedge", "canceldoubleterminal", "cancelcoalesced", "cancelcoalescedunsafe", "authcancelunterminatedexit"].includes(mode)) {
    call(2, "cancel-2");
    if (mode === "cancel") call(3);
    setTimeout(() => send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 2, reason: "test" } }), 60);
    if (mode === "cancelconfirmedlate") setTimeout(() => call(3), 340);
    if (mode === "canceldoubleterminal") setTimeout(() => call(3), 240);
    if (["cancelcoalesced", "cancelcoalescedunsafe"].includes(mode)) {
      setTimeout(() => call(2, undefined, "REUSED"), 180);
    }
  } else if (mode === "suppressioncap") {
    for (let id = 2; id < 34; id += 1) call(id);
  } else if (mode === "authconcurrent") {
    call(2);
    call(3);
  } else {
    const tokenModes = new Set([
      "hard", "visibility", "coalesce", "wait", "partial", "partialstall", "settled", "terminalstop", "progressstall",
    ]);
    call(2, tokenModes.has(mode) ? `${mode}-2` : undefined);
  }
  if (mode === "unrelated") {
    let pingId = 100;
    pingTimer = setInterval(() => send({ jsonrpc: "2.0", id: pingId++, method: "ping", params: {} }), 30);
  }
  if (mode === "flushstall") {
    // After id 2 is suppressed (~300ms) and the stub's partial jams the buffer
    // (~350ms), poll a bogus job: the local jobNotFound response is queued but
    // can never flush, so the delivery backstop must fire a bounded teardown.
    setTimeout(() => send({
      jsonrpc: "2.0", id: 3, method: "tools/call",
      params: { name: "codex-status", arguments: { jobId: "no-such-job", cursor: 0 } },
    }), 600);
  }
  settleTimer = setTimeout(() => {
    if (pingTimer) clearInterval(pingTimer);
    try { child.stdin.end(); } catch {}
    fallbackTimer = setTimeout(() => { try { child.kill("SIGTERM"); } catch {} }, 500);
  }, Number(settle));
};
child.stdout.on("data", (data) => {
  const chunk = data.toString();
  out += chunk;
  parseBuf += chunk;
  let newline;
  while ((newline = parseBuf.indexOf("\n")) !== -1) {
    const line = parseBuf.slice(0, newline); parseBuf = parseBuf.slice(newline + 1);
    let frame; try { frame = JSON.parse(line); } catch { continue; }
    if (frame.id === 1 && frame.result) startScenario();
    if (mode === "reuse" && frame.id === 2 && frame.result?.structuredContent?.content === "DONE" && !reuseSent) {
      reuseSent = true;
      call(2, undefined, "REUSED");
    }
    // survive: only AFTER id 2's timeout error do we issue id 3, so a passing
    // id-3 result proves the bridge served a new call post-timeout (not before it).
    if (mode === "survive" && frame.id === 2 && frame.error && !surviveSent) {
      surviveSent = true;
      call(3);
    }
    // gracesafe: after id 2's recovered terminal RESULT (settled at the hard
    // deadline without teardown), issue id 3 — a passing id-3 result proves the
    // transport survived (a full teardown would leave id 3 unanswered).
    if (mode === "gracesafe" && frame.id === 2 && frame.result && !surviveSent) {
      surviveSent = true;
      call(3);
    }
    if (mode === "authfailure" && frame.id === 2 && frame.result?.isError && !surviveSent) {
      surviveSent = true;
      call(3);
      send({ jsonrpc: "2.0", id: 100, method: "ping", params: {} });
      send({
        jsonrpc: "2.0",
        id: 101,
        method: "tools/call",
        params: { name: "codex-peek", arguments: {} },
      });
    }
    if (mode === "authconcurrent" && frame.id === 2 && frame.result?.isError && !surviveSent) {
      surviveSent = true;
      call(4);
    }
  }
});
bootTimer = setInterval(() => {
  try { readFileSync(pidFile, "utf8"); } catch { return; }
  clearInterval(bootTimer);
  send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "lifecycle-test", version: "0" } } });
}, 10);

child.once("close", (code, signal) => {
  clearInterval(bootTimer);
  clearTimeout(settleTimer);
  clearTimeout(fallbackTimer);
  if (pingTimer) clearInterval(pingTimer);
  setTimeout(() => {
    let parseErrors = 0;
    const frames = out.split("\n").filter(Boolean).flatMap((line) => {
      try { return [JSON.parse(line)]; } catch { parseErrors += 1; return []; }
    });
    let stubPid = null;
    try { stubPid = Number(readFileSync(pidFile, "utf8")); } catch {}
    let stubAlive = false;
    try { if (stubPid) process.kill(stubPid, 0); stubAlive = Boolean(stubPid); } catch {}
    let calls = [];
    try { calls = readFileSync(callFile, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line)); } catch {}
    const timerAudits = [...err.matchAll(/settled timer count=(\d+)/g)].map((match) => Number(match[1]));
    process.stdout.write(`${JSON.stringify({ code, signal, elapsedMs: Date.now() - started, stubAlive, calls, frames, parseErrors, rawHasProgress: out.includes('"method":"notifications/progress"'), timerAudits, stderr: err })}\n`);
    process.exit(0);
  }, 80);
});

process.once("SIGTERM", () => {
  try { child.kill("SIGTERM"); } catch {}
  setTimeout(() => process.exit(124), 1000);
});
EOF
}

# Drives the wrapper-owned background-job tools against the lifecycle stub.
write_codex_job_driver() {
  cat >"$1/job-driver.mjs" <<'EOF'
import { spawn } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";

const [stubDir, serverDir, mode = "async"] = process.argv.slice(2);
const pidFile = `${stubDir}/codex.pid`;
const callFile = `${stubDir}/calls.jsonl`;
const terminalProbeFile = `${stubDir}/terminal-probe.cjs`;
const terminalProbeOutput = `${stubDir}/terminal-probe.jsonl`;
if (mode === "asyncabortexit") {
  // Teardown intentionally cannot deliver a newly-woken status waiter: the MCP
  // transport is closing. Observe the exact local-response frame at its queue
  // boundary so this test can distinguish the abort-specific terminal message
  // from the generic bridge-stopped sweep that follows it.
  writeFileSync(terminalProbeFile, [
    'const fs = require("node:fs");',
    "const originalBufferFrom = Buffer.from;",
    "let recording = false;",
    "Buffer.from = function(value, ...args) {",
    "  const buffer = Reflect.apply(originalBufferFrom, Buffer, [value, ...args]);",
    "  if (!recording && typeof value === \"string\") {",
    "    try {",
    "      const structured = JSON.parse(value).result?.structuredContent;",
    "      if (structured?.jobId && [\"completed\", \"failed\", \"canceled\"].includes(structured.state)) {",
    "        recording = true;",
    "        fs.appendFileSync(process.env.MCP_AGENTS_TEST_TERMINAL_PROBE, `${JSON.stringify(structured)}\\n`);",
    "        recording = false;",
    "      }",
    "    } catch { recording = false; }",
    "  }",
    "  return buffer;",
    "};",
  ].join("\n"));
}
const child = spawn(
  "node",
  // --codex_status_interval 1.5 (=1500ms) is passed on the CLI while the env var below
  // holds the fast 20ms value: the cursor assertion therefore fails unless the CLI flag
  // both reaches the runtime AND wins over the environment.
  [
    "server.js",
    "--provider",
    "codex",
    "--codex_idle_timeout",
    "2",
    "--timeout",
    "4",
    "--codex_status_interval",
    "1.5",
  ],
  {
    cwd: serverDir,
    env: {
      ...process.env,
      PATH: `${stubDir}:${process.env.PATH}`,
      MCP_STUB_LIFECYCLE_MODE: mode,
      MCP_AGENTS_TEST_PID_FILE: pidFile,
      MCP_AGENTS_TEST_CALL_CAPTURE: callFile,
      MCP_AGENTS_CODEX_TERMINAL_GRACE_MS: "80",
      MCP_AGENTS_CODEX_CANCEL_GRACE_MS: "100",
      MCP_AGENTS_CODEX_PROGRESS_INTERVAL_MS: "20",
      // Deliberately the WRONG (fast) value — the CLI flag above sets 1500ms and must
      // beat it. With the flag effective the cursor stays nearly frozen for the whole
      // run, which also proves lifecycle transitions bypass pacing; if the flag stops
      // reaching the runtime, or stops winning over the environment, this 20ms value
      // takes over, the cursor climbs, and the assertion below fails.
      MCP_AGENTS_CODEX_STATUS_INTERVAL_MS: "20",
      MCP_AGENTS_CODEX_WAIT_INTERVAL_MS: "100",
      MCP_AGENTS_TEST_PRIVATE_PREFIX: "mcp-agents/job/test/",
      ...(mode === "asynctruncate" ? { MCP_AGENTS_TEST_COMMENTARY_BYTES: "64" } : {}),
      ...(mode === "asyncabortexit" ? {
        NODE_OPTIONS: `${process.env.NODE_OPTIONS ?? ""} --require=${terminalProbeFile}`.trim(),
        MCP_AGENTS_TEST_TERMINAL_PROBE: terminalProbeOutput,
      } : {}),
    },
    stdio: ["pipe", "pipe", "pipe"],
  },
);
let out = "";
let err = "";
let parseBuf = "";
let nextId = 2;
let jobId;
let commentaryOffset = 0;
let commentaryInFlight = false;
let resultRequested = false;
let resultOffset = 0;
let resultComplete = false;
let canceledWaitId;
let done = false;
const requestNames = new Map();
const statusResults = [];
const commentaryResults = [];
const resultResults = [];
const cancelResults = [];
const blockingResults = [];
child.stdin.on("error", () => {});
child.stderr.on("data", (data) => { err += data.toString(); });
const send = (message) => {
  if (child.stdin.writable) child.stdin.write(`${JSON.stringify(message)}\n`);
};
const callTool = (name, args) => {
  const id = nextId++;
  requestNames.set(id, name);
  send({ jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: args } });
  return id;
};
const poll = (cursor) => callTool("codex-status", { jobId, cursor, wait_ms: 200 });
const maybeFinish = () => {
  if (!resultComplete) return;
  if (mode === "asyncconcurrent" && blockingResults.length === 0) return;
  finish();
};
const finish = () => {
  if (done) return;
  done = true;
  setTimeout(() => { try { child.stdin.end(); } catch {} }, mode === "asyncfallback" ? 400 : 100);
};
const onFrame = (frame) => {
  if (frame.id === 1 && frame.result) {
    send({ jsonrpc: "2.0", method: "notifications/initialized" });
    send({ jsonrpc: "2.0", id: "mcp-agents/job/test/client", method: "ping", params: {} });
    callTool("codex-start", {
      prompt: "exercise async bridge",
      cwd: serverDir,
      sandbox: "read-only",
      model_reasoning_effort: "xhigh",
    });
    return;
  }
  const requestName = requestNames.get(frame.id);
  if (!requestName || !frame.result) return;
  const structured = frame.result.structuredContent ?? {};
  if (requestName === "codex-start") {
    jobId = structured.jobId;
    if (mode === "asyncabortcancel") {
      poll(structured.cursor);
      setTimeout(() => callTool("codex-cancel", { jobId }), 70);
    } else if (["asynccancel", "asynccancelabort", "asynccancelcomplete"].includes(mode)) {
      callTool("codex-cancel", { jobId });
    } else if (mode === "asyncwaitcancel") {
      canceledWaitId = callTool("codex-status", {
        jobId,
        cursor: structured.cursor,
        wait_ms: 1_000,
      });
      setTimeout(() => send({
        jsonrpc: "2.0",
        method: "notifications/cancelled",
        params: { requestId: canceledWaitId, reason: "test waiter cancellation" },
      }), 20);
      setTimeout(() => poll(structured.cursor), 50);
    } else {
      if (mode === "asyncconcurrent") {
        callTool("codex", {
          prompt: "blocking call during background job",
          cwd: serverDir,
          sandbox: "read-only",
          model_reasoning_effort: "xhigh",
        });
      }
      poll(structured.cursor);
    }
    return;
  }
  if (requestName === "codex-status") {
    statusResults.push({ ...structured, text: frame.result.content?.[0]?.text });
    if (
      structured.commentaryEndOffset > commentaryOffset &&
      !commentaryInFlight
    ) {
      commentaryInFlight = true;
      callTool("codex-commentary", { jobId, offset: commentaryOffset });
    }
    if (["completed", "failed", "canceled"].includes(structured.state)) {
      if (!resultRequested) {
        resultRequested = true;
        callTool("codex-result", { jobId, offset: 0 });
      }
    } else {
      poll(structured.cursor);
    }
    return;
  }
  if (requestName === "codex-commentary") {
    commentaryResults.push({ ...structured, text: frame.result.content?.[0]?.text });
    commentaryOffset = structured.nextOffset;
    commentaryInFlight = false;
    return;
  }
  if (requestName === "codex-result") {
    resultResults.push({
      ...structured,
      structuredText: structured.text,
      text: frame.result.content?.[0]?.text,
    });
    if (structured.state !== "completed") {
      resultComplete = true;
      maybeFinish();
      return;
    }
    resultOffset = structured.nextOffset;
    if (structured.done) {
      resultComplete = true;
      maybeFinish();
    } else {
      callTool("codex-result", { jobId, offset: resultOffset });
    }
    return;
  }
  if (requestName === "codex-cancel") {
    cancelResults.push({ ...structured, text: frame.result.content?.[0]?.text });
    // The bridge no longer dies when codex ignores the cancellation, so keep
    // polling: the job must reach a terminal state on its own.
    poll(structured.cursor);
    return;
  }
  if (requestName === "codex") {
    blockingResults.push({ ...structured, text: frame.result.content?.[0]?.text });
    maybeFinish();
  }
};
child.stdout.on("data", (data) => {
  const chunk = data.toString();
  out += chunk;
  parseBuf += chunk;
  let newline;
  while ((newline = parseBuf.indexOf("\n")) !== -1) {
    const line = parseBuf.slice(0, newline); parseBuf = parseBuf.slice(newline + 1);
    let frame; try { frame = JSON.parse(line); } catch { continue; }
    onFrame(frame);
  }
});
const bootTimer = setInterval(() => {
  try { readFileSync(pidFile, "utf8"); } catch { return; }
  clearInterval(bootTimer);
  send({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "job-test", version: "0" },
    },
  });
}, 10);
const timeout = setTimeout(() => {
  try { child.kill("SIGTERM"); } catch {}
}, 4_000);
child.once("close", (code, signal) => {
  clearInterval(bootTimer);
  clearTimeout(timeout);
  let frames = [];
  let parseErrors = 0;
  for (const line of out.split("\n").filter(Boolean)) {
    try { frames.push(JSON.parse(line)); } catch { parseErrors += 1; }
  }
  let calls = [];
  try {
    calls = readFileSync(callFile, "utf8")
      .split("\n").filter(Boolean).map((line) => JSON.parse(line));
  } catch {}
  let terminalProbeResults = [];
  try {
    terminalProbeResults = readFileSync(terminalProbeOutput, "utf8")
      .split("\n").filter(Boolean).map((line) => JSON.parse(line));
  } catch {}
  const privateIds = calls.map((call) => call.id).filter((id) => typeof id === "string");
  const rawFrames = JSON.stringify(frames);
  process.stdout.write(`${JSON.stringify({
    code,
    signal,
    jobId,
    statusResults,
    commentaryResults,
    resultResults,
    cancelResults,
    blockingResults,
    canceledWaitId,
    frames,
    calls,
    parseErrors,
    privateIds,
    privateIdLeaked: privateIds.some((id) => rawFrames.includes(id)),
    terminalProbeResults,
    stderr: err,
  })}\n`);
});
EOF
}

test_codex_job_lifecycle() {
  local label="$1" predicate="$2" mode="${3:-async}" tmpdir status summary ok
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  write_codex_lifecycle_stub "$tmpdir"
  write_codex_job_driver "$tmpdir"
  set +e
  summary=$($TIMEOUT_CMD 8 node "$tmpdir/job-driver.mjs" "$tmpdir" "$(pwd)" "$mode" 2>/dev/null)
  status=$?
  set -e
  ok=1
  [ "$status" -eq 0 ] || ok=0
  printf '%s' "$summary" | jq -e "$predicate" >/dev/null 2>&1 || ok=0
  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  Summary: ${summary:0:10000}"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

test_codex_lifecycle() {
  local label="$1" mode="$2" idle="$3" hard="$4" settle="$5"
  local terminal="$6" cancel="$7" progress="$8" predicate="$9" flushstall="${10:-}"
  local tmpdir status summary ok
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  write_codex_lifecycle_stub "$tmpdir"
  write_codex_lifecycle_driver "$tmpdir"
  set +e
  summary=$($TIMEOUT_CMD 8 node "$tmpdir/driver.mjs" "$tmpdir" "$(pwd)" "$mode" "$idle" "$hard" "$settle" "$terminal" "$cancel" "$progress" ${flushstall:+"$flushstall"} 2>/dev/null)
  status=$?
  set -e
  ok=1
  [ "$status" -eq 0 ] || ok=0
  printf '%s' "$summary" | jq -e "$predicate" >/dev/null 2>&1 || ok=0
  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  Summary: ${summary:0:10000}"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

test_codex_auth_failure_never_persists() {
  local label="$1" mode="${2:-authfailure}"
  local tmpdir real_home status summary content ok
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  real_home="$tmpdir/real-codex"
  mkdir "$real_home"
  printf '%s' '{"token":"original"}' > "$real_home/auth.json"
  chmod 0600 "$real_home/auth.json"
  write_codex_lifecycle_stub "$tmpdir"
  write_codex_lifecycle_driver "$tmpdir"
  set +e
  summary=$(CODEX_HOME="$real_home" MCP_AGENTS_TEST_MUTATE_ISOLATED_AUTH=1 \
    $TIMEOUT_CMD 8 node "$tmpdir/driver.mjs" "$tmpdir" "$(pwd)" \
    "$mode" "2" "2" "650" "80" "100" "0" 2>/dev/null)
  status=$?
  set -e
  content=$(cat "$real_home/auth.json" 2>/dev/null || true)
  ok=1
  [ "$status" -eq 0 ] || ok=0
  [ "$content" = '{"token":"original"}' ] || ok=0
  if [ "$mode" = "authfailure" ]; then
    printf '%s' "$summary" | jq -e \
      '([.frames[] | select(.id == 2 and .result.structuredContent.code == "codex_auth_invalidated")] | length == 1)' \
      >/dev/null 2>&1 || ok=0
  else
    printf '%s' "$summary" | jq -e \
      '([.frames[] | select(.method == "codex/event" and .params.msg.codex_error_info == "unauthorized")] | length == 0) and
       (.stderr | contains("codex_auth_invalidated"))' \
      >/dev/null 2>&1 || ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  auth.json: $content"
    echo "  Summary: ${summary:0:10000}"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

# ── Helpers: browser downstream + lease stubs and an MCP stdio driver. ──────
# These exercise the public process boundary: the real server parses real CLI
# argv, forwards real JSON-RPC frames, and shells out to a separately spawned
# lease helper. No browser helper is called past its production interface.
write_browser_mcp_stub() {
  cat >"$1/browser-mcp-stub" <<'EOF'
#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");

const mode = process.env.MCP_STUB_BROWSER_MODE || "normal";
const captureDir = process.env.MCP_STUB_BROWSER_CAPTURE_DIR;
const spawnFile = path.join(captureDir, "downstream-spawns.jsonl");
const rootsFile = path.join(captureDir, "roots-response.txt");
const rootsResponsesFile = path.join(captureDir, "roots-responses.jsonl");
const callCountFile = path.join(captureDir, "browser-call-count");
fs.appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${process.pid}\n`);
const argv = process.argv.slice(2);
fs.appendFileSync(spawnFile, `${JSON.stringify({ pid: process.pid, at: Date.now(), argv })}\n`);
const spawnOrdinal = fs.readFileSync(spawnFile, "utf8")
  .split("\n").filter(Boolean).length;
const stdinFile = path.join(captureDir, `${process.pid}.stdin`);
const send = (value, callback) =>
  process.stdout.write(`${JSON.stringify(value)}\n`, callback);
const initializeResult = (id) => ({
  jsonrpc: "2.0",
  id,
  result: {
    protocolVersion: "2024-11-05",
    capabilities: { tools: {} },
    serverInfo: { name: "browser-stub", version: "1.7.0" },
  },
});
const tools = () => [
  { name: "navigate_page", title: "Navigate title", description: "Navigate", annotations: { readOnlyHint: false }, inputSchema: { type: "object", properties: { url: { type: "string" } } } },
  { name: "performance_start_trace", description: "Start trace", inputSchema: { type: "object", properties: { reload: { type: "boolean" } } } },
  { name: "performance_stop_trace", description: "Stop trace", inputSchema: { type: "object", properties: {} } },
  { name: "performance_analyze_insight", description: "Analyze insight", inputSchema: { type: "object", properties: { insightSetId: { type: "string" } } } },
  { name: "lighthouse_audit", description: "Run Lighthouse", inputSchema: { type: "object", properties: {} } },
  { name: "upload_file", description: "Upload a file", inputSchema: { type: "object", properties: { filePath: { type: "string" } } } },
];
const toolsResult = (id) => ({ jsonrpc: "2.0", id, result: { tools: tools() } });
const result = (id, text = "BROWSER_OK") => send({
  jsonrpc: "2.0",
  id,
  result: {
    content: [{ type: "text", text }],
    structuredContent: { content: text },
  },
});
const connectFailure = (id) => send({
  jsonrpc: "2.0",
  id,
  result: {
    isError: true,
    content: [{ type: "text", text: "Could not connect to Chrome. Failed to fetch browser WebSocket URL." }],
    structuredContent: { content: "Could not connect to Chrome: Failed to fetch browser webSocket URL" },
  },
});
const emitTools = (id) => {
  const line = JSON.stringify(toolsResult(id));
  if (mode === "split") {
    const cut = Math.floor(line.length / 2);
    process.stdout.write(line.slice(0, cut));
    setTimeout(() => process.stdout.write(`${line.slice(cut)}\n`), 30);
  } else if (mode === "interleaved") {
    process.stdout.write('{"jsonrpc":"2.0","method":"notifications/message","params":{"marker":"BROWSER_INTERLEAVED"}}\n');
    process.stdout.write(`${line}\n`);
  } else if (mode === "straddle") {
    process.stdout.write('DLE"}}\n');
    process.stdout.write(`${line}\n`);
  } else if (mode === "partialdie") {
    process.stdout.write(line.slice(0, Math.floor(line.length / 2)), () => process.exit(0));
  } else if (mode === "nonewlinedie") {
    process.stdout.write(line, () => process.exit(0));
  } else if (mode === "oversized") {
    send({ jsonrpc: "2.0", method: "notifications/message", params: { marker: "BROWSER_OVERSIZED", pad: "x".repeat(11 * 1024 * 1024) } });
    process.stdout.write(`${line}\n`);
  } else if (mode === "bp") {
    send({ jsonrpc: "2.0", method: "notifications/message", params: { marker: "BROWSER_BP", pad: "x".repeat(300000) } });
    process.stdout.write(`${line}\n`);
  } else {
    process.stdout.write(`${line}\n`);
  }
};
const nextCallCount = () => {
  let count = 0;
  try { count = Number(fs.readFileSync(callCountFile, "utf8")); } catch {}
  count += 1;
  fs.writeFileSync(callCountFile, String(count));
  return count;
};
const batchedCallIds = [];
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  input += chunk;
  let newline;
  while ((newline = input.indexOf("\n")) !== -1) {
    const raw = input.slice(0, newline);
    input = input.slice(newline + 1);
    fs.appendFileSync(stdinFile, `${raw}\n`);
    let message;
    try { message = JSON.parse(raw); } catch { continue; }
    if (message.method === "initialize") {
      if (mode !== "hang-init") send(initializeResult(message.id));
      if (mode === "straddle") {
        process.stdout.write('{"jsonrpc":"2.0","method":"notifications/message","params":{"marker":"STRAD');
      }
    } else if (message.method === "notifications/initialized") {
      if (mode === "timeout-no-result" && spawnOrdinal > 1) {
        setTimeout(() => process.stdout.write("LATCH_CLEAR"), 25);
      }
      if (mode === "roots") {
        setTimeout(() => send({ jsonrpc: "2.0", id: "roots-1", method: "roots/list", params: {} }), 20);
      } else if (mode === "restart-roots") {
        setTimeout(() => send({ jsonrpc: "2.0", id: "roots-reused", method: "roots/list", params: {} }), 20);
      }
    } else if (message.method === "tools/list") {
      emitTools(message.id);
    } else if (message.method === "tools/call") {
      const count = nextCallCount();
      if (mode === "die") {
        process.exit(0);
      } else if (mode === "connectfail") {
        if (count === 1 || process.env.MCP_STUB_LEASE_MODE !== "status-absent") connectFailure(message.id);
        else result(message.id, "RECOVERED_NEXT_CALL");
      } else if (mode === "deferred-hard-timeout-recovery") {
        if (spawnOrdinal === 1 && message.id === 4) {
          result(message.id, "CLASSIFIER_OK_4");
        } else if (spawnOrdinal === 1 && message.id === 3) {
          setTimeout(() => result(message.id, "DEFERRED_RAW_3"), 10);
        }
      } else if (mode === "activity") {
        setTimeout(() => send({ jsonrpc: "2.0", method: "notifications/message", params: { activity: 1 } }), 50);
        setTimeout(() => send({ jsonrpc: "2.0", id: "activity-roots", method: "roots/list", params: {} }), 130);
        setTimeout(() => send({ jsonrpc: "2.0", method: "notifications/message", params: { activity: 2 } }), 210);
        setTimeout(() => result(message.id, "ACTIVITY_DONE"), 290);
      } else if (mode === "controlled-result") {
        const timer = setInterval(() => {
          if (!fs.existsSync(path.join(captureDir, `allow-call-${message.id}`))) return;
          clearInterval(timer);
          result(message.id, `RAW_CANCELLED_${message.id}`);
        }, 10);
      } else if (mode === "restart-outstanding" || mode === "restart-outstanding-unsafe") {
        if (mode === "restart-outstanding-unsafe" && spawnOrdinal === 1) {
          process.stdout.write('{"jsonrpc":"2.0","id":999,"result":');
        }
        if (spawnOrdinal > 1) {
          result(message.id, `REPLACEMENT_OK_${message.id}`);
          setTimeout(() => process.stdout.write("LATCH_CLEAR"), 25);
        }
      } else if (mode === "oversized-result") {
        send({
          jsonrpc: "2.0",
          id: message.id,
          result: {
            content: [{ type: "text", text: "RAW_OVERSIZED_RESULT" }],
            structuredContent: {
              content: "RAW_OVERSIZED_RESULT",
              pad: "x".repeat(11 * 1024 * 1024),
            },
          },
        });
      } else if (mode === "oversized-result-id-after") {
        send({
          jsonrpc: "2.0",
          result: {
            content: [{ type: "text", text: "RAW_OVERSIZED_ID_AFTER" }],
            structuredContent: { content: "RAW_OVERSIZED_ID_AFTER" },
          },
          id: message.id,
          pad: "x".repeat(11 * 1024 * 1024),
        });
      } else if (mode === "oversized-complete-id-after") {
        send({
          jsonrpc: "2.0",
          result: {
            content: [{ type: "text", text: "RAW_OVERSIZED_COMPLETE" }],
            structuredContent: { content: "RAW_OVERSIZED_COMPLETE" },
          },
          id: message.id,
          pad: "x".repeat(2048),
        });
      } else if (mode === "finalize-multiframe") {
        batchedCallIds.push(message.id);
        if (batchedCallIds.length === 3) {
          const lines = batchedCallIds.map((id) => JSON.stringify({
            jsonrpc: "2.0",
            id,
            result: {
              content: [{ type: "text", text: `RAW_FINALIZE_${id}` }],
              structuredContent: { content: `RAW_FINALIZE_${id}` },
            },
          })).join("\n");
          process.stdout.write(`${lines}\n`, () => process.exit(0));
        }
      } else if (mode === "malformed-result") {
        process.stdout.write(
          `{"jsonrpc":"2.0","id":${JSON.stringify(message.id)},"result":INVALID}\n`,
        );
        setTimeout(() => process.stdout.write("LATCH_CLEAR"), 25);
      } else if (mode === "timeout-no-result") {
        if (spawnOrdinal === 1) {
          process.stdout.write('{"jsonrpc":"2.0","id":999,"result":');
          setTimeout(() => process.stdout.write("OLD_PROCESS_SHOULD_BE_DEAD"), 1200);
        } else {
          setTimeout(() => process.stdout.write("LATCH_CLEAR"), 25);
        }
      } else if (mode === "call-nonewlinedie") {
        process.stdout.write(JSON.stringify({
          jsonrpc: "2.0",
          id: message.id,
          result: {
            content: [{ type: "text", text: `BROWSER_UNTERMINATED_${message.id}` }],
            structuredContent: { content: `BROWSER_UNTERMINATED_${message.id}` },
          },
        }), () => process.exit(0));
      } else if (mode === "stderr") {
        const timer = setInterval(() => process.stderr.write("noisy but not browser activity\n"), 35);
        setTimeout(() => clearInterval(timer), 350);
      } else {
        result(message.id, `BROWSER_OK_${message.id}`);
      }
    } else if (message.id === "roots-1") {
      fs.writeFileSync(rootsFile, raw);
    } else if (message.id === "roots-reused") {
      fs.appendFileSync(rootsResponsesFile, `${JSON.stringify({
        pid: process.pid,
        spawnOrdinal,
        raw,
      })}\n`);
    }
  }
});
process.stdin.on("end", () => process.exit(0));
setInterval(() => {}, 1 << 30);
EOF
  chmod +x "$1/browser-mcp-stub"
}

write_browser_lease_stub() {
  cat >"$1/browser-identity-stub" <<'EOF'
#!/usr/bin/env node
const fs = require("node:fs");
const http = require("node:http");

const [port, identity, readyFile] = process.argv.slice(2);
const captureDir = process.env.MCP_STUB_BROWSER_CAPTURE_DIR;
fs.appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${process.pid}\n`);
let identityReads = 0;
const server = http.createServer((request, response) => {
  if (request.url !== "/json/version") {
    response.writeHead(404).end();
    return;
  }
  identityReads += 1;
  const respond = () => {
    const reportedIdentity =
      fs.existsSync(`${captureDir}/substitute-after-acquire`) && identityReads > 1
        ? "local-substitute"
        : identity;
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({
      Browser: "Chrome/Test",
      webSocketDebuggerUrl:
        `ws://127.0.0.1:${port}/devtools/browser/${reportedIdentity}`,
    }));
  };
  if (
    fs.existsSync(`${captureDir}/slow-post-identity`) && identityReads > 1
  ) setTimeout(respond, 300);
  else if (fs.existsSync(`${captureDir}/slow-identity`)) setTimeout(respond, 700);
  else respond();
});
const stop = () => server.close(() => process.exit(0));
process.on("SIGTERM", stop);
process.on("SIGINT", stop);
server.listen(Number(port), "127.0.0.1", () => {
  fs.writeFileSync(readyFile, String(process.pid));
});
EOF
  chmod +x "$1/browser-identity-stub"
  cat >"$1/browser-lease-stub" <<'EOF'
#!/usr/bin/env node
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const mode = process.env.MCP_STUB_LEASE_MODE || "ready";
const captureDir = process.env.MCP_STUB_BROWSER_CAPTURE_DIR;
const callsFile = path.join(captureDir, "lease-calls.jsonl");
const releaseCompletionsFile = path.join(captureDir, "release-completions.jsonl");
const countFile = path.join(captureDir, "acquire-count");
const identityStateFile = path.join(captureDir, "identity-current.json");
const termFile = path.join(captureDir, "acquire-terminated.txt");
const args = process.argv.slice(2);
fs.appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${process.pid}\n`);
fs.appendFileSync(callsFile, `${JSON.stringify({ pid: process.pid, at: Date.now(), args })}\n`);
const valueAfter = (flag) => {
  const index = args.indexOf(flag);
  return index === -1 ? undefined : args[index + 1];
};
const acquireCount = () => {
  let count = 0;
  try { count = Number(fs.readFileSync(countFile, "utf8")); } catch {}
  count += 1;
  fs.writeFileSync(countFile, String(count));
  return count;
};
const stopIdentity = () => {
  let state;
  try { state = JSON.parse(fs.readFileSync(identityStateFile, "utf8")); } catch {}
  if (state?.pid) {
    try { process.kill(state.pid, "SIGTERM"); } catch {}
    for (let attempt = 0; attempt < 200; attempt += 1) {
      try { process.kill(state.pid, 0); } catch { break; }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
    }
    try { process.kill(state.pid, 0); process.kill(state.pid, "SIGKILL"); } catch {}
  }
  try { fs.unlinkSync(identityStateFile); } catch {}
};
const startIdentity = (port, identity) => {
  stopIdentity();
  const readyFile = path.join(captureDir, `identity-ready-${process.pid}`);
  const child = spawn(
    process.execPath,
    [path.join(__dirname, "browser-identity-stub"), port, identity, readyFile],
    { detached: true, stdio: "ignore", env: process.env },
  );
  for (let attempt = 0; attempt < 200 && !fs.existsSync(readyFile); attempt += 1) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
  }
  if (!fs.existsSync(readyFile)) {
    try { process.kill(-child.pid, "SIGKILL"); } catch {}
    throw new Error("identity stub failed to bind");
  }
  try { fs.unlinkSync(readyFile); } catch {}
  fs.writeFileSync(identityStateFile, JSON.stringify({
    pid: child.pid,
    port: Number(port),
    identity,
  }));
};
const ready = (count) => {
  const port = valueAfter("--local-cdp-port");
  const wrong = mode === "wrong-port" ? String(Number(port) + 1) : port;
  if (mode !== "wrong-port" && mode !== "malformed" && mode !== "duplicate-proto") {
    startIdentity(port, `remote-gen-${count}`);
  }
  const lines = [
    "record_version=1",
    "state=ready",
    ...(mode === "malformed" ? [] : [`generation=gen-${count}`]),
    "lease_id=cbx_test",
    `local_cdp_port=${wrong}`,
    `browser_url=http://127.0.0.1:${wrong}`,
    `idle_teardown=${mode === "cap-only" ? "cap-only" : "enabled"}`,
    ...(mode === "duplicate-proto" ? ["__proto__=first", "__proto__=second"] : []),
  ];
  process.stdout.write(`${lines.join("\n")}\n`);
  process.exit(0);
};
const command = args[0];
if (command === "acquire") {
  const count = acquireCount();
  if ([
    "acquire-term",
    "acquire-term-timeout",
    "acquire-ignore-term-timeout",
    "acquire-derived-timeout",
  ].includes(mode)) {
    process.on("SIGTERM", () => {
      fs.writeFileSync(termFile, "SIGTERM\n");
      if (mode !== "acquire-ignore-term-timeout") process.exit(69);
    });
    fs.writeFileSync(path.join(captureDir, "acquire-hanging-ready"), "ready\n");
    setInterval(() => {}, 1 << 30);
  } else if (mode === "unavailable-69") {
    process.stderr.write("no capacity\n");
    process.exit(69);
  } else if (mode === "dev-unreachable-69") {
    process.stderr.write("GUI not verified — dev server not reachable at :5100\n");
    process.exit(69);
  } else if (mode === "minio-unreachable-69") {
    process.stderr.write("GUI not verified — MinIO not reachable at :9000\n");
    process.exit(69);
  } else if (mode === "acquire-empty-70") {
    process.exit(70);
  } else if (
    mode === "port-75-always" ||
    (mode === "port-75-once" && count === 1) ||
    (mode === "ready-port-75-second" && count === 2)
  ) {
    setTimeout(() => {
      process.stdout.write("state=port_unavailable\n");
      process.exit(75);
    }, 120);
  } else if (mode === "slow-ready") {
    setTimeout(() => ready(count), 280);
  } else {
    ready(count);
  }
} else if (command === "status") {
  if (mode === "status-ready") process.exit(0);
  if (mode === "status-slow-ready") {
    setTimeout(() => process.exit(0), 300);
    return;
  }
  if (mode === "status-corrupt") process.exit(70);
  process.exit(69);
} else if (command === "release") {
  stopIdentity();
  if (mode === "release-69" || mode === "cap-only") process.exit(69);
  if (mode === "release-empty-70") process.exit(70);
  const reason = valueAfter("--reason");
  const finishRelease = () => {
    fs.appendFileSync(releaseCompletionsFile, `${JSON.stringify({
      pid: process.pid,
      at: Date.now(),
      reason,
    })}\n`);
    process.exit(0);
  };
  if (mode === "slow-idle-release" && reason === "idle") {
    setTimeout(finishRelease, 2200);
  } else if (mode === "slow-shutdown-release" && reason === "shutdown") {
    setTimeout(finishRelease, 650);
  } else {
    finishRelease();
  }
} else {
  process.exit(64);
}
EOF
  chmod +x "$1/browser-lease-stub"
}

write_browser_npx_stub() {
  cat >"$1/npx" <<'EOF'
#!/usr/bin/env node
const { spawn } = require("node:child_process");
const fs = require("node:fs");

fs.appendFileSync(process.env.MCP_AGENTS_TEST_CHILD_REGISTRY, `${process.pid}\n`);
const args = process.argv.slice(2);
fs.appendFileSync(
  process.env.MCP_STUB_NPX_CAPTURE,
  `${JSON.stringify({ pid: process.pid, at: Date.now(), args })}\n`,
);
const child = spawn(process.env.MCP_STUB_NPX_TARGET, args.slice(2), {
  stdio: "inherit",
});
child.on("error", (error) => {
  process.stderr.write(`${error.message}\n`);
  process.exit(1);
});
child.on("close", (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exit(code ?? 1);
});
EOF
  chmod +x "$1/npx"
}

write_browser_driver() {
  cat >"$1/browser-driver.mjs" <<'EOF'
import { spawn } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";

const [stubDir, serverDir, scenario, browserMode, leaseMode, idle, hard] = process.argv.slice(2);
const captureDir = `${stubDir}/captures`;
const browserCommand = JSON.stringify([`${stubDir}/browser-mcp-stub`, "--stub-base"]);
const leaseCommand = JSON.stringify([`${stubDir}/browser-lease-stub`]);
const child = spawn("node", [
  "server.js",
  "--provider", "browser",
  "--browser_lease_command", leaseCommand,
  "--browser_command", browserCommand,
  "--browser_idle_timeout", idle,
  "--browser_viewport", "1280x720",
  "--browser_app_port", "5100",
  "--browser_log_file", `${stubDir}/browser.log`,
  "--browser_allowed_url_pattern", "http://127.0.0.1/*",
  "--browser_allowed_url_pattern", "https://example.test/*",
  "--timeout", hard,
], {
  cwd: serverDir,
  env: {
    ...process.env,
    MCP_STUB_BROWSER_MODE: browserMode,
    MCP_STUB_LEASE_MODE: leaseMode,
    MCP_STUB_BROWSER_CAPTURE_DIR: captureDir,
    MCP_AGENTS_BROWSER_COMMAND: '["/definitely/not-the-cli-browser"]',
    MCP_AGENTS_BROWSER_LEASE_COMMAND: '["/definitely/not-the-cli-lease"]',
    MCP_AGENTS_TEST_BROWSER_PROGRESS_INTERVAL_MS: "45",
    ...(leaseMode === "acquire-derived-timeout" ? {} : {
      // 180ms lost a race with process spawn: a freshly written file costs
      // ~210ms on its first exec here (~29ms once warm), so the helper was
      // killed before it recorded its invocation. The helper hangs forever in
      // these modes, so a larger budget still times out -- it just stops
      // killing the stub before it can install its SIGTERM handler.
      MCP_AGENTS_TEST_BROWSER_HELPER_TIMEOUT_MS:
        ["acquire-term-timeout", "acquire-ignore-term-timeout"].includes(leaseMode)
          ? "1200"
          : "1500",
    }),
    MCP_AGENTS_TEST_BROWSER_IDENTITY_TIMEOUT_MS: "500",
    MCP_AGENTS_TEST_BROWSER_HELPER_TERM_GRACE_MS: "250",
    MCP_AGENTS_TEST_BROWSER_SHUTDOWN_RELEASE_TIMEOUT_MS: "1500",
    MCP_AGENTS_TEST_BROWSER_FLUSH_STALL_MS: "400",
    ...(scenario === "oversized-complete-id-after" ? {
      MCP_AGENTS_TEST_BROWSER_REWRITE_MAX_BYTES: "512",
    } : {}),
  },
  stdio: ["pipe", "pipe", "pipe"],
});
let out = "";
let err = "";
let parseBuffer = "";
let parseErrors = 0;
let driverError;
let lastNoisyStderrAt;
let rootsRequestCount = 0;
let substituteChild;
let latchClearBeforeClose = false;
const rootsClientResponses = [];
const frames = [];
const frameEvents = [];
const rawLines = [];
const pending = new Map();
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const waitFor = async (predicate, message, timeoutMs = 2000) => {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await delay(10);
  }
  throw new Error(message);
};
const sendRaw = (line) => child.stdin.write(`${line}\n`);
const send = (message) => sendRaw(JSON.stringify(message));
const request = (id, method, params, timeoutMs = 2500) => new Promise((resolve, reject) => {
  const timer = setTimeout(() => {
    pending.delete(JSON.stringify(id));
    reject(new Error(`${method} ${JSON.stringify(id)} timed out`));
  }, timeoutMs);
  pending.set(JSON.stringify(id), {
    resolve: (frame) => { clearTimeout(timer); resolve(frame); },
  });
  send({ jsonrpc: "2.0", id, method, params });
});
const call = (id, token) => request(id, "tools/call", {
  name: "navigate_page",
  arguments: { url: `http://127.0.0.1/${id}` },
  ...(token === undefined ? {} : { _meta: { progressToken: token } }),
});
child.stdin.on("error", () => {});
child.stderr.on("data", (chunk) => {
  const text = chunk.toString();
  err += text;
  if (text.includes("[chrome-devtools] noisy but not browser activity")) {
    lastNoisyStderrAt = Date.now();
  }
});
child.stdout.on("data", (chunk) => {
  const text = chunk.toString();
  out += text;
  parseBuffer += text;
  let newline;
  while ((newline = parseBuffer.indexOf("\n")) !== -1) {
    const line = parseBuffer.slice(0, newline);
    parseBuffer = parseBuffer.slice(newline + 1);
    if (!line) continue;
    rawLines.push(line.length > 100000 ? line.slice(0, 300) : line);
    let frame;
    try { frame = JSON.parse(line); } catch { parseErrors += 1; continue; }
    if (frame.params?.pad) frame.params.pad = `[${frame.params.pad.length} bytes]`;
    if (frame.result?.structuredContent?.pad) {
      frame.result.structuredContent.pad =
        `[${frame.result.structuredContent.pad.length} bytes]`;
    }
    if (frame.pad) frame.pad = `[${frame.pad.length} bytes]`;
    frames.push(frame);
    frameEvents.push({ at: Date.now(), id: frame.id, method: frame.method });
    if (frame.method === "roots/list") {
      if (frame.id === "roots-1") {
        sendRaw('{"jsonrpc":"2.0", "id":"roots-1", "result":{"roots":[{"uri":"file:///workspace","name":"root"}]}}');
      } else if (scenario === "restart-roots" || scenario === "restart-roots-out-of-order") {
        rootsRequestCount += 1;
        const response = (id, name) =>
          `{"jsonrpc":"2.0", "id":${JSON.stringify(id)}, "result":{"roots":[{"uri":"file:///workspace","name":"${name}"}]}}`;
        if (scenario === "restart-roots" ) {
          const name = rootsRequestCount === 1 ? "dead-root" : "replacement-root";
          rootsClientResponses.push({ order: name, id: frame.id });
          sendRaw(response(frame.id, name));
        } else if (rootsRequestCount === 1) {
          rootsClientResponses.push({ order: "held-dead", id: frame.id });
        } else {
          rootsClientResponses.push({ order: "replacement-first", id: frame.id });
          sendRaw(response(frame.id, "replacement-root"));
          if (scenario === "restart-roots-out-of-order") {
            setTimeout(() => {
              rootsClientResponses.push({ order: "stale-second", id: "roots-reused" });
              sendRaw(response("roots-reused", "dead-root"));
            }, 30);
          }
        }
      } else {
        send({ jsonrpc: "2.0", id: frame.id, result: { roots: [] } });
      }
    }
    const waiter = pending.get(JSON.stringify(frame.id));
    if (waiter && (frame.result || frame.error)) {
      pending.delete(JSON.stringify(frame.id));
      waiter.resolve(frame);
    }
  }
});
const closed = new Promise((resolve) => child.once("close", (code, signal) => resolve({ code, signal })));
const hardStop = setTimeout(() => { try { child.kill("SIGKILL"); } catch {} }, 6500);
const initializeParams = {
  protocolVersion: "2024-11-05",
  capabilities: { roots: { listChanged: true }, sampling: {} },
  clientInfo: { name: "browser-driver", version: "0" },
};
try {
  const initialized = request(1, "initialize", initializeParams);
  await initialized;
  if (scenario !== "hang-init") {
    send({ jsonrpc: "2.0", method: "notifications/initialized" });
    if (scenario !== "skip-list") {
      if (scenario === "bp") {
        child.stdout.pause();
        setTimeout(() => child.stdout.resume(), 350);
      }
      await request(2, "tools/list", {});
    }
  }
  if (scenario === "normal" || scenario === "shutdown" || scenario === "idle-zero") {
    await call(3);
    if (scenario === "idle-zero") await delay(260);
  } else if (scenario === "first-call-substitution") {
    writeFileSync(`${captureDir}/substitute-after-acquire`, "ready\n");
    await call(3);
  } else if (scenario === "concurrent-identity-substitution") {
    // Two calls queue on one shared cold acquire (leaseMode "slow-ready" delays
    // "ready" long enough for both to stack up before it resolves), so both are
    // forwarded to downstream under the SAME generation with no pre-flight
    // identity gate between them. The substituted identity mismatches on the
    // first post-response check (the acquire itself consumed read #1), so the
    // first result's classification discards the shared generation. The second
    // result's classification must then be bound to the generation snapshot it
    // was actually issued under, not the now-emptied live generation.
    writeFileSync(`${captureDir}/substitute-after-acquire`, "ready\n");
    const first = call(3);
    const second = call(4);
    await Promise.all([first, second]);
  } else if (scenario === "classifier-identity-toctou") {
    writeFileSync(`${captureDir}/slow-post-identity`, "ready\n");
    await call(3);
  } else if (scenario === "classifier-connect-toctou") {
    await call(3);
  } else if (scenario === "deferred-hard-timeout-recovery") {
    writeFileSync(`${captureDir}/slow-post-identity`, "ready\n");
    const timeout = call(5);
    await delay(120);
    await Promise.all([call(3), call(4), timeout]);
    await delay(100);
  } else if (scenario === "cancel-open-generation-change") {
    const late = call(3);
    await waitFor(() => {
      try {
        return readFileSync(`${captureDir}/browser-call-count`, "utf8") === "1";
      } catch { return false; }
    }, "browser call was not forwarded before cancellation");
    send({
      jsonrpc: "2.0",
      method: "notifications/cancelled",
      params: { requestId: 3, reason: "test open-call cancellation" },
    });
    await waitFor(() => {
      try {
        return readFileSync(`${captureDir}/lease-calls.jsonl`, "utf8")
          .split("\n").filter(Boolean)
          .map((line) => JSON.parse(line))
          .some((entry) => entry.args[0] === "release" && entry.args.includes("idle"));
      } catch { return false; }
    }, "generation was not released while the cancelled call remained open");
    writeFileSync(`${captureDir}/allow-call-3`, "ready\n");
    await late;
  } else if (scenario === "restart-outstanding" || scenario === "restart-outstanding-unsafe") {
    let abandonedError;
    const abandoned = call(3).catch((error) => { abandonedError = error; });
    await waitFor(() => {
      try {
        return readFileSync(`${captureDir}/browser-call-count`, "utf8") === "1";
      } catch { return false; }
    }, "browser call was not outstanding before restart");
    await waitFor(() => {
      try {
        return readFileSync(`${captureDir}/lease-calls.jsonl`, "utf8")
          .split("\n").filter(Boolean)
          .map((line) => JSON.parse(line))
          .some((entry) => entry.args[0] === "release" && entry.args.includes("idle"));
      } catch { return false; }
    }, "generation was not released before restart");
    await call(4);
    if (scenario === "restart-outstanding") {
      await waitFor(() => out.includes("LATCH_CLEAR"), "restart left the rewrite latch armed");
      latchClearBeforeClose = true;
    }
    await abandoned;
    if (abandonedError) throw abandonedError;
  } else if (scenario === "oversized-browser-result") {
    await call(3);
  } else if (scenario === "oversized-id-after-result") {
    await call(3);
  } else if (scenario === "oversized-complete-id-after") {
    await call(3);
  } else if (scenario === "finalize-multiframe") {
    writeFileSync(`${captureDir}/slow-post-identity`, "ready\n");
    await Promise.all([call(3), call(4), call(5)]);
  } else if (scenario === "malformed-browser-result") {
    await call(3);
    await waitFor(() => out.includes("LATCH_CLEAR"), "malformed result pinned the rewrite latch");
    latchClearBeforeClose = true;
  } else if (scenario === "browser-hard-timeout") {
    await call(3);
    await waitFor(() => out.includes("LATCH_CLEAR"), "hard timeout pinned the rewrite latch");
    latchClearBeforeClose = true;
  } else if (scenario === "unterminated-browser-result") {
    await call(3);
  } else if (scenario === "identity-substitution") {
    await call(3);
    const identityState = JSON.parse(
      readFileSync(`${captureDir}/identity-current.json`, "utf8"),
    );
    try { process.kill(identityState.pid, "SIGTERM"); } catch {}
    await waitFor(() => {
      try { process.kill(identityState.pid, 0); return false; } catch { return true; }
    }, "remote identity stub did not stop");
    const readyFile = `${captureDir}/substitute-ready`;
    substituteChild = spawn(process.execPath, [
      `${stubDir}/browser-identity-stub`,
      String(identityState.port),
      "local-substitute",
      readyFile,
    ], { detached: true, stdio: "ignore", env: process.env });
    await waitFor(() => existsSync(readyFile), "substitute identity stub did not bind");
    await call(4);
  } else if (scenario === "identity-unreachable") {
    await call(3);
    const identityState = JSON.parse(
      readFileSync(`${captureDir}/identity-current.json`, "utf8"),
    );
    try { process.kill(identityState.pid, "SIGTERM"); } catch {}
    await waitFor(() => {
      try { process.kill(identityState.pid, 0); return false; } catch { return true; }
    }, "remote identity stub did not stop");
    await call(4);
  } else if (scenario === "slow-identity-idle") {
    await call(3);
    writeFileSync(`${captureDir}/slow-identity`, "ready\n");
    await call(4);
  } else if (scenario === "shutdown-acquire") {
    void call(3).catch(() => undefined);
    await waitFor(
      () => existsSync(`${captureDir}/acquire-hanging-ready`),
      "acquire helper did not enter its cleanup-trapped wait",
    );
  } else if (scenario === "unknown") {
    await request(3, "tools/call", {
      name: "not_advertised",
      arguments: {},
    });
  } else if (scenario === "skip-list") {
    await call(3);
  } else if (scenario === "slow-ready") {
    const first = call(3, "browser-progress");
    const second = call(4, 42);
    const canceled = call(5, { invalid: true }).catch(() => undefined);
    const absent = call(6);
    await delay(55);
    send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 5, reason: "test" } });
    await Promise.all([first, second, absent]);
    await delay(80);
    void canceled;
  } else if (["unavailable", "dev-unreachable", "minio-unreachable", "acquire-empty", "acquire-timeout", "acquire-kill-timeout", "derived-helper-timeout", "port-once", "restart-roots", "restart-roots-out-of-order", "port-always", "malformed", "wrong-port", "duplicate-proto", "die"].includes(scenario)) {
    await call(3);
  } else if (["status-ready", "status-corrupt", "status-absent"].includes(scenario)) {
    await call(3);
    if (scenario === "status-absent") await call(4);
  } else if (scenario === "roots") {
    await delay(160);
  } else if (scenario === "activity") {
    await call(3);
    await delay(220);
  } else if (scenario === "stderr") {
    send({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "navigate_page", arguments: { url: "http://127.0.0.1/stderr" } } });
    // Hold the noise window open well past the idle release. The release
    // helper stamps its own start time, so its spawn cost must still land
    // inside the noise for the ordering assertion -- release-before-last-noise
    // -- to mean "stderr did not reset idle".
    await delay(900);
  } else if (scenario === "idle-release" || scenario === "release-69" || scenario === "release-70" || scenario === "cap-only") {
    await call(3);
    await delay(260);
  } else if (scenario === "slow-idle-release") {
    await call(3);
    await delay(2450);
  }
} catch (error) {
  driverError = error instanceof Error ? error.message : String(error);
} finally {
  await delay(60);
  try { child.stdin.end(); } catch {}
}
const closeInfo = await closed;
if (substituteChild) {
  try { process.kill(-substituteChild.pid, "SIGTERM"); } catch {}
}
clearTimeout(hardStop);
const readJsonLines = (file) => {
  try {
    return readFileSync(file, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
  } catch { return []; }
};
const spawns = readJsonLines(`${captureDir}/downstream-spawns.jsonl`).map((spawnInfo) => {
  let stdinRaw = "";
  try { stdinRaw = readFileSync(`${captureDir}/${spawnInfo.pid}.stdin`, "utf8"); } catch {}
  const stdin = stdinRaw.split("\n").filter(Boolean).flatMap((line) => {
    try { return [JSON.parse(line)]; } catch { return []; }
  });
  return { ...spawnInfo, stdinRaw, stdin };
});
const leaseCalls = readJsonLines(`${captureDir}/lease-calls.jsonl`);
const acquirePid = leaseCalls.find((callInfo) => callInfo.args[0] === "acquire")?.pid;
let acquireAlive = false;
try { if (acquirePid) process.kill(acquirePid, 0); acquireAlive = Boolean(acquirePid); } catch {}
const releaseCompletions = readJsonLines(`${captureDir}/release-completions.jsonl`);
const rootsResponses = readJsonLines(`${captureDir}/roots-responses.jsonl`);
let rootsResponse;
try { rootsResponse = readFileSync(`${captureDir}/roots-response.txt`, "utf8"); } catch {}
process.stdout.write(`${JSON.stringify({
  scenario,
  driverError,
  closeInfo,
  frames,
  frameEvents,
  rawLines,
  parseErrors,
  stderr: err,
  spawns,
  leaseCalls,
  releaseCompletions,
  rootsResponses,
  rootsClientResponses,
  latchClearBeforeClose,
  lastNoisyStderrAt,
  rootsResponse,
  acquireTerminated: existsSync(`${captureDir}/acquire-terminated.txt`),
  acquireAlive,
  browserLogExists: existsSync(`${stubDir}/browser.log`),
})}\n`);
EOF
}

test_browser_case() {
  local label="$1" scenario="$2" browser_mode="$3" lease_mode="$4"
  local idle="$5" hard="$6" predicate="$7"
  local tmpdir status summary ok warmdir
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  mkdir "$tmpdir/captures"
  write_browser_mcp_stub "$tmpdir"
  write_browser_lease_stub "$tmpdir"
  write_browser_driver "$tmpdir"
  # macOS pays a one-off scan on a file's FIRST exec: measured here at ~210ms
  # per freshly written file, dropping to ~29ms once that same file is warm.
  # Every case writes its stubs into a new mktemp dir, so cases with sub-second
  # budgets spend that scan inside the window they measure -- the deferred
  # hard-timeout case has 550ms minus a deliberate 280ms wait, leaving ~60ms of
  # headroom cold and ~240ms warm. Pay it up front. acquire-empty-70 exits
  # immediately and the throwaway capture dir keeps it out of this case's
  # captures.
  warmdir=$(mktemp -d)
  MCP_STUB_BROWSER_CAPTURE_DIR="$warmdir" MCP_STUB_LEASE_MODE=acquire-empty-70 \
    "$tmpdir/browser-lease-stub" acquire >/dev/null 2>&1 || true
  rm -rf "$warmdir"
  set +e
  summary=$($TIMEOUT_CMD 9 node "$tmpdir/browser-driver.mjs" \
    "$tmpdir" "$(pwd)" "$scenario" "$browser_mode" "$lease_mode" \
    "$idle" "$hard" 2>/dev/null)
  status=$?
  set -e
  ok=1
  [ "$status" -eq 0 ] || ok=0
  printf '%s' "$summary" | jq -e \
    "(.closeInfo.code == 0) and (.parseErrors == 0) and ($predicate)" \
    >/dev/null 2>&1 || ok=0
  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  Summary: ${summary:0:14000}"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

drive_browser_resolution_handshake() {
  local output_file="$1" expected_server_name="$2" client_name="$3"
  local sent_initialized=0
  printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{"roots":{"listChanged":true}},"clientInfo":{"name":"%s","version":"0"}}}\n' \
    "$client_name"
  for _ in $(seq 1 140); do
    if [ "$sent_initialized" -eq 0 ] && jq -e \
      --arg server_name "$expected_server_name" \
      'select(.id == 1 and .result.serverInfo.name == $server_name)' \
      "$output_file" >/dev/null 2>&1; then
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
      sent_initialized=1
    fi
    if [ "$sent_initialized" -eq 1 ] && jq -e \
      'select(.id == 2 and (.result.tools | length > 0))' \
      "$output_file" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

test_browser_local_resolution() {
  local label="$1" tmpdir output_file error_file status ok lease_command
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  mkdir "$tmpdir/captures"
  output_file="$tmpdir/output.jsonl"
  error_file="$tmpdir/error.txt"
  write_browser_lease_stub "$tmpdir"
  lease_command="[\"$tmpdir/browser-lease-stub\"]"
  set +e
  drive_browser_resolution_handshake \
    "$output_file" "chrome_devtools" "local-resolution-test" | \
    MCP_STUB_BROWSER_CAPTURE_DIR="$tmpdir/captures" \
    MCP_STUB_LEASE_MODE=ready \
    $TIMEOUT_CMD 8 $SERVER --provider browser \
      --browser_lease_command "$lease_command" \
      >"$output_file" 2>"$error_file"
  status=$?
  set -e
  ok=1
  [ "$status" -eq 0 ] || ok=0
  jq -e 'select(.id == 1 and .result.serverInfo.name == "chrome_devtools")' \
    "$output_file" >/dev/null 2>&1 || ok=0
  jq -e 'select(.id == 2 and (.result.tools | length > 0))' \
    "$output_file" >/dev/null 2>&1 || ok=0
  grep -Fq 'source=local package' "$error_file" || ok=0
  grep -Fq 'first startup may wait for npm to resolve chrome-devtools-mcp@latest' "$error_file" && ok=0
  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  Output: $(cat "$output_file")"
    echo "  Error: $(cat "$error_file")"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

test_browser_npx_resolution() {
  local label="$1" tmpdir package_dir output_file error_file npx_file
  local status ok lease_command node_bin_dir
  echo "--- $label ---"
  tmpdir=$(mktemp -d)
  package_dir="$tmpdir/published"
  mkdir -p "$tmpdir/captures" "$tmpdir/bin" \
    "$package_dir/node_modules/@modelcontextprotocol"
  cp server.js package.json "$package_dir/"
  ln -s "$(pwd)/node_modules/@modelcontextprotocol/sdk" \
    "$package_dir/node_modules/@modelcontextprotocol/sdk"
  write_browser_mcp_stub "$tmpdir"
  write_browser_lease_stub "$tmpdir"
  write_browser_npx_stub "$tmpdir/bin"
  output_file="$tmpdir/output.jsonl"
  error_file="$tmpdir/error.txt"
  npx_file="$tmpdir/npx.jsonl"
  lease_command="[\"$tmpdir/browser-lease-stub\"]"
  node_bin_dir=$(dirname "$(command -v node)")
  set +e
  drive_browser_resolution_handshake \
    "$output_file" "browser-stub" "npx-resolution-test" | \
    PATH="$tmpdir/bin:$node_bin_dir:/usr/bin:/bin" NODE_PATH= \
    MCP_STUB_BROWSER_CAPTURE_DIR="$tmpdir/captures" \
    MCP_STUB_BROWSER_MODE=normal \
    MCP_STUB_LEASE_MODE=ready \
    MCP_STUB_NPX_CAPTURE="$npx_file" \
    MCP_STUB_NPX_TARGET="$tmpdir/browser-mcp-stub" \
    $TIMEOUT_CMD 8 node "$package_dir/server.js" --provider browser \
      --browser_lease_command "$lease_command" \
      >"$output_file" 2>"$error_file"
  status=$?
  set -e
  ok=1
  [ "$status" -eq 0 ] || ok=0
  jq -s -e '
    (length == 1) and
    (.[0].args[0:2] == ["-y", "chrome-devtools-mcp@latest"]) and
    (.[0].args | index("--browserUrl") != null) and
    (.[0].args | index("--viewport") == null)
  ' "$npx_file" >/dev/null 2>&1 || ok=0
  jq -e 'select(.id == 1 and .result.serverInfo.name == "browser-stub")' \
    "$output_file" >/dev/null 2>&1 || ok=0
  jq -e 'select(.id == 2 and (.result.tools | length > 0))' \
    "$output_file" >/dev/null 2>&1 || ok=0
  grep -Fq 'first startup may wait for npm to resolve chrome-devtools-mcp@latest' "$error_file" || ok=0
  grep -Fq 'source=npx fallback' "$error_file" || ok=0
  if [ "$ok" -eq 1 ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (status=$status)"
    echo "  Npx: $(cat "$npx_file" 2>/dev/null || true)"
    echo "  Output: $(cat "$output_file")"
    echo "  Error: $(cat "$error_file")"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$tmpdir"
}

test_no_registered_child_leaks() {
  local label="$1" survivors="" pid
  echo "--- $label ---"
  for _ in $(seq 1 30); do
    survivors=""
    while IFS= read -r pid; do
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then survivors="$survivors $pid"; fi
    done < "$TEST_CHILD_REGISTRY"
    [ -z "$survivors" ] && break
    sleep 0.1
  done
  if [ -z "$survivors" ]; then
    green "PASS: $label"
    PASS=$((PASS + 1))
  else
    red "FAIL: $label (survivors:$survivors)"
    FAIL=$((FAIL + 1))
    cleanup_registered_test_children
  fi
}

test_provider_shutdown_kills_child "stdin shutdown kills detached claude child"

# Stub-based Claude one-shot review tests (fast — no real Claude needed).
test_claude_job \
  "Claude background review isolates the leaf CLI and parses fragmented stream-json" \
  "lifecycle" \
  'def arg_after($argv; $flag):
     $argv[(($argv | index($flag)) + 1)];
   (.captures | length == 1) and
   (.captures[0] as $capture |
     ($capture.meta.cwd == "'"$(pwd)"'") and
     ($capture.meta.streaming == true) and
     (arg_after($capture.meta.argv; "--model") == "claude-opus-4-8") and
     (arg_after($capture.meta.argv; "--effort") == "xhigh") and
     (arg_after($capture.meta.argv; "--input-format") == "stream-json") and
     (arg_after($capture.meta.argv; "--output-format") == "stream-json") and
     (arg_after($capture.meta.argv; "--setting-sources") == "project") and
     (arg_after($capture.meta.argv; "--permission-mode") == "plan") and
     (arg_after($capture.meta.argv; "--tools") == "Bash,Glob,Grep,Read") and
     ((arg_after($capture.meta.argv; "--settings") | fromjson) ==
       {"disableAllHooks":true,"disableAgentView":true,"disableArtifact":true}) and
     (arg_after($capture.meta.argv; "--append-system-prompt") |
       (contains("leaf, read-only code reviewer") and
        contains("do not delegate") and
        contains("do not") and
        contains("run tests"))) and
     ($capture.meta.argv | index("--no-session-persistence") != null) and
     ($capture.meta.argv | index("--verbose") != null) and
     ($capture.meta.argv | index("--disable-slash-commands") != null) and
     ($capture.meta.argv | index("--strict-mcp-config") != null) and
     ($capture.meta.argv | index("--include-partial-messages") == null) and
     ($capture.meta.argv | index("--mcp-config") == null) and
     ($capture.meta.argv | index("--dangerously-skip-permissions") == null) and
     ([$capture.stdinParsed[] |
       select(.type == "user" and
         .message == {"role":"user","content":"NORMAL"})] | length == 1)) and
   (.data.starts[0].result.structuredContent |
     (.jobId | type == "string") and
     (.state == "starting") and
     (.cursor == 0) and
     (.resultAvailable == false) and
     (.next.tool == "claude-status")) and
   ([.data.statuses[].result.structuredContent.state] |
     (index("running") != null) and (index("completed") != null)) and
   ([.data.statuses[].result.structuredContent.cursor |
      select(type == "number")] as $cursors |
     ($cursors == ($cursors | sort)) and
     (($cursors | max) >= 3)) and
   (.data.lifecycleTerminal.result.structuredContent |
     (.state == "completed") and
     (.resultAvailable == true) and
     (.next.tool == "claude-result")) and
   (.data.futureCursor.result |
     (.isError == true) and
     (.structuredContent.code == "status_cursor_ahead")) and
   (.data.results[0].result |
     (.isError != true) and
     (.content[0].text == "CLAUDE_REVIEW_OK") and
     (.structuredContent.text == "CLAUDE_REVIEW_OK") and
     (.structuredContent.offset == 0) and
     (.structuredContent.nextOffset == 16) and
     (.structuredContent.endOffset == 16) and
     (.structuredContent.done == true)) and
   (.data.pings[-1].result.content[0].text == "pong") and
   ((.frames | tostring) | contains("SENTINEL_") | not) and
   (.stderr | contains("[mcp-agents] Claude job started")) and
   (.stderr | contains("[mcp-agents] Claude job terminal")) and
   (.stderr | contains("SENTINEL_") | not) and
   (.stderr | contains("NORMAL") | not)'

test_claude_job \
  "legacy claude_code remains blocking and keeps its response shape" \
  "legacy" \
  'def arg_after($argv; $flag):
     $argv[(($argv | index($flag)) + 1)];
   (.captures | length == 1) and
   (.captures[0] as $capture |
     ($capture.meta.streaming == false) and
     ($capture.rawStdin == "LEGACY") and
     (arg_after($capture.meta.argv; "--model") == "claude-opus-4-8") and
     (arg_after($capture.meta.argv; "--effort") == "xhigh") and
     (arg_after($capture.meta.argv; "--output-format") == "json") and
     ($capture.meta.argv | index("--no-session-persistence") != null) and
     ($capture.meta.argv | index("--input-format") == null)) and
   (.data.legacy.result |
     (.isError != true) and
     (.content == [{"type":"text","text":"LEGACY_CLAUDE_OK"}])) and
   (.data.pings[-1].result.content[0].text == "pong")'

test_claude_job \
  "Claude jobs reject relative cwd, caller timeout, and malformed polling locally" \
  "invalid" \
  '(.captures | length == 0) and
   (.data.invalid | length == 4) and
   (.data.invalid | all(
     (.result.isError == true) and
     (.result.structuredContent.code == "invalid_arguments"))) and
   ([.data.invalid[].result.structuredContent.issues[].argument] |
     (index("cwd") != null) and
     (index("timeout_ms") != null) and
     (index("cursor") != null) and
     (index("wait_ms") != null)) and
   (.data.pings[-1].result.content[0].text == "pong")'

test_claude_job \
  "canceling a status waiter leaves its Claude job alive and its sibling completes" \
  "cancel" \
  '([.captures[] |
      select(any(.stdinParsed[];
        .type == "user" and .message.content == "HANG"))] | length == 1) and
   ([.captures[] |
      select(any(.stdinParsed[];
        .type == "user" and .message.content == "HANG"))][0] as $hanging |
     ([$hanging.stdinParsed[] |
       select(.type == "control_request" and
         .request.subtype == "interrupt")] | length == 1) and
     ($hanging.signals | index("CONTROL_INTERRUPT") != null)) and
   ((.data.waiterFrameBeforeJobCancel == null) or
     (.data.waiterFrameBeforeJobCancel.result.structuredContent.state == "running")) and
   (.data.afterWaiterCancel.result.structuredContent |
     (.state == "running") and (.resultAvailable == false)) and
   (.data.hangingTerminal.result.structuredContent.state == "canceled") and
   (.data.hangingPid | type == "number") and
   (.data.hangingAliveAfterTerminal == false) and
   (. as $root |
     .data.secondCancel.result |
       (.isError != true) and
       (.structuredContent.state == "canceled") and
       (.structuredContent.cursor ==
         $root.data.hangingTerminal.result.structuredContent.cursor)) and
   (.data.siblingTerminal.result.structuredContent.state == "completed") and
   ([.data.results[] |
     select(.result.structuredContent.text == "CLAUDE_REVIEW_OK")] | length == 1) and
   (.data.pings[-1].result.content[0].text == "pong")'

test_claude_job \
  "one Claude timeout fails only that job and the server handles a follow-up review" \
  "timeout" \
  '([.captures[] |
      select(any(.stdinParsed[];
        .type == "user" and .message.content == "TIMEOUT"))] | length == 1) and
   ([.captures[] |
      select(any(.stdinParsed[];
        .type == "user" and .message.content == "TIMEOUT"))][0] as $timed |
     ($timed.signals | index("CONTROL_INTERRUPT") != null) and
     ($timed.signals | index("SIGTERM") != null)) and
   (.data.timeoutTerminal.result.structuredContent |
     (.state == "failed") and
     (.message | ascii_downcase | contains("timed out"))) and
   (.data.timeoutPid | type == "number") and
   (.data.timeoutAliveAfterTerminal == false) and
   (.data.followupTerminal.result.structuredContent.state == "completed") and
   ([.data.results[] |
     select(.result.structuredContent.text == "CLAUDE_REVIEW_OK")] | length == 1) and
   (.data.pings[-1].result.content[0].text == "pong")'

test_claude_job \
  "Claude retries one empty terminal result inside the same job and then succeeds" \
  "retry" \
  '(.data.starts | length == 1) and
   (.captures | length == 2) and
   ([.captures[].stdinParsed[] |
     select(.type == "user" and
       .message.content == "EMPTY_THEN_OK")] | length == 2) and
   (.data.retryTerminal.result.structuredContent.jobId ==
     .data.starts[0].result.structuredContent.jobId) and
   (.data.retryTerminal.result.structuredContent.state == "completed") and
   (.data.retryResult.result |
     (.isError != true) and
     (.content[0].text == "CLAUDE_RETRY_OK") and
     (.structuredContent.text == "CLAUDE_RETRY_OK") and
     (.structuredContent.done == true)) and
   ([.data.statuses[].result.structuredContent.message |
     select(contains("retrying after an empty result"))] | length == 1)'

test_claude_job \
  "Claude provider errors become generic failures without leaking provider payloads" \
  "provider-error" \
  '(.captures | length == 1) and
   (.data.providerErrorTerminal.result.structuredContent |
     (.state == "failed") and
     (.message == "Claude: provider returned an error")) and
   (.data.providerErrorResult.result |
     (.isError == true) and
     (.structuredContent.state == "failed") and
     (.structuredContent.resultAvailable == false)) and
   ((.frames | tostring) | contains("SENTINEL_PROVIDER_ERROR") | not) and
   (.stderr | contains("SENTINEL_PROVIDER_ERROR") | not) and
   (.data.pings[-1].result.content[0].text == "pong")'

test_claude_job \
  "Claude status progress uses the supplied token and exposes only sanitized phase text" \
  "progress" \
  '([.frames[] |
      select(.method == "notifications/progress")] as $progress |
     ($progress | length == 2) and
     ($progress[1].params.progress > $progress[0].params.progress) and
     ($progress | all(
       (.params.progressToken == "claude-progress-token") and
       (.params.progress | type == "number") and
       (.params.message | startswith("Claude: ")) and
       (.params.message | contains("SENTINEL") | not)))) and
   (.data.progressStatus.result.structuredContent.state == "running") and
   (.data.progressTerminal.result.structuredContent.state == "canceled")'

test_claude_job \
  "disconnecting with a live Claude job interrupts and reaps its process" \
  "disconnect" \
  '(.captures | length == 1) and
   (.data.disconnectStatus.result.structuredContent.state == "running") and
   (.captures[0] |
     (.alive == false) and
     (.signals | index("CONTROL_INTERRUPT") != null) and
     ([.stdinParsed[] |
       select(.type == "control_request" and
         .request.subtype == "interrupt")] | length == 1))'

test_claude_job \
  "Claude results page by Unicode code point without splitting astral text" \
  "paging" \
  '(.data.pageMetrics ==
     [{"contentCodePoints":32768,
       "structuredCodePoints":32768,
       "equal":true,
       "allRocket":true,
       "offset":0,
       "nextOffset":32768,
       "endOffset":32780,
       "done":false},
      {"contentCodePoints":12,
       "structuredCodePoints":12,
       "equal":true,
       "allRocket":true,
       "offset":32768,
       "nextOffset":32780,
       "endOffset":32780,
       "done":true}])'

test_claude_job \
  "Claude rejects an atomic result over 10 MiB without leaking it through MCP" \
  "oversize" \
  '(.data.oversizeTerminal.result.structuredContent |
     (.state == "failed") and
     (.message | contains("10 MiB"))) and
   (.data.oversizeResult.result |
     (.isError == true) and
     (.structuredContent.state == "failed") and
     (.structuredContent.resultAvailable == false)) and
   ((.frames | tostring | length) < 100000) and
   (.data.pings[-1].result.content[0].text == "pong")'

test_claude_job \
  "Claude terminal jobs expire from connection-local retention" \
  "retention" \
  '(.data.expired.result |
     (.isError == true) and
     (.structuredContent.code == "job_not_found")) and
   (.data.pings[-1].result.content[0].text == "pong")'

test_claude_job \
  "Claude active-job capacity rejects excess work without spawning it" \
  "capacity" \
  '(.captures | length == 2) and
   (.data.capacityRejected.result |
     (.isError == true) and
     (.structuredContent.code == "job_capacity_full") and
     (.structuredContent.activeJobs == 2) and
     (.structuredContent.maxActiveJobs == 2)) and
   ([.data.statuses[].result.structuredContent.state |
     select(. == "canceled")] | length >= 2) and
   (.data.pings[-1].result.content[0].text == "pong")'

test_claude_job \
  "Claude retained-job capacity evicts collected terminal results at the bound" \
  "retained" \
  '(.captures | length == 3) and
   (.data.evicted.result |
     (.isError == true) and
     (.structuredContent.code == "job_not_found")) and
   (.data.stillRetained.result.structuredContent.state == "completed") and
   ([.data.results[].result.structuredContent |
     select(.state == "completed" and .done == true)] | length == 3)'

# Stub-based strict Codex contract tests (fast — no real Codex needed).
test_codex_home_location_and_permissions \
  "codex bridge uses a private project-local home root"
test_codex_bridge_config \
  "codex bridge enables workspace network by default" \
  "true" "" "__unset__"
test_codex_bridge_config \
  "codex bridge disables workspace network from CLI" \
  "false" "--codex-workspace-network=false" "__unset__"
test_codex_bridge_config \
  "codex bridge disables workspace network from env" \
  "false" "" "false"
test_codex_bridge_config \
  "codex workspace network CLI overrides env" \
  "true" "--codex-workspace-network true" "false"
test_codex_bridge_config \
  "codex bridge mirrors explicit Fast-mode opt-in" \
  "true" "" "__unset__" \
  $'basic_decoy = """quoted""""\nliteral_decoy = \'\'\'quoted\'\'\'\'\nservice_tier = "fast" # explicit opt-in\ndo_not_copy = true\n\n[ features ]\nfast_mode = true # explicit opt-in\n\n[mcp_servers.sentinel]\ncommand = "do_not_copy"' \
  "true"
test_codex_bridge_config \
  "codex bridge rejects service-tier-only Fast mode" \
  "true" "" "__unset__" \
  'service_tier = "fast"' \
  "false"
test_codex_bridge_config \
  "codex bridge rejects feature-only Fast mode" \
  "true" "" "__unset__" \
  $'[features]\nfast_mode = true' \
  "false"
test_codex_bridge_config \
  "codex bridge rejects a disabled Fast-mode feature" \
  "true" "" "__unset__" \
  $'service_tier = "fast"\n\n[features]\nfast_mode = false' \
  "false"
test_codex_bridge_config \
  "codex bridge rejects a non-fast service tier" \
  "true" "" "__unset__" \
  $'service_tier = "flex"\n\n[features]\nfast_mode = true' \
  "false"
test_codex_bridge_config \
  "codex bridge ignores commented, nested, and multiline decoys" \
  "true" "" "__unset__" \
  $'# service_tier = "fast"\ndeveloper_instructions = """\nservice_tier = "fast"\n[features]\nfast_mode = true\n"""\n\n[profiles.fast]\nservice_tier = "fast"\n\n[features.child]\nfast_mode = true' \
  "false"
test_codex_bridge_config \
  "codex bridge rejects ambiguous duplicate Fast settings" \
  "true" "" "__unset__" \
  $'service_tier = "fast"\nservice_tier = "fast"\n\n[features]\nfast_mode = true' \
  "false"
test_codex_bridge_config \
  "codex bridge rejects duplicate Fast-mode features" \
  "true" "" "__unset__" \
  $'service_tier = "fast"\n\n[features]\nfast_mode = true\nfast_mode = true' \
  "false"
test_codex_bridge_config \
  "codex bridge survives unreadable source Fast-mode config" \
  "true" "" "__unset__" \
  "__read_error__" \
  "false"
# The [agents] enabled=false off switch is version-gated: 0.102–0.144 route a
# boolean under [agents] into the flattened role map and hard-fail config
# parsing, so the table must be absent there (the feature flag still gates the
# collab tools on those versions). Unknown versions assume modern codex.
export MCP_STUB_CODEX_VERSION="codex-cli 0.130.0"
test_codex_bridge_config \
  "codex bridge omits the agents table on codex 0.130" \
  "true" "" "__unset__" \
  "" \
  "false" \
  "absent"
export MCP_STUB_CODEX_VERSION="codex-cli 0.144.9"
test_codex_bridge_config \
  "codex bridge omits the agents table on codex 0.144" \
  "true" "" "__unset__" \
  "" \
  "false" \
  "absent"
export MCP_STUB_CODEX_VERSION="codex-cli 1.2.3"
test_codex_bridge_config \
  "codex bridge keeps the agents off switch on codex 1.2.3" \
  "true" "" "__unset__" \
  "" \
  "false" \
  "present"
export MCP_STUB_CODEX_VERSION="not-a-version"
test_codex_bridge_config \
  "codex bridge assumes modern codex on an unknown version" \
  "true" "" "__unset__" \
  "" \
  "false" \
  "present"
unset MCP_STUB_CODEX_VERSION
test_codex_auth_persistence_secure_temp "codex auth write-back uses secure exclusive temp"
test_codex_auth_persistence_conflict "codex auth write-back preserves a newer canonical login"
test_codex_call_passes_through_unmodified \
  "codex-reply forwards an accepted no-goal call byte-for-byte" \
  "codex-reply" \
  '{"prompt":"höhö 日本語 🚀 — ünïcödé","threadId":"thread-123"}'
test_codex_call_passes_through_unmodified \
  "codex forwards omitted selectors byte-for-byte" \
  "codex" \
  '{"prompt":"höhö 日本語 🚀 — ünïcödé","cwd":"/tmp/work","sandbox":"read-only"}'

# Accepted initial calls preserve a curated model, translate effort into native
# config, and may inject goal.
test_codex_call_transform "codex forwards per-session Sol model with medium effort" \
  "" \
  '{"prompt":"hi","cwd":"/tmp/work","sandbox":"read-only","model":"gpt-5.6-sol","model_reasoning_effort":"medium"}' \
  '.params.arguments | ((has("model_reasoning_effort")|not) and (.model == "gpt-5.6-sol") and (.cwd == "/tmp/work") and (.sandbox == "read-only") and (.config == {"model_reasoning_effort":"medium"}))'
test_codex_call_transform "codex forwards per-session Terra model with high effort" \
  "" \
  '{"prompt":"hi","cwd":"/tmp/work","sandbox":"workspace-write","model":"gpt-5.6-terra","model_reasoning_effort":"high"}' \
  '.params.arguments | ((has("model_reasoning_effort")|not) and (.model == "gpt-5.6-terra") and (.config == {"model_reasoning_effort":"high"}))'
test_codex_call_transform "codex translates per-session max effort without model override" \
  "" \
  '{"prompt":"hi","cwd":"/tmp/work","sandbox":"workspace-write","model_reasoning_effort":"max"}' \
  '.params.arguments | ((has("model_reasoning_effort")|not) and (has("model")|not) and (.config == {"model_reasoning_effort":"max"}))'
test_codex_call_transform "codex preserves omitted selectors for native defaults" \
  "" \
  '{"prompt":"hi","cwd":"/tmp/work","sandbox":"read-only"}' \
  '.params.arguments | ((has("model")|not) and (has("model_reasoning_effort")|not) and (has("config")|not))'
test_codex_call_transform "codex composes per-session max effort with goal" \
  "" \
  '{"prompt":"hi","cwd":"/tmp/work","sandbox":"workspace-write","model_reasoning_effort":"max","goal":"SHIPSAFE"}' \
  '.params.arguments | ((has("model_reasoning_effort")|not) and (has("goal")|not) and (.config == {"model_reasoning_effort":"max"}) and (.["developer-instructions"]|test("SHIPSAFE")))'

test_codex_call_transform "codex injects per-call goal into developer-instructions" \
  "" \
  '{"prompt":"hi","cwd":"/tmp/work","sandbox":"workspace-write","model_reasoning_effort":"xhigh","goal":"SHIPSAFE"}' \
  '.params.arguments | ((has("goal")|not) and (.prompt == "hi") and (.["developer-instructions"]|test("SHIPSAFE")))'
test_codex_call_transform "codex injects server --goal into developer-instructions" \
  "--goal SERVERGOAL" \
  '{"prompt":"hi","cwd":"/tmp/work","sandbox":"workspace-write","model_reasoning_effort":"xhigh"}' \
  '.params.arguments | ((.prompt == "hi") and (.["developer-instructions"]|test("SERVERGOAL")))'
test_codex_call_transform "codex per-call goal overrides server --goal" \
  "--goal SERVERGOAL" \
  '{"prompt":"hi","cwd":"/tmp/work","sandbox":"workspace-write","model_reasoning_effort":"xhigh","goal":"CALLGOAL"}' \
  '.params.arguments | ((has("goal")|not) and (.["developer-instructions"]|test("CALLGOAL")) and (.["developer-instructions"]|test("SERVERGOAL")|not))'
test_codex_call_transform "codex blank per-call goal suppresses server --goal" \
  "--goal SERVERGOAL" \
  '{"prompt":"hi","cwd":"/tmp/work","sandbox":"workspace-write","model_reasoning_effort":"xhigh","goal":""}' \
  '.params.arguments | ((has("goal")|not) and (.prompt == "hi") and (has("developer-instructions")|not))'
test_codex_call_transform "codex-reply injects per-call goal as prompt reminder" \
  "" \
  '{"threadId":"abc","prompt":"continue","goal":"STAYFOCUSED"}' \
  '.params.arguments | ((has("goal")|not) and (.threadId == "abc") and (has("developer-instructions")|not) and (.prompt|startswith("Reminder")) and (.prompt|test("continue")) and ((.prompt|index("STAYFOCUSED")) < (.prompt|index("continue"))))' \
  "codex-reply"
test_codex_call_transform "codex injects multi-word per-call goal" \
  "" \
  '{"prompt":"hi","cwd":"/tmp/work","sandbox":"workspace-write","model_reasoning_effort":"xhigh","goal":"keep the public API unchanged"}' \
  '.params.arguments | (.["developer-instructions"]|test("keep the public API unchanged"))'

# allow_subagents is wrapper-only: always stripped; only `true` becomes the
# native per-call override features.multi_agent. The isolated home config keeps
# multi_agent = false and no [mcp_servers] regardless (asserted by the bridge
# config tests above), so enabling it can never re-open MCP delegation.
test_codex_call_transform "codex allow_subagents=true injects both subagent overrides" \
  "" \
  '{"prompt":"hi","cwd":"/tmp/work","sandbox":"workspace-write","allow_subagents":true}' \
  '.params.arguments | ((has("allow_subagents")|not) and (.config == {"features.multi_agent":true,"agents.enabled":true}))'
test_codex_call_transform "codex allow_subagents=false is stripped with no override" \
  "" \
  '{"prompt":"hi","cwd":"/tmp/work","sandbox":"workspace-write","allow_subagents":false}' \
  '.params.arguments | ((has("allow_subagents")|not) and (has("config")|not))'
test_codex_call_transform "codex composes allow_subagents with per-session effort" \
  "" \
  '{"prompt":"hi","cwd":"/tmp/work","sandbox":"workspace-write","model_reasoning_effort":"max","allow_subagents":true}' \
  '.params.arguments | ((has("allow_subagents")|not) and (has("model_reasoning_effort")|not) and (.config == {"model_reasoning_effort":"max","features.multi_agent":true,"agents.enabled":true}))'
test_codex_call_transform "codex-start strips allow_subagents into the private job config" \
  "" \
  '{"prompt":"hi","cwd":"/tmp/work","sandbox":"workspace-write","allow_subagents":true}' \
  '(.params.name == "codex") and (.params.arguments | ((has("allow_subagents")|not) and (.config == {"features.multi_agent":true,"agents.enabled":true})))' \
  "codex-start"
# On pre-0.145 codex the agents.enabled override would be a fatal config type
# error at the native layer, so the opt-in injects the feature flag only.
export MCP_STUB_CODEX_VERSION="codex-cli 0.130.0"
test_codex_call_transform "codex allow_subagents on codex 0.130 injects the feature flag only" \
  "" \
  '{"prompt":"hi","cwd":"/tmp/work","sandbox":"workspace-write","allow_subagents":true}' \
  '.params.arguments | ((has("allow_subagents")|not) and (.config == {"features.multi_agent":true}))'
unset MCP_STUB_CODEX_VERSION

# Forbidden, missing, malformed, and deprecated arguments fail before Codex runs.
test_codex_rejects_call "codex rejects hidden native configuration" \
  '{"prompt":"hi","cwd":"/tmp/work","sandbox":"read-only","model_reasoning_effort":"xhigh","model":"STRICT_SECRET_MODEL","config":{"secret":"STRICT_SECRET_CONFIG"},"approval-policy":"never","developer-instructions":"STRICT_SECRET_DEV","base-instructions":"STRICT_SECRET_BASE","compact-prompt":"STRICT_SECRET_COMPACT"}' \
  '(.error.data.issues | map(.argument) | sort) == ["approval-policy","base-instructions","compact-prompt","config","developer-instructions","model"]'
test_codex_rejects_call "codex rejects missing required arguments" \
  '{"prompt":"hi"}' \
  '(.error.data.issues | map(.argument) | sort) == ["cwd","sandbox"]'
test_codex_rejects_call "codex rejects malformed operational arguments" \
  '{"prompt":false,"cwd":"relative/path","sandbox":"escape","model":"gpt-5.6-luna","model_reasoning_effort":"ultra","goal":false,"allow_subagents":"yes"}' \
  '(.error.data.issues | map(.argument) | sort) == ["allow_subagents","cwd","goal","model","model_reasoning_effort","prompt","sandbox"]'
test_codex_rejects_call "codex rejects a non-object arguments value" \
  'null' \
  '(.error.data.issues == [{"argument":"arguments","problem":"must be an object"}])'
test_codex_rejects_call "codex-reply requires threadId and rejects conversationId" \
  '{"prompt":"continue","conversationId":"legacy"}' \
  '(.error.data.issues | map(.argument) | sort) == ["conversationId","threadId"]' \
  "codex-reply"
test_codex_rejects_call "codex-reply rejects inherited session controls" \
  '{"prompt":"continue","threadId":"abc","sandbox":"read-only","model":"gpt-5.6-terra","model_reasoning_effort":"max","cwd":"/tmp/work","allow_subagents":true}' \
  '(.error.data.issues | map(.argument) | sort) == ["allow_subagents","cwd","model","model_reasoning_effort","sandbox"]' \
  "codex-reply"
test_codex_rejects_call "codex-status rejects missing cursor and invalid wait" \
  '{"jobId":"job","wait_ms":60001}' \
  '(.error.data.issues | map(.argument) | sort) == ["cursor","wait_ms"]' \
  "codex-status"
test_codex_rejects_call "codex-commentary rejects malformed job and offset" \
  '{"jobId":"","offset":-1}' \
  '(.error.data.issues | map(.argument) | sort) == ["jobId","offset"]' \
  "codex-commentary"
test_codex_local_response_lifecycle "codex local validation responses remain frame-safe and cancelable"

# Stub-based Codex tools/list schema tests (fast — no real Codex needed).
# The wrapper rewrites ONLY the tools/list RESPONSE to advertise its curated
# contract; everything else stays byte-for-byte.
test_codex_toolslist_rewrite "tools/list advertises exact curated argument sets" \
  "normal" \
  'select(.id==2) | ((.result.tools|map(select(.name=="codex"))[0].inputSchema.properties|keys) == ["allow_subagents","cwd","goal","model","model_reasoning_effort","prompt","sandbox"] and (.result.tools|map(select(.name=="codex-reply"))[0].inputSchema.properties|keys) == ["goal","prompt","threadId"])'
test_codex_toolslist_rewrite "tools/list advertises all optional Codex job tools" \
  "normal" \
  'select(.id==2) | ([.result.tools[].name | select(startswith("codex-"))] | sort) == ["codex-cancel","codex-commentary","codex-peek","codex-reply","codex-reply-start","codex-result","codex-start","codex-status"]'
test_codex_toolslist_rewrite "codex-peek advertises a closed, wholly optional filter schema" \
  "normal" \
  'select(.id==2) | (.result.tools|map(select(.name=="codex-peek"))[0].inputSchema |
    (.additionalProperties == false) and (.required == []) and
    ((.properties|keys) == ["cwd","requestId","threadId"]))'
test_codex_peek "codex-peek reports a parked turn with its identity and workspace" \
  '{}' \
  'select(.id==4) | .result.structuredContent as $s |
   ($s.count == 1) and ($s.ambiguous == false) and
   ($s.turns[0] | (.tool == "codex") and (.cwd == "/tmp/peek-workspace") and
     (.sandbox == "workspace-write") and (.cwdInferred == false) and
     (.threadId == "0199aaaa-bbbb-cccc-dddd-eeeeffff0000") and
     (has("requestId")) and (has("elapsedSeconds")) and (has("lastActivitySeconds")))'
test_codex_peek "codex-peek never returns the prompt" \
  '{}' \
  'select(.id==4) | (.result | tostring | contains("build it") | not)'
test_codex_peek "codex-peek honours a cwd filter" \
  '{"cwd":"/tmp/peek-workspace"}' \
  'select(.id==4) | (.result.structuredContent.count == 1)'
test_codex_peek "an empty codex-peek warns that absence is not termination" \
  '{"cwd":"/tmp/somewhere-else"}' \
  'select(.id==4) | (.result.structuredContent.count == 0) and
   (.result.content[0].text | contains("not evidence"))'
test_codex_peek "codex-peek rejects a non-string requestId instead of ignoring it" \
  '{"requestId":4}' \
  'select(.id==4) | (.error.code == -32602) or
   (.result.isError == true) or
   ((.result.structuredContent.issues // []) | any(.argument == "requestId"))'
test_codex_peek_reply "a codex-reply turn reports the workspace inherited from its thread" \
  'select(.id==5) | .result.structuredContent as $s |
   ($s.count == 2) and
   ($s.turns | map(select(.tool == "codex-reply")) | length == 1) and
   ($s.turns[] | select(.tool == "codex-reply") |
     (.cwd == "/tmp/peek-workspace") and (.cwdInferred == true) and
     (.threadId == "0199aaaa-bbbb-cccc-dddd-eeeeffff0000") and (.state == "running")) and
   ($s.turns[] | select(.tool == "codex") | .cwdInferred == false)'
test_codex_abandoned_ledger "an abandoned blocking turn is counted, not forgotten" \
  "codex" \
  'select(.id==9) | .result.structuredContent.abandonedTurnsProcessWide >= 1'
test_codex_abandoned_ledger "an abandoned background JOB is counted too" \
  "codex-start" \
  'select(.id==9) | .result.structuredContent.abandonedTurnsProcessWide >= 1'
test_codex_abandoned_ledger "a late native response SETTLES the abandonment, so the count returns to zero" \
  "codex" \
  'select(.id==9) | .result.structuredContent.abandonedTurnsProcessWide == 0' \
  5000
test_codex_abandoned_ledger "a late response settles an abandoned JOB too, not just a blocking call" \
  "codex-start" \
  'select(.id==9) | .result.structuredContent.abandonedTurnsProcessWide == 0' \
  5000
test_codex_peek_job "a background job is addressed by jobId and never leaks the private request id" \
  'select(.id==4) | .result.structuredContent as $s |
   ($s.count == 1) and
   ($s.turns[0] | (.tool == "codex") and (has("jobId")) and (has("requestId") | not) and
     (.cwd == "/tmp/job-workspace")) and
   (.result | tostring | contains("mcp-agents/job/") | not)'
test_codex_toolslist_rewrite "Codex job tools use exact closed schemas" \
  "normal" \
  'select(.id==2) | (.result.tools | map({key:.name,value:.}) | from_entries) as $t |
   (($t["codex-start"].inputSchema == $t.codex.inputSchema) and
    ($t["codex-reply-start"].inputSchema == $t["codex-reply"].inputSchema) and
    ($t["codex-status"].inputSchema | (.additionalProperties == false) and (.required == ["jobId","cursor"]) and (.properties.wait_ms.maximum == 60000)) and
    ($t["codex-commentary"].inputSchema | (.additionalProperties == false) and (.required == ["jobId"])) and
    ($t["codex-result"].inputSchema | (.additionalProperties == false) and (.required == ["jobId"])) and
    ($t["codex-cancel"].inputSchema | (.additionalProperties == false) and (.required == ["jobId"])))'
test_codex_toolslist_rewrite "tools/list advertises exact Sol|Terra model on codex only" \
  "normal" \
  'select(.id==2) | ((.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.model | ((.type == "string") and (.enum == ["gpt-5.6-sol","gpt-5.6-terra"]) and (has("default")|not))) and (.result.tools|map(select(.name=="codex-reply"))[0].inputSchema.properties|has("model")|not))'
test_codex_toolslist_rewrite "tools/list advertises exact medium|high|xhigh|max effort on codex only" \
  "normal" \
  'select(.id==2) | ((.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.model_reasoning_effort | ((.type == "string") and (.enum == ["medium","high","xhigh","max"]) and (has("default")|not))) and (.result.tools|map(select(.name=="codex-reply"))[0].inputSchema.properties|has("model_reasoning_effort")|not))'
test_codex_toolslist_rewrite "tools/list advertises boolean allow_subagents on session-start tools only" \
  "normal" \
  'select(.id==2) | (.result.tools | map({key:.name,value:.}) | from_entries) as $t |
   (($t.codex.inputSchema.properties.allow_subagents | ((.type == "boolean") and (has("default")|not) and (.description|test("default false")))) and
    ($t["codex-start"].inputSchema.properties.allow_subagents.type == "boolean") and
    ($t["codex-reply"].inputSchema.properties|has("allow_subagents")|not) and
    ($t["codex-reply-start"].inputSchema.properties|has("allow_subagents")|not) and
    (($t.codex.inputSchema.required|sort) == ["cwd","prompt","sandbox"]))'
test_codex_toolslist_rewrite "tools/list explains model, effort, and reply inheritance" \
  "normal" \
  'select(.id==2) | (.result.tools|map(select(.name=="codex"))[0].inputSchema.properties) as $p | (($p.model.description|test("gpt-5.6-sol.*demanding")) and ($p.model.description|test("gpt-5.6-terra.*faster")) and ($p.model.description|test("repl.*inherit")) and ($p.model_reasoning_effort.description|ascii_downcase|test("medium.*balanced.*high.*complex.*xhigh.*hard.*max.*quality-first.*repl.*inherit")))'
# If upstream Codex starts declaring this property itself, mcp-agents still
# owns the policy: constrain codex to the four allowed values and remove the
# property from codex-reply rather than exposing upstream drift such as ultra.
test_codex_toolslist_rewrite "tools/list constrains drifted upstream effort schema" \
  "haveeffort" \
  'select(.id==2) | ((.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.model_reasoning_effort | ((.type == "string") and (.enum == ["medium","high","xhigh","max"]) and (.description != "STUB_DRIFTED_EFFORT_DESC"))) and (.result.tools|map(select(.name=="codex-reply"))[0].inputSchema.properties|has("model_reasoning_effort")|not))'
test_codex_toolslist_rewrite "tools/list makes both schemas closed and operational fields required" \
  "normal" \
  'select(.id==2) | ((.result.tools|map(select(.name=="codex"))[0].inputSchema | ((.additionalProperties == false) and ((.required|sort) == ["cwd","prompt","sandbox"]))) and (.result.tools|map(select(.name=="codex-reply"))[0].inputSchema | ((.additionalProperties == false) and ((.required|sort) == ["prompt","threadId"]))))'
test_codex_toolslist_rewrite "tools/list advertises exact sandbox choices" \
  "normal" \
  'select(.id==2) | (.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.sandbox.enum == ["read-only","workspace-write","danger-full-access"])'
test_codex_toolslist_rewrite "tools/list curates model and hides native config and future drift" \
  "normal" \
  'select(.id==2) | ((.result.tools|map(select(.name=="codex"))[0].inputSchema.properties | (.model.enum == ["gpt-5.6-sol","gpt-5.6-terra"]) and (has("approval-policy")|not) and (has("base-instructions")|not) and (has("compact-prompt")|not) and (has("config")|not) and (has("developer-instructions")|not) and (has("future_upstream_setting")|not)) and (.result.tools|map(select(.name=="codex-reply"))[0].inputSchema.properties | (has("conversationId")|not) and (has("future_reply_setting")|not)))'
test_codex_toolslist_rewrite "tools/list keeps workspace network server-owned" \
  "normal" \
  'select(.id==2) | [.result.tools[] | select(.name == "codex" or .name == "codex-start" or .name == "codex-reply" or .name == "codex-reply-start") | .inputSchema.properties | ((has("network_access")|not) and (has("codex_workspace_network_access")|not) and (has("codex-workspace-network")|not))] | all'
test_codex_toolslist_rewrite "tools/list preserves non-schema tool metadata" \
  "normal" \
  'select(.id==2) | (.result.tools|map(select(.name=="codex"))[0] | ((.title == "Native Codex title") and (.annotations.readOnlyHint == false) and (.outputSchema.type == "object") and (.description | test("Config struct") | not)))'
test_codex_toolslist_rewrite "tools/list forwards interleaved notification byte-for-byte + rewrites result" \
  "interleaved" \
  'select(.id==2) | (.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal.type=="string")' \
  '{"jsonrpc":"2.0","method":"codex/event","params":{"marker":"PASSTHROUGH_SENTINEL"}}'
test_codex_toolslist_rewrite "tools/list reassembles a split frame and rewrites it" \
  "split" \
  'select(.id==2) | (.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal.type=="string")'
test_codex_toolslist_reentry "tools/list latch re-entry: two calls both rewritten"
test_codex_toolslist_rewrite "tools/list replaces drifted upstream goal schema" \
  "havegoal" \
  'select(.id==2) | (.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal | ((.type == "string") and (.description != "STUB_OWN_GOAL_DESC")))'
test_codex_toolslist_rewrite "tools/list with no codex tools forwarded byte-for-byte" \
  "noctools" \
  'select(.id==2) | ((.result.tools|length==1) and (.result.tools[0].name=="ping") and (.result.tools[0].inputSchema.properties|has("goal")|not) and (.result.tools[0].inputSchema.properties|has("model_reasoning_effort")|not))'
test_codex_toolslist_rewrite "tools/list error response forwarded unchanged" \
  "error" \
  'select(.id==2) | (.error.code==-32601)'
test_codex_toolslist_rewrite "tools/list partial-then-die yields one -32001 (no hang)" \
  "partialdie" \
  'select(.id==2) | (has("error") and .error.code==-32001)'
test_codex_toolslist_rewrite "tools/list finalize recovers a complete-but-unterminated frame" \
  "nonewlinedie" \
  'select(.id==2) | (.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal.type=="string")'
test_codex_toolslist_backpressure "tools/list both responses survive backpressure (no strand)"
test_codex_toolslist_rewrite "tools/list mode-boundary straddle reassembled byte-for-byte + rewritten" \
  "straddle" \
  'select(.id==2) | (.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal.type=="string")' \
  '{"jsonrpc":"2.0","method":"codex/event","params":{"marker":"STRADDLE_SENTINEL"}}'
# Latch-boundary return-to-raw: a trailing NON-tools/list partial after the
# rewritten result must be forwarded raw (not withheld/byte-lost) when codex dies.
test_codex_toolslist_file "tools/list trailing partial after result is forwarded raw (not lost)" \
  "trailpartialdie" \
  '.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal.type=="string"' \
  "TRAILING_HEAD"
# Oversized (>10 MiB) frame in the latch window is forwarded raw without parsing,
# and the subsequent tools/list result is still rewritten.
test_codex_toolslist_file "tools/list oversized frame forwarded raw, result still rewritten" \
  "oversized" \
  '.result.tools|map(select(.name=="codex"))[0].inputSchema.properties.goal.type=="string"' \
  "OVERSIZED_MARKER"
# Cancel path: a tools/list cancel that empties the latch while a non-tools/list
# partial is withheld must flush it raw (not byte-lose it when codex then dies).
test_codex_toolslist_cancel "tools/list cancel flushes a withheld partial raw (not lost)"

# Stub-based per-request Codex lifecycle tests.
# A per-request idle/hard timeout aborts ONLY that request (one -32001) and
# keeps the bridge connected — it no longer finalize()s the whole process. So
# the wrapper now exits cleanly (code 0) when the driver closes stdin, NOT with
# code 1 at the timeout, and the "stayed connected" message signature must hold.
test_codex_lifecycle "codex stderr does not reset request idle deadline" \
  "stderr" "0.3" "2" "1000" "80" "100" "0" \
  '(.code == 0) and (.stubAlive == false) and
   ([.frames[] | select(.id == 2 and .error.code == -32001 and (.error.message | ascii_downcase | contains("idle")) and (.error.message | ascii_downcase | contains("stayed connected")))] | length == 1) and
   ([.frames[] | select(.id == 2 and has("result"))] | length == 0)'
test_codex_lifecycle "codex interprets typed auth failure and latches new turns" \
  "authfailure" "2" "2" "650" "80" "100" "0" \
  '(.code == 0) and (.stubAlive == false) and (.parseErrors == 0) and
   (.calls | length == 1) and (.calls[0].id == 2) and
   ([.frames[] | select(.method == "codex/event" and .params.msg.codex_error_info == "unauthorized")] | length == 0) and
   ([.frames[] | select(.id == 2 and .result.isError == true and
     .result.structuredContent.code == "codex_auth_invalidated" and
     .result.structuredContent.action == "reauthenticate_and_restart")] | length == 1) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
     .result.structuredContent.code == "codex_auth_invalidated")] | length == 1) and
   ([.frames[] | select(.id == 100 and has("result"))] | length == 1) and
   ([.frames[] | select(.id == 101 and .result.structuredContent.count == 0)] | length == 1) and
   ((.frames | tostring | contains("refresh token was revoked")) | not)'
test_codex_auth_failure_never_persists \
  "codex never writes known-invalidated isolated auth back to canonical"
test_codex_auth_failure_never_persists \
  "canceled Codex auth failure still blocks invalid auth write-back" \
  "authcancelunterminatedexit"
test_codex_lifecycle "codex auth latch lets an already-running sibling finish" \
  "authconcurrent" "2" "2" "500" "80" "100" "0" \
  '(.code == 0) and (.stubAlive == false) and
   ([.calls[] | select(.id == 2 or .id == 3)] | length == 2) and
   ([.calls[] | select(.id == 4)] | length == 0) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.code == "codex_auth_invalidated")] | length == 1) and
   ([.frames[] | select(.id == 3 and .result.structuredContent.content == "ALREADY_RUNNING_SURVIVED")] | length == 1) and
   ([.frames[] | select(.id == 4 and .result.structuredContent.code == "codex_auth_invalidated")] | length == 1)'
test_codex_lifecycle "successful Codex output mentioning revoked auth stays untouched" \
  "authtextsuccess" "2" "2" "300" "80" "100" "0" \
  '(.code == 0) and (.stubAlive == false) and
   ([.frames[] | select(.id == 2 and .result.isError != true and
     (.result.structuredContent.content | contains("refresh token was revoked")))] | length == 1)'
test_codex_lifecycle "codex recovers an unterminated auth result during child exit" \
  "authunterminatedexit" "2" "2" "500" "80" "100" "0" \
  '(.code == 0) and (.stubAlive == false) and (.parseErrors == 0) and
   ([.frames[] | select(.method == "codex/event" and .params.msg.codex_error_info == "unauthorized")] | length == 0) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.code == "codex_auth_invalidated")] | length == 1)'
# Proof the transport SURVIVES the timeout: after id 2 idles out, the bridge
# keeps answering the driver's ping flood (ids >= 100) — many round-trips, not one.
test_codex_lifecycle "codex unrelated pings/events do not reset request idle deadline" \
  "unrelated" "0.3" "2" "1000" "80" "100" "0" \
  '(.code == 0) and (.stubAlive == false) and
   ([.frames[] | select(.id == 2 and .error.code == -32001 and (.error.message | ascii_downcase | contains("idle")))] | length == 1) and
   ([.frames[] | select((.id // 0) >= 100 and has("result"))] | length >= 5)'
test_codex_lifecycle "codex matching events extend idle and progress uses supplied token only" \
  "progress" "0.3" "2" "1000" "80" "100" "60" \
  '(.code == 0) and (.stubAlive == false) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "PROGRESS_2")] | length == 1) and
   ([.frames[] | select(.id == 3 and .result.structuredContent.content == "PROGRESS_3")] | length == 1) and
   ([.frames[] | select(.method == "notifications/progress")] as $p |
     (($p | length) >= 1) and ([$p[] | select(.params.progressToken != "progress-3")] | length == 0))'
test_codex_lifecycle "codex progress accepts string/numeric tokens and rejects missing/invalid tokens" \
  "tokens" "0.5" "2" "350" "80" "100" "20" \
  '(.code == 0) and
   ([.frames[] | select(.id >= 2 and .id <= 5 and has("result"))] | length == 4) and
   ([.frames[] | select(.method == "notifications/progress") | .params.progressToken] | sort) == [42, "string-token"]'
test_codex_lifecycle "codex progress allowlist exposes useful status and redacts hostile fields" \
  "visibility" "1" "2" "750" "80" "100" "30" \
  '(.code == 0) and (.parseErrors == 0) and
   ([.frames[] | select(.method == "notifications/progress" and .params.progressToken == "visibility-2")] as $p |
     ($p | length) >= 7 and
     ([$p[].params.progress] as $seq | ($seq == ($seq | sort)) and (($seq | unique | length) == ($seq | length))) and
     ([$p[].params.message] | all((length <= 200) and startswith("Codex: "))) and
     (([$p[].params.message] | join(" ")) as $messages |
       ($messages | contains("Working on tests 🚀")) and
       ($messages | contains("working on: Verify bridge")) and
       ($messages | contains("running a command")) and
       ($messages | contains("command finished (exit 7)")) and
       ($messages | contains("applying changes to 2 file(s)")) and
       ($messages | contains("calling safe-server/safe-tool")) and
       ($messages | contains("web search finished")) and
       ($messages | contains("subagent activity")) and
       ($messages | contains("Completed commentary")) and
       ($messages | contains("SENTINEL_") | not)))'
test_codex_lifecycle "codex progress is immediate then coalesces latest distinct status" \
  "coalesce" "0.5" "2" "350" "80" "100" "80" \
  '(.code == 0) and
   ([.frames[] | select(.method == "notifications/progress") | .params.message] ==
     ["Codex: started", "Codex: working on: Latest status"])'
# Silence notices must not extend the idle deadline: the idle -32001 still fires
# (proof it wasn't extended). Process exit is now driven by the driver closing
# stdin (settle), not by the timeout, so the old idle-timed elapsed bound is gone.
test_codex_lifecycle "codex silence notices report event age without extending idle" \
  "wait" "1.25" "3" "2400" "80" "100" "20,250" \
  '(.code == 0) and
   ([.frames[] | select(.method == "notifications/progress") | .params.message] as $messages |
     ($messages | any(contains("still running; last activity 0s ago"))) and
     ($messages | any(contains("still running; last activity 1s ago")))) and
   ([.frames[] | select(.id == 2 and .error.code == -32001 and (.error.message | ascii_downcase | contains("idle")))] | length == 1)'
test_codex_lifecycle "codex progress waits for a safe boundary and keeps only the latest frame" \
  "partial" "0.5" "2" "600" "80" "100" "20,60" \
  '(.code == 0) and (.parseErrors == 0) and
   ([.frames[] | select(.method == "notifications/progress")] | length == 1) and
   ([.frames[] | select(.method == "notifications/progress") | .params.message | contains("still running")] | all) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "PARTIAL")] | length == 1)'
# Permanent partial stall: the idle abort has NO safe frame boundary to inject at
# (codex is wedged mid-partial-frame), so it must never splice a frame into the
# partial (rawHasProgress==false) and instead DEFERS. Because this codex ignores
# the cancellation too, the deferred abort escalates to a bounded teardown after
# the cancel grace — the only safe resolution for a mid-frame wedge: exactly one
# -32001 for id 2, no result, exit code 1. A codex that resolved the partial
# would instead keep the transport alive (see the "survive" test below).
test_codex_lifecycle "codex permanent partial stall never splices progress and escalates to a bounded teardown" \
  "partialstall" "0.25" "2" "1500" "80" "100" "20,60" \
  '(.code == 1) and (.rawHasProgress == false) and (.elapsedMs < 1800) and
   ([.frames[] | select(.id == 2 and .error.code == -32001)] | length == 1) and
   ([.frames[] | select(.id == 2 and has("result"))] | length == 0)'
# The core guarantee, proven end to end: id 2 idles out with a -32001, and only
# THEN is id 3 issued — its real result proves the bridge stayed connected and
# served a brand-new call after the first one timed out (no whole-process exit).
test_codex_lifecycle "codex keeps the transport alive so a later call succeeds after one times out" \
  "survive" "0.3" "5" "1200" "80" "100" "0" \
  '(.code == 0) and (.stubAlive == false) and
   ([.frames[] | select(.id == 2 and .error.code == -32001 and (.error.message | ascii_downcase | contains("idle")) and (.error.message | ascii_downcase | contains("stayed connected")))] | length == 1) and
   ([.frames[] | select(.id == 2 and has("result"))] | length == 0) and
   ([.frames[] | select(.id == 3 and .result.structuredContent.content == "SURVIVED")] | length == 1)'
# The hard deadline is an immutable backstop even after terminal grace begins:
# beginTerminalGrace clears idleTimer but NOT hardTimer, and the keep-alive abort
# path no-ops for a non-"open" entry — so the hard timer must fall back to a
# bounded teardown. Proof: the bridge exits at the ~1s hard deadline (elapsedMs
# well under the 4s stdin-close settle), NOT by hanging until the client leaves.
# A regression (hard timer no-ops in terminal_grace) would hang to ~settle.
test_codex_lifecycle "codex hard deadline bounds a wedged terminal-grace call (no infinite hang)" \
  "gracehang" "5" "1" "4000" "200" "100" "0" \
  '(.code == 1) and (.elapsedMs >= 900) and (.elapsedMs < 2500) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "GRACE")] | length == 1) and
   ([.frames[] | select(.id == 2 and has("error"))] | length == 0)'
# Complement to gracehang: when the hard deadline lands on a terminal_grace entry
# whose framing is CLEAN, armEntryHard settles it via synthesizeTerminalResult
# WITHOUT tearing down the bridge. Hard (200ms) < terminal grace (500ms) so the
# hard timer fires first, in terminal_grace; Fix A recovers id 2's result and the
# transport survives to answer id 3. Reverting Fix A tears down at the hard
# deadline instead (exit 1, id 3 unanswered) — this is the test that distinguishes
# it (gracehang alone cannot, since finalize's own recovery emits the same frame).
test_codex_lifecycle "codex hard deadline on a clean terminal-grace call settles it without teardown" \
  "gracesafe" "5" "0.2" "1000" "500" "100" "0" \
  '(.code == 0) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "DONE")] | length == 1) and
   ([.frames[] | select(.id == 3 and .result.structuredContent.content == "DONE")] | length == 1)'
# Delivery backstop: a suppressed id latches buffer mode; a codex that then leaves
# a native frame unterminated and never exits blocks EVERY queued generated frame
# (here a codex-status local response with no timer of its own). The session-level
# flush-stall guard (400ms here) must escalate to a bounded teardown (exit 1) —
# proven by exiting well under the 3s stdin-close settle, not hanging until it.
test_codex_lifecycle "codex delivery backstop tears down when a stuck native partial blocks all frames" \
  "flushstall" "0.3" "5" "3000" "80" "100" "0" \
  '(.code == 1) and (.elapsedMs >= 900) and (.elapsedMs < 2200) and
   ([.frames[] | select(.id == 2 and .error.code == -32001)] | length == 1)' \
  "400"
# The backstop must survive a wedged request's own progress heartbeats. The
# "still running; last activity Ns ago" message changes ~once per second, so a
# remove-then-push coalesce would empty+reset the guard every ~1s; with the guard
# limit (2000ms) set ABOVE that reset rate, a buggy coalesce would reset the guard
# faster than it can fire and the wedge would NEVER be bounded (hang to the 5s
# stdin-close settle → exit 0). In-place coalescing preserves the arm time, so the
# guard fires (exit 1) well before settle. Idle disabled so only this can bound it.
test_codex_lifecycle "codex delivery backstop is not reset by a wedged request's progress heartbeats" \
  "progressstall" "0" "20" "5000" "80" "100" "20,100" \
  '(.code == 1) and (.elapsedMs < 4500)' \
  "2000"
test_codex_lifecycle "codex settlement clears progress and silence timers" \
  "settled" "0.5" "2" "300" "80" "100" "20,60" \
  '(.code == 0) and
   ((.timerAudits | length) >= 1) and (.timerAudits | all(. == 0)) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "SETTLED")] | length == 1) and
   ([.frames[] | select(.method == "notifications/progress")] | length == 1)'
test_codex_lifecycle "codex terminal grace stops progress before fallback settlement" \
  "terminalstop" "0.5" "2" "350" "150" "100" "20,60" \
  '(.code == 0) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "DONE")] | length == 1) and
   ([.frames[] | select(.method == "notifications/progress")] | length == 1)'
test_codex_lifecycle "codex terminal event synthesizes result with early thread id" \
  "terminal" "0.3" "2" "350" "80" "100" "0" \
  '(.code == 0) and (.stubAlive == false) and
   ([.frames[] | select(.id == 2 and .result.content[0].text == "DONE" and .result.structuredContent == {"threadId":"00000000-0000-4000-8000-000000000002","content":"DONE"})] | length == 1) and
   ([.frames[] | select(.id == 2 and has("error"))] | length == 0)'
test_codex_lifecycle "codex turn_aborted settles an open call as an error, never success" \
  "aborted" "0.3" "2" "350" "80" "100" "0" \
  '(.code == 0) and (.stubAlive == false) and
   ([.frames[] | select(.id == 2 and .error.code == -32001 and
     (.error.message | contains("turn_aborted")) and
     (.error.message | ascii_downcase | contains("did not complete")) and
     (.error.message | contains("Any writes it made are in the tree")) and
     (.error.message | contains("verify the workspace")))] | length == 1) and
   ([.frames[] | select(.id == 2 and has("result"))] | length == 0)'
test_codex_lifecycle "codex terminal event survives immediate child exit" \
  "terminalexit" "0.3" "2" "350" "80" "100" "0" \
  '(.code == 0) and (.stubAlive == false) and
   ([.calls[] | select(.id == 2 and .prompt == "call 2")] | length == 1) and
   ([.frames[] | select(.id == 2 and .result.content[0].text == "DONE" and .result.structuredContent == {"threadId":"00000000-0000-4000-8000-000000000002","content":"DONE"})] | length == 1) and
   ([.frames[] | select(.id == 2 and has("error"))] | length == 0)'
test_codex_lifecycle "codex teardown recovers turn_aborted as an error, never success" \
  "abortedexit" "0.3" "2" "350" "80" "100" "0" \
  '(.code == 0) and (.stubAlive == false) and
   ([.calls[] | select(.id == 2 and .prompt == "call 2")] | length == 1) and
   ([.frames[] | select(.id == 2 and .error.code == -32001 and
     (.error.message | contains("turn_aborted")) and
     (.error.message | ascii_downcase | contains("did not complete")))] | length == 1) and
   ([.frames[] | select(.id == 2 and has("result"))] | length == 0)'
test_codex_lifecycle "codex native result inside terminal grace wins" \
  "native" "0.3" "2" "300" "150" "100" "0" \
  '(.code == 0) and (.stubAlive == false) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "NATIVE")] | length == 1) and
   ([.frames[] | select(.id == 2 and (.result.structuredContent.content // "") == "DONE")] | length == 0)'
test_codex_lifecycle "codex warns when a native response settles an aborted foreground turn" \
  "nativeabort" "0.3" "2" "300" "150" "100" "0" \
  '(.code == 0) and (.stubAlive == false) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "NATIVE_AFTER_ABORT")] | length == 1) and
   ([.frames[] | select(.id == 2 and has("error"))] | length == 0) and
   (.stderr | contains("native codex response settled aborted request")) and
   (.stderr | contains("forwarding unchanged"))'
test_codex_lifecycle "codex late native result is suppressed after terminal fallback" \
  "late" "0.3" "2" "400" "70" "100" "0" \
  '(.code == 0) and (.stubAlive == false) and
   ([.frames[] | select(.id == 2 and has("result"))] | length == 1) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "DONE")] | length == 1) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "LATE")] | length == 0)'
test_codex_lifecycle "codex request-id reuse is rejected while late response is suppressed" \
  "reuse" "0.3" "2" "600" "70" "100" "0" \
  '(.code == 1) and (.stubAlive == false) and
   ([.calls[] | select(.id == 2 and .prompt == "call 2")] | length == 1) and
   ([.calls[] | select(.prompt == "REUSED")] | length == 0) and
   ([.frames[] | select(.id == 2 and has("result"))] | length == 1) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "DONE")] | length == 1) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "LATE")] | length == 0) and
   ([.frames[] | select(.id == 2 and has("error"))] | length == 1) and
   ([.frames[] | select(.id == 2 and .error.code == -32001 and (.error.message | ascii_downcase | contains("reused")))] | length == 1)'
test_codex_lifecycle "codex hard deadline is immutable despite matching progress" \
  "hard" "0.3" "0.55" "1000" "80" "100" "0" \
  '(.code == 0) and (.stubAlive == false) and
   ([.frames[] | select(.id == 2 and .error.code == -32001 and (.error.message | ascii_downcase | test("hard|deadline")))] | length == 1) and
   ([.frames[] | select(.method == "notifications/progress" and .params.progressToken == "hard-2")] | length >= 1)'
# An unattended writer must never outlive the client that dispatched it: once
# the client's stdin closes nothing can consume codex's output, so a codex that
# ignores both the EOF and the cancellations gets a bounded wind-down and is
# then reaped group-wide. Without the backstop the driver's fallback SIGTERM at
# settle+500ms would be what finally stopped it.
test_codex_lifecycle "codex still working after the client disconnects is reaped" \
  "clientgone" "5" "5" "400" "80" "100" "0" \
  '(.code == 0) and (.signal == null) and (.stubAlive == false) and
   (.elapsedMs < 1500)'

# A cancellation codex never acknowledges must cost exactly one request. The
# bridge stays up and the UNRELATED in-flight call (id 3) keeps running — the
# old behaviour tore the whole process down ~160ms in, killing every peer
# request, every background job, and the isolated CODEX_HOME with them.
test_codex_lifecycle "codex cancellation abandons only its own request and keeps the bridge alive" \
  "cancel" "2" "2" "800" "80" "100" "0" \
  '(.code == 0) and (.elapsedMs > 500) and (.stubAlive == false) and
   ([.frames[] | select(.id == 2 and (has("result") or has("error")))] | length == 0) and
   ([.frames[] | select(.params?._meta?.requestId == 3)] | length > 5)'
test_codex_lifecycle "codex confirmed cancellation gets its own frame-boundary grace" \
  "cancelconfirmedlate" "2" "2" "700" "80" "100" "0" \
  '(.code == 0) and (.stubAlive == false) and
   ([.frames[] | select(.id == 3 and .result.structuredContent.content == "SURVIVED_CONFIRMED_CANCEL")] | length == 1) and
   (.stderr | contains("cancellation was confirmed by") | not) and
   (.stderr | contains("NOT confirmed stopped") | not)'
# Positive counterpart to the clean-settlement cases above and below: after the
# first cancel grace expires mid-frame, an abort acknowledgement starts its own
# frame-boundary grace. If the new partial remains wedged, that second bounded
# wait must escalate instead of recurring forever or silently returning.
test_codex_lifecycle "codex confirmed cancellation escalates a sustained framing wedge" \
  "cancelconfirmedwedge" "2" "2" "900" "80" "100" "0" \
  '(.code == 1) and (.stubAlive == false) and
   (.elapsedMs >= 240) and (.elapsedMs < 900) and
   (.stderr | contains("request 2 cancellation was confirmed by turn_aborted, but codex left a frame unterminated"))'
test_codex_lifecycle "codex ignores duplicate terminal events while confirmed cancellation is pending" \
  "canceldoubleterminal" "2" "2" "550" "80" "100" "0" \
  '(.code == 0) and (.stubAlive == false) and
   ([.frames[] | select(.id == 3 and .result.structuredContent.content == "SURVIVED_DOUBLE_TERMINAL")] | length == 1) and
   (.stderr | contains("cancellation was confirmed by") | not)'
test_codex_lifecycle "coalesced canceled terminal event and response release suppression before id reuse" \
  "cancelcoalesced" "2" "2" "500" "80" "100" "0" \
  '(.code == 0) and (.stubAlive == false) and
   ([.calls[] | select(.id == 2)] | length == 2) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "REUSED_AFTER_COALESCED_CANCEL")] | length == 1) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "SUPPRESSED_NATIVE_CANCEL_RESULT")] | length == 0) and
   (.stderr | contains("reused before the prior Codex response settled") | not)'
test_codex_lifecycle "unsafe-boundary cancel releases suppression after coalesced abort and response" \
  "cancelcoalescedunsafe" "2" "2" "500" "80" "100" "0" \
  '(.code == 0) and (.stubAlive == false) and
   ([.calls[] | select(.id == 2)] | length == 2) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "ALREADY_FORWARDED_CANCEL_RESULT")] | length == 1) and
   ([.frames[] | select(.id == 2 and .result.structuredContent.content == "REUSED_AFTER_UNSAFE_CANCEL")] | length == 1) and
   ([.frames[] | select(.id == 2 and has("error"))] | length == 0) and
   (.stderr | contains("reused before the prior Codex response settled") | not)'

# Each terminal fallback must suppress the native response it answered for, but
# that bounded set cannot grow forever when Codex never sends those responses.
# Drive exactly the production limit (32 distinct ids) and require the bridge's
# documented process-level backstop to fire. Wall time is intentionally absent:
# processing 32 real frame exchanges varies with host load, while the outer test
# timeout still bounds a bridge that fails to invoke the backstop at all.
test_codex_lifecycle "codex tears down when late-response suppression reaches its limit" \
  "suppressioncap" "2" "2" "1000" "40" "100" "0" \
  '(.code == 1) and (.stubAlive == false) and
   (.calls | length == 32) and
   (.stderr | contains("codex passthrough finalize: late-response suppression limit reached"))'

test_codex_job_lifecycle "Codex background job exposes status, commentary, and result without private-id leakage" \
  '(.code == 0) and (.parseErrors == 0) and
   (.jobId | type == "string") and
   (.calls | length == 1) and (.calls[0].id | startswith("mcp-agents/job/test/")) and
   (.privateIdLeaked == false) and
   ([.frames[] | select(.id == "mcp-agents/job/test/client" and .error.code == -32600)] | length == 1) and
   ([.frames[] | select(.method == "codex/event")] | length == 0) and
   ([.statusResults[] | select(.state == "running")] | length >= 1) and
   ((.statusResults | map(.cursor) | max) <= 4) and
   ([.statusResults[] | select(.state == "completed" and .resultAvailable == true)] | length == 1) and
   ([.commentaryResults[] | select((.text | contains("Inspecting the")) and .state == "running")] | length >= 1) and
   ((.commentaryResults | map(.text) | join("")) == "Inspecting the bridge 🚀\n\n") and
   (.resultResults | length == 1) and
   (.resultResults[0] | (.state == "completed") and (.offset == 0) and
    (.nextOffset == 12) and (.endOffset == 12) and (.done == true) and
    (.resultTruncated == false) and (.text == "ASYNC_RESULT") and
    (.structuredText == "ASYNC_RESULT"))'
test_codex_job_lifecycle "Codex background auth failure is sanitized and classified" \
  '(.code == 0) and (.parseErrors == 0) and (.privateIdLeaked == false) and
   ([.frames[] | select(.method == "codex/event")] | length == 0) and
   ([.statusResults[] | select(.state == "failed" and
     .code == "codex_auth_invalidated" and
     (.message | contains("restart")))] | length == 1) and
   (.resultResults | length == 1) and
   (.resultResults[0].state == "failed") and
   (.resultResults[0].code == "codex_auth_invalidated") and
   ((.frames | tostring | contains("refresh token was revoked")) | not)' \
  "asyncauthfailure"
test_codex_job_lifecycle "Codex background job terminal fallback suppresses its late native response" \
  '(.code == 0) and (.parseErrors == 0) and (.privateIdLeaked == false) and
   ([.frames[] | select(.method == "codex/event")] | length == 0) and
   ([.statusResults[] | select(.state == "completed")] | length == 1) and
   (.resultResults | length == 1) and (.resultResults[0].text == "FALLBACK_RESULT") and
   ([.frames[] | select(.result.structuredContent.content == "LATE_PRIVATE_RESULT")] | length == 0)' \
  "asyncfallback"
test_codex_job_lifecycle "Codex turn_aborted fails an open background job, never completes it" \
  '(.code == 0) and (.parseErrors == 0) and (.privateIdLeaked == false) and
   ([.statusResults[] | select(
     .state == "failed" and (.message | contains("turn_aborted"))
   )] | length == 1) and
   ([.statusResults[] | select(.state == "completed")] | length == 0) and
   (.resultResults | length == 1) and (.resultResults[0].state == "failed")' \
  "asyncabort"
test_codex_job_lifecycle "Codex native success after turn_aborted still fails the background job" \
  '(.code == 0) and (.parseErrors == 0) and (.privateIdLeaked == false) and
   ([.statusResults[] | select(
     .state == "failed" and (.message | contains("turn_aborted"))
   )] | length == 1) and
   ([.statusResults[] | select(.state == "completed")] | length == 0) and
   (.resultResults | length == 1) and
   (.resultResults[0].state == "failed") and
   ((.frames | tostring) | contains("MUST_NOT_COMPLETE_AFTER_ABORT") | not)' \
  "asyncabortnative"
test_codex_job_lifecycle "Codex teardown preserves the abort-specific background-job message" \
  '(.code == 0) and (.parseErrors == 0) and (.privateIdLeaked == false) and
   (.terminalProbeResults | length == 1) and
   (.terminalProbeResults[0].state == "failed") and
   (.terminalProbeResults[0].message == "Codex: turn_aborted: Codex aborted the turn before completion") and
   (.terminalProbeResults[0].threadId == "00000000-0000-4000-8000-999999999999")' \
  "asyncabortexit"
test_codex_job_lifecycle "Codex cancellation preserves a turn_aborted observed before the request" \
  '(.code == 0) and (.parseErrors == 0) and (.privateIdLeaked == false) and
   ([.statusResults[] | select(
     .state == "canceled" and (.message | contains("confirmed by turn_aborted"))
   )] | length >= 1) and
   ([.statusResults[] | select(
     (.message | contains("did not acknowledge"))
   )] | length == 0) and
   (.resultResults | length == 1) and (.resultResults[0].state == "canceled") and
   (.stderr | contains("NOT confirmed stopped") | not) and
   (.stderr | contains("abandoned while possibly still running") | not)' \
  "asyncabortcancel"
test_codex_job_lifecycle "Codex turn_aborted confirms a requested cancellation before grace expiry" \
  '(.code == 0) and (.parseErrors == 0) and (.privateIdLeaked == false) and
   (.cancelResults | length == 1) and (.cancelResults[0].state == "canceling") and
   ([.statusResults[] | select(
     .state == "canceled" and (.message | contains("confirmed by turn_aborted"))
   )] | length == 1) and
   (.resultResults | length == 1) and (.resultResults[0].state == "canceled") and
   (.stderr | contains("NOT confirmed stopped") | not) and
   (.stderr | contains("abandoned while possibly still running") | not)' \
  "asynccancelabort"
test_codex_job_lifecycle "Codex completion after requested cancellation is distinct from an honored abort" \
  '(.code == 0) and (.parseErrors == 0) and (.privateIdLeaked == false) and
   (.cancelResults | length == 1) and (.cancelResults[0].state == "canceling") and
   ([.statusResults[] | select(
     .state == "canceled" and
     (.message | contains("completed after cancellation was requested")) and
     (.message | contains("task_complete")) and
     (.message | contains("result discarded")) and
     (.message | contains("confirmed by") | not)
   )] | length == 1) and
   (.resultResults | length == 1) and (.resultResults[0].state == "canceled")' \
  "asynccancelcomplete"
test_codex_job_lifecycle "Codex background job cancellation is visible and never emits a private-id error" \
  '(.code == 0) and (.parseErrors == 0) and (.privateIdLeaked == false) and
   (.cancelResults | length == 1) and (.cancelResults[0].state == "canceling") and
   ([.statusResults[] | select(.state == "canceled")] | length >= 1) and
   ([.frames[] | select(.method == "codex/event")] | length == 0) and
   ([.frames[] | select((.error.message? // "") | contains("request was still open"))] | length == 0) and
   (.stderr | contains("NOT confirmed stopped"))' \
  "asynccancel"
test_codex_job_lifecycle "Codex commentary exposes only explicit commentary and strips unsafe controls" \
  '(.code == 0) and (.parseErrors == 0) and
   ((.commentaryResults | map(.text) | join("")) == "Safe\ncommentary\n\n") and
   ((.commentaryResults | map(.text) | join("")) | contains("SENTINEL_") | not) and
   (.resultResults[0].text == "PRIVACY_RESULT")' \
  "asyncprivacy"
test_codex_job_lifecycle "Codex commentary reports absolute offsets after tail truncation" \
  '(.code == 0) and (.parseErrors == 0) and
   ([.commentaryResults[] | select(
      .requestedOffset == 0 and .startOffset > 0 and
      .truncatedBefore == true and .endOffset > .startOffset
    )] | length == 1) and
   ([.statusResults[] | select(
      .state == "completed" and .commentaryTruncated == true and
      .commentaryStartOffset > 0 and .commentaryEndOffset == 202
    )] | length == 1) and
   ((.commentaryResults | map(.text) | join("")) | endswith("\n\n")) and
   (.resultResults[0].text == "TRUNCATE_RESULT")' \
  "asynctruncate"
test_codex_job_lifecycle "Codex background results page without truncation" \
  '(.code == 0) and (.parseErrors == 0) and (.privateIdLeaked == false) and
   (.resultResults | length == 2) and
   (.resultResults[0] | (.offset == 0) and (.nextOffset == 32768) and
    (.endOffset == 32780) and (.done == false) and (.resultTruncated == false) and
    ((.text | length) == 32768) and (.structuredText == .text)) and
   (.resultResults[1] | (.offset == 32768) and (.nextOffset == 32780) and
    (.endOffset == 32780) and (.done == true) and ((.text | length) == 12) and
    (.structuredText == .text)) and
   ((.resultResults | map(.text) | join("") | length) == 32780)' \
  "asyncpage"
test_codex_job_lifecycle "Oversized Codex background results fail atomically without leaking" \
  '(.code == 0) and (.parseErrors == 0) and (.privateIdLeaked == false) and
   ([.statusResults[] | select(
      .state == "failed" and (.message | contains("10 MiB"))
    )] | length == 1) and
   (.resultResults | length == 1) and
   (.resultResults[0].state == "failed") and
   (.resultResults[0].resultAvailable == false) and
   ([.frames[] | select(.method == "codex/event")] | length == 0) and
   ([.frames[] | select(
      (.result.structuredContent.content? // "" | length) > 10485760
    )] | length == 0)' \
  "asyncoversize"
test_codex_job_lifecycle "Codex blocking calls remain isolated while a background job runs" \
  '(.code == 0) and (.parseErrors == 0) and (.privateIdLeaked == false) and
   (.calls | length == 2) and
   ([.calls[] | select(.id | type == "string")] | length == 1) and
   ([.calls[] | select(.id | type == "number")] | length == 1) and
   (.blockingResults | length == 1) and
   (.blockingResults[0].text == "BLOCKING_RESULT") and
   (.resultResults | length == 1) and
   (.resultResults[0].text == "BACKGROUND_RESULT") and
   ([.frames[] | select(
      .method == "codex/event" and (.params._meta.requestId | type == "number")
    )] | length >= 1)' \
  "asyncconcurrent"
test_codex_job_lifecycle "Canceling a status wait leaves its Codex job running" \
  '.canceledWaitId as $wait |
   (.code == 0) and (.parseErrors == 0) and (.privateIdLeaked == false) and
   (.canceledWaitId | type == "number") and
   ([.frames[] | select(.id == $wait)] | length == 0) and
   ([.statusResults[] | select(.state == "completed")] | length == 1) and
   (.resultResults | length == 1) and
   (.resultResults[0].text == "WAIT_CANCEL_RESULT")' \
  "asyncwaitcancel"

# Stub-based codex watchdog/child-death tests (fast — no real codex needed)
run_codex_watchdog_case "codex idle watchdog fails the stalled call but keeps the bridge alive" \
  "stall" "--codex_idle_timeout 1" 0
run_codex_watchdog_case "codex child death synthesizes error (no childless hang)" \
  "die" "--codex_idle_timeout 30" 0

# Browser resolver and passthrough process-boundary tests. The npx resolver and
# all remaining browser cases use PID-registering downstream/helper stubs, so
# they run anywhere. The FIRST case is different: it starts the REAL
# package-local chrome-devtools-mcp, whose own engines floor rises as the
# unpinned dependency tracks latest. mcp-agents now requires `>=26` so this
# normally passes; the gate stays as a guard for anyone running the suite on an
# older node than the package supports.
browser_local_node_ok=1
if ! node -e '
  const [maj, min] = process.versions.node.split(".").map(Number);
  process.exit(maj > 20 || (maj === 20 && min >= 19) ? 0 : 1);
' 2>/dev/null; then
  browser_local_node_ok=0
fi
if [ "$browser_local_node_ok" -eq 1 ]; then
  test_browser_local_resolution \
    "browser defaults to the package-local downstream without npx"
else
  echo "(Skipping package-local browser resolver test — node $(node -p 'process.versions.node') is below the chrome-devtools-mcp engines floor)"
fi
test_browser_npx_resolution \
  "published browser install invokes the unpinned npx fallback"
test_browser_case "browser startup, argv, lazy acquire, warnings, and shutdown release" \
  "normal" "normal" "ready" "10" "3" \
  'def arg_after($argv; $flag): $argv[(($argv | index($flag)) + 1)];
   (.driverError == null) and (.spawns | length == 1) and
   (.leaseCalls | map(.args[0]) == ["acquire","release"]) and
   (.spawns[0].at <= .leaseCalls[0].at) and
   (.spawns[0] as $spawn | .leaseCalls[0] as $acquire |
     (arg_after($spawn.argv; "--browserUrl") |
       startswith("http://127.0.0.1:")) and
     (arg_after($spawn.argv; "--browserUrl") ==
       ("http://127.0.0.1:" + arg_after($acquire.args; "--local-cdp-port"))) and
     ($spawn.argv | index("--viewport") == null) and
     (arg_after($spawn.argv; "--logFile") | endswith("/browser.log")) and
     ([range(0; $spawn.argv|length) as $i |
       select($spawn.argv[$i] == "--allowedUrlPattern") |
       $spawn.argv[$i+1]] == ["http://127.0.0.1/*","https://example.test/*"]) and
     ($spawn.argv | index("--no-usage-statistics") != null) and
     ($spawn.argv | index("--allowUnrestrictedPaths") == null) and
     ($spawn.argv | index("--allow-unrestricted-paths") == null) and
     ($spawn.argv | index("--headless") == null) and
     ($spawn.argv | index("--isolated") == null) and
     (arg_after($acquire.args; "--app-port") == "5100") and
     (arg_after($acquire.args; "--viewport") == "1280x720") and
     ($spawn.stdin[0].params.capabilities.roots.listChanged == true) and
     ($spawn.stdinRaw | startswith("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"roots\":{\"listChanged\":true},\"sampling\":{}},\"clientInfo\":{\"name\":\"browser-driver\",\"version\":\"0\"}}}\n"))) and
   ([.frames[] | select(.id == 2) | .result.tools] | length == 1) and
   ([.frames[] | select(.id == 2) | .result.tools[] |
      select(.name == "performance_start_trace" or
             .name == "performance_stop_trace" or
             .name == "performance_analyze_insight" or
             .name == "lighthouse_audit") |
      (.description | contains("never as a gate"))] | all) and
   ([.frames[] | select(.id == 2) | .result.tools[] |
      select(.name == "upload_file") |
      ((.description | contains("unsupported")) and
       (.inputSchema.properties.filePath.type == "string"))] | all) and
   ([.frames[] | select(.id == 2) | .result.tools[] |
      select(.name == "navigate_page") |
      (.title == "Navigate title" and .annotations.readOnlyHint == false and
       .inputSchema.properties.url.type == "string")] | all) and
   ([.frames[] | select(.id == 2) | .result.tools[].name] | sort) ==
     ["lighthouse_audit","navigate_page","performance_analyze_insight","performance_start_trace","performance_stop_trace","upload_file"] and
   ([.frames[] | select(.id == 3 and .result.structuredContent.content == "BROWSER_OK_3")] | length == 1) and
   ([.stderr | scan("session_id=[0-9a-f-]{36}")] | length == 1) and
   (.leaseCalls[-1].args | index("shutdown") != null)'

test_browser_case "browser split tools/list frame is reassembled and rewritten" \
  "split" "split" "ready" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 2) | .result.tools[].name] | sort) ==
     ["lighthouse_audit","navigate_page","performance_analyze_insight","performance_start_trace","performance_stop_trace","upload_file"] and
   ([.frames[] | select(.id == 2) | .result.tools[] |
     select(.name == "upload_file") |
     (.description | contains("unsupported"))] | all)'
test_browser_case "browser interleaved frame stays byte-identical during rewrite" \
  "interleaved" "interleaved" "ready" "10" "3" \
  '(.driverError == null) and
   (.rawLines | index("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"marker\":\"BROWSER_INTERLEAVED\"}}") != null) and
   ([.frames[] | select(.id == 2) | .result.tools[].name] | sort) ==
     ["lighthouse_audit","navigate_page","performance_analyze_insight","performance_start_trace","performance_stop_trace","upload_file"] and
   ([.frames[] | select(.id == 2) | .result.tools[] |
     select(.name == "lighthouse_audit") |
     (.description | contains("never as a gate"))] | all)'
test_browser_case "browser mode-boundary straddle forwards the orphan frame intact" \
  "straddle" "straddle" "ready" "10" "3" \
  '(.driverError == null) and
   (.rawLines | index("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"marker\":\"STRADDLE\"}}") != null) and
   ([.frames[] | select(.id == 2 and .result.tools)] | length == 1)'
test_browser_case "browser partial tools/list then child death yields one error" \
  "partialdie" "partialdie" "ready" "10" "3" \
  '([.frames[] | select(.id == 2 and .error.code == -32001)] | length == 1) and
   ([.frames[] | select(.id == 2 and has("result"))] | length == 0)'
test_browser_case "browser complete unterminated tools/list is recovered on exit" \
  "nonewlinedie" "nonewlinedie" "ready" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 2) | .result.tools[].name] | sort) ==
     ["lighthouse_audit","navigate_page","performance_analyze_insight","performance_start_trace","performance_stop_trace","upload_file"] and
   ([.frames[] | select(.id == 2) | .result.tools[] |
     select(.name == "performance_start_trace") |
     (.description | contains("never as a gate"))] | all)'
test_browser_case "browser oversized frame forwards raw and following list rewrites" \
  "oversized" "oversized" "ready" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.params.marker == "BROWSER_OVERSIZED")] | length == 1) and
   ([.frames[] | select(.id == 2) | .result.tools[].name] | sort) ==
     ["lighthouse_audit","navigate_page","performance_analyze_insight","performance_start_trace","performance_stop_trace","upload_file"] and
   ([.frames[] | select(.id == 2) | .result.tools[] |
     select(.name == "upload_file") |
     (.description | contains("unsupported"))] | all)'
test_browser_case "browser tools/list survives client stdout backpressure" \
  "bp" "bp" "ready" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.params.marker == "BROWSER_BP")] | length == 1) and
   ([.frames[] | select(.id == 2 and .result.tools)] | length == 1)'

test_browser_case "browser roots/list round-trip preserves the exact client answer" \
  "roots" "roots" "ready" "10" "3" \
  '(.driverError == null) and
   (.rootsResponse == "{\"jsonrpc\":\"2.0\", \"id\":\"roots-1\", \"result\":{\"roots\":[{\"uri\":\"file:///workspace\",\"name\":\"root\"}]}}") and
   ([.frames[] | select(.id == "roots-1" and .method == "roots/list")] | length == 1) and
   (.leaseCalls | length == 0)'
test_browser_case "browser initialize is tracked and hard-bounded" \
  "hang-init" "hang-init" "ready" "10" "0.18" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 1 and .error.code == -32001)] | length == 1)'
test_browser_case "unplanned browser downstream death fails the open call" \
  "die" "die" "ready" "10" "3" \
  '([.frames[] | select(.id == 3 and .result.isError == true and
     .result.structuredContent.code == "browser_lease_replaced" and
     .result.structuredContent.outcomeUnknown == true)] | length == 1)'

test_browser_case "concurrent cold calls share one acquire, preserve FIFO, and cancel held work" \
  "slow-ready" "normal" "slow-ready" "10" "3" \
   '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "acquire")] | length == 1) and
   (.spawns[0].stdin | map(select(.method == "tools/call") | .id) == [3,4,6]) and
   ([.frames[] | select(.id == 5)] | length == 0) and
   ([.frames[] | select(.method == "notifications/progress") |
      .params.progressToken] | unique | sort) == [42,"browser-progress"] and
   ([.frames[] | select(.method == "notifications/progress" and
      (.params.progressToken | type == "object"))] | length == 0)'
test_browser_case "advertised tool ownership avoids leasing for unknown tools" \
  "unknown" "normal" "ready" "10" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "acquire")] | length == 0) and
   ([.spawns[0].stdin[] | select(.method == "tools/call" and
      .params.name == "not_advertised")] | length == 1)'
test_browser_case "browser calls conservatively acquire when tools/list was skipped" \
  "skip-list" "normal" "ready" "10" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "acquire")] | length == 1) and
   ([.spawns[0].stdin[] | select(.method == "tools/call" and .id == 3)] | length == 1)'
test_browser_case "browser acquire exit 69 fails closed with no-box context" \
  "unavailable" "normal" "unavailable-69" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
     .result.structuredContent.code == "browser_unavailable" and
     (.result.content[0].text | contains("GUI not verified — no browser box available")) and
     (.result.content[0].text | contains("Lease helper: no capacity")))] | length == 1) and
   (.stderr | contains("browser lease unavailable: no capacity")) and
   ([.spawns[0].stdin[] | select(.method == "tools/call")] | length == 0)'
test_browser_case "browser dev-server preflight error is surfaced verbatim" \
  "dev-unreachable" "normal" "dev-unreachable-69" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and
     .result.structuredContent.code == "browser_dev_server_unreachable" and
     .result.content[0].text == "GUI not verified — dev server not reachable at :5100")] | length == 1)'
test_browser_case "browser MinIO preflight error stays distinct and verbatim" \
  "minio-unreachable" "normal" "minio-unreachable-69" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and
     .result.structuredContent.code == "browser_minio_unreachable" and
     .result.content[0].text == "GUI not verified — MinIO not reachable at :9000")] | length == 1)'
test_browser_case "browser empty acquire diagnostics fall back to the exit code" \
  "acquire-empty" "normal" "acquire-empty-70" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and
     .result.structuredContent.code == "browser_provisioning_failed" and
     (.result.content[0].text | contains("lease helper exited with code 70")))] | length == 1)'

test_browser_case "browser exit-75 restart replays roots into the new downstream only" \
  "port-once" "normal" "port-75-once" "10" "3" \
  'def arg_after($argv; $flag): $argv[(($argv | index($flag)) + 1)];
   (.driverError == null) and (.spawns | length == 2) and
   ([.leaseCalls[] | select(.args[0] == "acquire")] | length == 2) and
   (arg_after(.spawns[0].argv; "--browserUrl") != arg_after(.spawns[1].argv; "--browserUrl")) and
   (.spawns[1].stdin[0].id as $internalId |
     ($internalId | startswith("mcp-agents/browser/initialize/")) and
     (.spawns[1].stdinRaw | startswith(
       ("{\"jsonrpc\":\"2.0\",\"id\":" + ($internalId | tojson) +
        ",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"roots\":{\"listChanged\":true},\"sampling\":{}},\"clientInfo\":{\"name\":\"browser-driver\",\"version\":\"0\"}}}\n")))) and
   ([.spawns[1].stdin[] | select(.method == "notifications/initialized")] | length == 1) and
   ([.frames[] | select(.id == 1 and has("result"))] | length == 1) and
   ([.frames[] | select((.id | type) == "string" and
      (.id | startswith("mcp-agents/browser/initialize/")))] | length == 0) and
   ([.frames[] | select(.id == 3 and .result.structuredContent.content == "BROWSER_OK_3")] | length == 1)'
test_browser_case "browser restart drops dead roots and round-trips replacement roots" \
  "restart-roots" "restart-roots" "port-75-once" "10" "3" \
  '(.driverError == null) and (.spawns | length == 2) and
   ([.frames[] | select(.id == "roots-reused" and .method == "roots/list")] | length == 2) and
   (.rootsResponses == [{
      "pid": .spawns[1].pid,
      "spawnOrdinal": 2,
      "raw": "{\"jsonrpc\":\"2.0\", \"id\":\"roots-reused\", \"result\":{\"roots\":[{\"uri\":\"file:///workspace\",\"name\":\"replacement-root\"}]}}"
    }]) and
   ([.spawns[0].stdin[] | select(.id == "roots-reused" and has("result"))] | length == 0) and
   ([.spawns[1].stdin[] | select(.id == "roots-reused" and has("result"))] | length == 1) and
   (.spawns[1].stdinRaw | contains("dead-root") | not) and
   ([.frames[] | select(.id == 3 and .result.structuredContent.content == "BROWSER_OK_3")] | length == 1)'
test_browser_case "browser restart correlates roots by generation when replacement answers first" \
  "restart-roots-out-of-order" "restart-roots" "port-75-once" "10" "3" \
  '(.driverError == null) and (.spawns | length == 2) and
   ([.frames[] | select(.method == "roots/list")] | length == 2) and
   ([.frames[] | select(.method == "roots/list") | .id][0] == "roots-reused") and
   ([.frames[] | select(.method == "roots/list") | .id][1] |
      startswith("mcp-agents/browser/downstream-request/")) and
   (.rootsClientResponses | map(.order) ==
      ["held-dead","replacement-first","stale-second"]) and
   (.rootsResponses == [{
      "pid": .spawns[1].pid,
      "spawnOrdinal": 2,
      "raw": "{\"jsonrpc\":\"2.0\",\"id\":\"roots-reused\",\"result\":{\"roots\":[{\"uri\":\"file:///workspace\",\"name\":\"replacement-root\"}]}}"
    }]) and
   ([.spawns[0].stdin[] | select(.id == "roots-reused" and has("result"))] | length == 0) and
   ([.spawns[1].stdin[] | select(.id == "roots-reused" and has("result"))] | length == 1) and
   (.spawns[1].stdinRaw | contains("dead-root") | not) and
   ([.frames[] | select(.id == 3 and .result.structuredContent.content == "BROWSER_OK_3")] | length == 1)'
test_browser_case "browser exit-75 retries are bounded at three attempts" \
  "port-always" "normal" "port-75-always" "10" "3" \
  '(.driverError == null) and (.spawns | length == 3) and
   ([.leaseCalls[] | select(.args[0] == "acquire")] | length == 3) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.code == "browser_provisioning_failed" and
      (.result.content[0].text | contains("3 attempts")))] | length == 1)'
test_browser_case "browser malformed ready record fails closed" \
  "malformed" "normal" "malformed" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.code == "browser_provisioning_failed")] | length == 1)'
test_browser_case "browser mismatched ready port fails closed" \
  "wrong-port" "normal" "wrong-port" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.code == "browser_provisioning_failed")] | length == 1)'
test_browser_case "browser lease records reject duplicate prototype keys" \
  "duplicate-proto" "normal" "duplicate-proto" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.code == "browser_provisioning_failed" and
      (.result.content[0].text | contains("duplicate browser lease record key: __proto__")))] | length == 1) and
   ([.spawns[0].stdin[] | select(.method == "tools/call")] | length == 0)'

test_browser_case "browser rejects a different Chrome process on the leased port" \
  "identity-substitution" "normal" "ready" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and .result.structuredContent.content == "BROWSER_OK_3")] | length == 1) and
   ([.frames[] | select(.id == 4 and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.stateLost == true and
      .result.structuredContent.outcomeUnknown == false and
      (.result.content[0].text | contains("call was not executed")))] | length == 1) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] == [3]) and
   (.stderr | contains("browser lease identity lost"))'
test_browser_case "browser post-verifies the first call on a new generation" \
  "first-call-substitution" "normal" "ready" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.stateLost == true and
      .result.structuredContent.outcomeUnknown == true and
      (.result.content[-1].text | contains("never blindly replay")))] | length == 1) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] == [3]) and
   ([.leaseCalls[] | select(.args[0] == "release" and
      (.args | index("gen-1") != null))] | length == 1)'
test_browser_case "a sibling in-flight result is never forwarded raw after a peer discards the generation" \
  "concurrent-identity-substitution" "normal" "slow-ready" "10" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "acquire")] | length == 1) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] == [3, 4]) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.stateLost == true and
      .result.structuredContent.outcomeUnknown == true)] | length == 1) and
   ([.frames[] | select(.id == 4 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.stateLost == true and
      .result.structuredContent.outcomeUnknown == true and
      (.result.content[-1].text | contains("never blindly replay")))] | length == 1)'
test_browser_case "browser identity classification fails closed if its generation expires during the check" \
  "classifier-identity-toctou" "normal" "ready" "0.12" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1) and
   ([.frames[] | select(.id == 3 and .result.isError != true and
      .result.structuredContent.content == "BROWSER_OK_3")] | length == 0)'
test_browser_case "browser connect classification fails closed if its generation expires during status" \
  "classifier-connect-toctou" "connectfail" "status-slow-ready" "0.12" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      (.result.structuredContent | has("code") | not))] | length == 0)'
test_browser_case "hard-timeout recovery suppresses a response already deferred during classification" \
  "deferred-hard-timeout-recovery" "deferred-hard-timeout-recovery" \
  "slow-ready" "10" "0.55" \
  '(.driverError == null) and (.spawns | length == 2) and
   ([.leaseCalls[] | select(.args[0] == "acquire")] | length == 1) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] == [5, 3, 4]) and
   ([.spawns[1].stdin[] | select(.method == "tools/call")] | length == 0) and
   ([.frames[] | select(.id == 3)] | length == 1) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.content == "DEFERRED_RAW_3")] | length == 0) and
   ([.frames[] | select(.id == 4 and
      .result.structuredContent.content == "CLASSIFIER_OK_4")] | length == 1) and
   ([.frames[] | select(.id == 5 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1)'
test_browser_case "cancelling an open browser call preserves generation classification" \
  "cancel-open-generation-change" "controlled-result" "ready" "0.12" "3" \
  '(.driverError == null) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] == [3]) and
   ([.spawns[0].stdin[] | select(.method == "notifications/cancelled" and
      .params.requestId == 3)] | length == 1) and
   ([.leaseCalls[] | select(.args[0] == "release" and
      (.args | index("idle") != null))] | length == 1) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true and
      (.result.content[-1].text | contains("never blindly replay")))] | length == 1) and
   ([.frames[] | select(.id == 3 and .result.isError != true and
      .result.structuredContent.content == "RAW_CANCELLED_3")] | length == 0)'
test_browser_case "browser restart resolves an outstanding call and clears its latch" \
  "restart-outstanding" "restart-outstanding" "ready-port-75-second" "0.12" "3" \
  '(.driverError == null) and (.spawns | length == 2) and
   (.latchClearBeforeClose == true) and
   ([.leaseCalls[] | select(.args[0] == "acquire")] | length == 3) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] == [3]) and
   ([.spawns[1].stdin[] | select(.method == "tools/call") | .id] == [4]) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1) and
   ([.frames[] | select(.id == 4 and
      .result.structuredContent.content == "REPLACEMENT_OK_4")] | length == 1)'
test_browser_case "unsafe browser restart still resolves calls owned by the dead downstream" \
  "restart-outstanding-unsafe" "restart-outstanding-unsafe" "ready-port-75-second" "0.12" "3" \
  '(.driverError == null) and (.spawns | length == 1) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1) and
   ([.frames[] | select(.id == 4 and .result.isError == true and
      .result.structuredContent.code == "browser_provisioning_failed" and
      (.result.structuredContent.message | contains("unsafe frame boundary")))] | length == 1)'
test_browser_case "oversized browser result fails closed instead of forwarding raw" \
  "oversized-browser-result" "oversized-result" "ready" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.content == "RAW_OVERSIZED_RESULT")] | length == 0)'
test_browser_case "oversized browser result with id after result fails closed" \
  "oversized-id-after-result" "oversized-result-id-after" "ready" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.content == "RAW_OVERSIZED_ID_AFTER")] | length == 0)'
test_browser_case "complete oversized browser result with id after result fails closed" \
  "oversized-complete-id-after" "oversized-complete-id-after" "ready" "10" "3" \
  '(.driverError == null) and
   (.stderr | contains("frame exceeded rewrite cap")) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1) and
   ([.frames[] | select(.id == 3 and .result.isError != true and
      .result.structuredContent.content == "RAW_OVERSIZED_COMPLETE")] | length == 0)'
test_browser_case "browser finalize resolves active and buffered classifier owners" \
  "finalize-multiframe" "finalize-multiframe" "ready" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select((.id == 3 or .id == 4 or .id == 5) and
      .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | map(.id) | sort == [3,4,5]) and
   ([.frames[] | select((.id == 3 or .id == 4 or .id == 5) and
      .result.isError != true and
      (.result.structuredContent.content | startswith("RAW_FINALIZE_")))] | length == 0)'
test_browser_case "malformed browser result resolves lease-loss and clears its tracking" \
  "malformed-browser-result" "malformed-result" "ready" "10" "3" \
  '(.driverError == null) and (.latchClearBeforeClose == true) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1)'
test_browser_case "hard-timed-out browser call resolves lease-loss without permanent tracking" \
  "browser-hard-timeout" "timeout-no-result" "ready" "10" "1" \
  '(.driverError == null) and (.latchClearBeforeClose == true) and
   (.spawns | length == 2) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1) and
   (.rawLines | map(contains("OLD_PROCESS_SHOULD_BE_DEAD")) | any | not)'
test_browser_case "unterminated browser result fails closed during child exit" \
  "unterminated-browser-result" "call-nonewlinedie" "ready" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.outcomeUnknown == true)] | length == 1) and
   ([.frames[] | select(.id == 3 and .result.isError != true and
      .result.structuredContent.content == "BROWSER_UNTERMINATED_3")] | length == 0)'
test_browser_case "browser suspends idle expiry during a held identity check" \
  "slow-identity-idle" "normal" "ready" "0.12" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 4 and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.stateLost == true and
      .result.structuredContent.outcomeUnknown == false and
      (.result.content[0].text | contains("identity could not be verified")))] | length == 1) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] == [3]) and
   ([.leaseCalls[] | select(.args[0] == "release" and
      (.args | index("gen-1") != null))] | length == 1)'
test_browser_case "browser unreadable identity releases the discarded generation" \
  "identity-unreachable" "normal" "ready" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 4 and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.stateLost == true and
      .result.structuredContent.outcomeUnknown == false)] | length == 1) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] == [3]) and
   ([.leaseCalls[] | select(.args[0] == "release" and
      (.args | index("gen-1") != null))] | length == 1)'

test_browser_case "browser shutdown lets an acquiring helper run its TERM cleanup" \
  "shutdown-acquire" "normal" "acquire-term" "10" "3" \
  '(.driverError == null) and (.acquireTerminated == true) and
   (.leaseCalls | map(.args[0]) == ["acquire"]) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] | length == 0)'
test_browser_case "browser acquire timeout lets the helper run its TERM cleanup" \
  "acquire-timeout" "normal" "acquire-term-timeout" "10" "3" \
  '(.driverError == null) and (.acquireTerminated == true) and
   (.leaseCalls | map(.args[0]) == ["acquire"]) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.code == "browser_provisioning_failed" and
      (.result.content[0].text | contains("timed out")))] | length == 1) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] | length == 0)'
test_browser_case "browser escalates when an acquiring helper ignores TERM" \
  "acquire-kill-timeout" "normal" "acquire-ignore-term-timeout" "10" "3" \
  '(.driverError == null) and (.acquireTerminated == true) and
   (.acquireAlive == false) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.code == "browser_provisioning_failed" and
      (.result.content[0].text | contains("timed out")))] | length == 1) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] | length == 0)'
test_browser_case "browser helper budget stays below its request budget" \
  "derived-helper-timeout" "normal" "acquire-derived-timeout" "10" "18" \
  '(.driverError == null) and (.acquireTerminated == true) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.code == "browser_provisioning_failed" and
      (.result.content[0].text | contains("timed out")))] | length == 1) and
   ([.frames[] | select(.id == 3 and .error.code == -32001)] | length == 0) and
   ([.spawns[0].stdin[] | select(.method == "tools/call") | .id] | length == 0)'

test_browser_case "browser status-ready preserves the native connect error" \
  "status-ready" "connectfail" "status-ready" "10" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "status")] | length == 1) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      (.result.structuredContent | has("code") | not))] | length == 1)'
test_browser_case "browser corrupt status stays unknown and preserves native error" \
  "status-corrupt" "connectfail" "status-corrupt" "10" "3" \
  '(.driverError == null) and
   ([.frames[] | select(.id == 3 and .result.isError == true and
      (.result.structuredContent | has("code") | not))] | length == 1) and
   (.stderr | contains("status is unknown")) and
   (.stderr | contains("exit 70"))'
test_browser_case "browser absent lease enriches once, never replays, and next call repairs" \
  "status-absent" "connectfail" "status-absent" "10" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "acquire")] | length == 2) and
   ([.leaseCalls[] | select(.args[0] == "status")] | length == 1) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.code == "browser_lease_replaced" and
      .result.structuredContent.stateLost == true and
      .result.structuredContent.outcomeUnknown == true and
      (.result.content[-1].text | contains("never blindly replay")))] | length == 1) and
   ([.frames[] | select(.id == 4 and
      .result.structuredContent.content == "RECOVERED_NEXT_CALL")] | length == 1) and
   ([.spawns[0].stdin[] | select(.method == "tools/call")] | map(.id) == [3,4])'

test_browser_case "every downstream frame resets browser lease idle" \
  "activity" "activity" "ready" "0.12" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "release" and
      (.args | index("idle") != null))] | length == 1) and
   ([.leaseCalls[] | select(.args[0] == "release")][0].at >
     [.frameEvents[] | select(.id == 3)][0].at) and
   ([.frames[] | select(.id == 3 and
      .result.structuredContent.content == "ACTIVITY_DONE")] | length == 1)'
test_browser_case "browser stderr is prefixed and does not reset lease idle" \
  "stderr" "stderr" "ready" "0.12" "3" \
  '(.driverError == null) and
   (.stderr | contains("[chrome-devtools] noisy but not browser activity")) and
   ([.leaseCalls[] | select(.args[0] == "release" and
      (.args | index("idle") != null))] | length == 1) and
   ([.leaseCalls[] | select(.args[0] == "release")][0].at <
     .lastNoisyStderrAt)'
test_browser_case "browser idle timeout releases a ready generation" \
  "idle-release" "normal" "ready" "0.12" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "release" and
      (.args | index("idle") != null) and
      (.args | index("gen-1") != null))] | length == 1)'
test_browser_case "browser idle timeout zero disables idle release" \
  "idle-zero" "normal" "ready" "0" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "release" and
      (.args | index("idle") != null))] | length == 0) and
   ([.leaseCalls[] | select(.args[0] == "release" and
      (.args | index("shutdown") != null))] | length == 1)'
test_browser_case "browser idle release exit 69 is nonfatal" \
  "release-69" "normal" "release-69" "0.12" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "release")] | length >= 1) and
   (.stderr | contains("was nonfatal"))'
test_browser_case "browser empty release diagnostics fall back to the exit code" \
  "release-70" "normal" "release-empty-70" "0.12" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "release")] | length >= 1) and
   (.stderr | contains("exit 70"))'
test_browser_case "browser cap-only generation still attempts nonfatal release" \
  "cap-only" "normal" "cap-only" "0.12" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "release" and
      (.args | index("idle") != null))] | length == 1) and
   (.stderr | contains("was nonfatal"))'
test_browser_case "browser shutdown releases the exact acquired generation" \
  "shutdown" "normal" "ready" "10" "3" \
  '(.driverError == null) and
   ([.leaseCalls[] | select(.args[0] == "release" and
      (.args | index("shutdown") != null) and
      (.args | index("gen-1") != null))] | length == 1)'
test_browser_case "browser idle release has time to finish remote cleanup" \
  "slow-idle-release" "normal" "slow-idle-release" "0.12" "5" \
  '(.driverError == null) and
   ([.releaseCompletions[] | select(.reason == "idle")] | length == 1)'
test_browser_case "browser shutdown release is bounded and reaped" \
  "shutdown" "normal" "slow-shutdown-release" "10" "5" \
  '(.driverError == null) and
   ([.releaseCompletions[] | select(.reason == "shutdown")] | length == 1)'

if [ "${SKIP_INTEGRATION:-}" = "1" ]; then
  echo ""
  echo "(Skipping integration tests — SKIP_INTEGRATION=1)"
else
  test_connectivity "call claude (connectivity)" "claude" "claude_code" 30
  test_connectivity "call gemini (connectivity)" "gemini" "gemini"     30
  test_codex_passthrough "codex passthrough (tools/list)"
  test_codex_isolated_runtime "codex passthrough (isolated runtime + per-session max)"
  test_codex_percall_write "codex per-call workspace-write grants writes"
fi

test_no_registered_child_leaks "test suite leaves no provider stub children"

# ---------- Summary ----------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
