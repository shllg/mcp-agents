# mcp-agents

MCP server that wraps AI CLI tools — [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [Antigravity CLI](https://antigravity.google/) (`agy`), and [Codex CLI](https://github.com/openai/codex) — and can proxy [Chrome DevTools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp) to a remotely leased browser.

## Prerequisites

- **Node.js >= 18**
- At least one of the following CLIs installed and on your `$PATH`:

| CLI | Install |
|-----|---------|
| `claude` | [Claude Code docs](https://docs.anthropic.com/en/docs/claude-code) |
| `agy` | [Google Antigravity](https://antigravity.google/) |
| `codex` | `npm install -g @openai/codex` |

Only the CLI you select with `--provider` needs to be present.

## Install

```bash
npm install -g mcp-agents
```

Global install is the fastest and most reliable startup path. `npx -y mcp-agents`
is functionally equivalent once the MCP server is running, but startup depends on
npm package resolution/cache state before the MCP client can connect.

**Tip:** If your project's `.mcp.json` references `mcp-agents`, add `npm install -g mcp-agents`
to your setup script (e.g. `bin/setup`) so new developers get it automatically.

## Quick test

```bash
# Default provider (codex)
mcp-agents

# Specific provider
mcp-agents --provider claude
mcp-agents --provider gemini

# Browser provider (example injected lease helper)
mcp-agents --provider browser \
  --browser_lease_command '["bin/box","--browser"]'
```

The server speaks [JSON-RPC over stdio](https://modelcontextprotocol.io/docs/concepts/transports#stdio). It prints `[mcp-agents] ready (provider: <name>)` to stderr when it's listening.

## Providers & Tools

Each `--provider` flag selects one CLI backend:

| Provider | Tool names | CLI command |
|----------|------------|-------------|
| `claude` | `claude_code`, `claude-start`, `claude-status`, `claude-result`, `claude-cancel` | `claude --model claude-opus-4-8 --effort xhigh` |
| `gemini` | `gemini` | `agy --sandbox -p <prompt>` |
| `codex` | *(pass-through)* | `codex mcp-server` |
| `browser` | *(pass-through)* | `chrome-devtools-mcp --browserUrl <leased-loopback-CDP-url>` |

### Claude reviews

For substantial second opinions and code reviews, use the background tools:

1. Call `claude-start` with the complete review prompt and an absolute `cwd`.
2. Call `claude-status` with the returned `jobId` and `cursor`. Repeat with
   each new cursor until the state is terminal.
3. When the state is `completed`, call `claude-result`. Continue from
   `nextOffset` until `done` is `true`.
4. Call `claude-cancel` if the verdict is no longer needed.

| Tool | Required arguments | Optional arguments |
|------|--------------------|--------------------|
| `claude-start` | `prompt`, absolute `cwd` | — |
| `claude-status` | `jobId`, `cursor` | `wait_ms` |
| `claude-result` | `jobId` | `offset` |
| `claude-cancel` | `jobId` | — |

`claude-status` long-polls for 10 seconds by default and accepts `wait_ms` up to
60 seconds. Canceling a status poll does not cancel its job. Jobs are one-shot
and local to the current MCP connection: there are no reply sessions, and a
disconnect cancels active work. The server allows 8 active and 32 retained jobs,
keeps terminal jobs for one hour, pages results at 32,768 Unicode code points,
and rejects a final result over 10 MiB.

Background reviews have a bridge-owned two-hour deadline. Operators can replace
it with `--timeout <seconds>` when starting the server; callers cannot shorten a
job with `timeout_ms`. Claude is pinned to `claude-opus-4-8` at effort `xhigh`
and runs as a leaf reviewer: it keeps project instructions and repository
context, but disables hooks, subagents, skills, slash commands, external MCP
servers, and mutation tools. Only `Read`, `Glob`, `Grep`, and plan-mode
read-only `Bash` inspection are available; the leaf instruction also forbids
test execution, installs, delegation, and external side effects. Intermediate
model output, tool inputs/results, paths, and reasoning are not forwarded
through MCP; only sanitized phase status and the final verdict are exposed.

Use the blocking `claude_code` tool only for small prompts where a single MCP
call can comfortably finish inside the client timeout.

#### `claude_code` parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `prompt` | `string` | yes | The prompt to send to Claude Code |
| `timeout_ms` | `integer` | no | Timeout in ms (default: 900 000 / 15 minutes) |

Any additional `tools/call` arguments are ignored (for example `model`, `effort`, or `config`).

Claude is pinned to `claude-opus-4-8` at effort `xhigh`; callers cannot change the model or effort per call. Calls run with `--output-format json`; the server parses the JSON payload and returns the assistant `result` text (or an MCP error if `is_error=true`).
The longer default accommodates deep Opus reviews; callers can still set a
smaller `timeout_ms`, and server operators can override the default with
`--timeout <seconds>`.

### `gemini` parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `prompt` | `string` | yes | The prompt to send to the Antigravity CLI (`agy`) |
| `timeout_ms` | `integer` | no | Timeout in ms (default: 300 000 / 5 minutes) |

Any additional `tools/call` arguments are ignored (for example `model` or `model_reasoning_effort`).

`agy` always runs with `--sandbox` (terminal restrictions enabled); there is no per-call sandbox toggle.

### `browser` (remote Chrome pass-through)

The browser provider starts a local `chrome-devtools-mcp` server immediately,
then lazily acquires a remote Chrome lease on the first advertised browser tool
call. The MCP server and all files it writes remain local; only CDP crosses the
operator-provided loopback tunnel. Calls arriving during acquisition share one
provisioning attempt and remain in FIFO order. There are no wrapper-owned
acquire, status, release, job, or cancellation tools.

#### Quick setup with crabbox

Best paired with **crabbox**: ephemeral, single-tenant boxes that die on their
own caps — the lifetime a browser lease wants, without a teardown you have to
get right.

Your `acquire` helper does four things: lease a box; start Chromium on it with
`--remote-debugging-port=<remote>`; open
`ssh -L 127.0.0.1:<local-cdp-port>:127.0.0.1:<remote>` (add a matching `-R` for
`--app-port` when the page under test is served on your machine); then, once
`/json/version` answers on the local port, print:

```text
record_version=1
state=ready
generation=<opaque token>
local_cdp_port=<the port you were given>
browser_url=http://127.0.0.1:<that same port>
```

`status` re-checks that lease, `release` tears it down, and any exit `69` keeps
the lane fail-closed.

The provider has no cloud or SSH knowledge. An injected command owns the lease
and receives these argv forms:

```text
acquire --session <id> --local-cdp-port <port> --viewport <WxH> [--app-port <port>]
status --session <id> [--generation <token>]
release --session <id> --generation <token> --reason idle|shutdown
```

Successful acquire output is inert UTF-8 `key=value` data containing a version-1
ready record, generation, selected local CDP port, and matching browser URL.
Exit `69` is fail-closed: the call returns “GUI not verified — no browser box
available” and never launches a local browser. A helper-reported local dev-server
preflight error is preserved verbatim. Exit `75` reports a loopback bind race;
mcp-agents chooses a new port, restarts the downstream, replays the original MCP
initialize capabilities (including `roots`) and initialized notification, and
retries at most three times without exposing a duplicate initialize result.

`chrome-devtools-mcp` is deliberately **not pinned** — the fallback floats to the
latest release. Nothing here depends on a particular version's reconnect
behavior: every browser tool result is verified against the lease generation it
was issued under whether or not the downstream reports a reconnect, so a newer
release cannot quietly weaken the fail-closed contract. Resolution is
deterministic in this order:

1. `--browser_command` or `MCP_AGENTS_BROWSER_COMMAND` (command string or JSON
   argv).
2. A package-local resolvable `chrome-devtools-mcp`, then
   `node_modules/.bin/chrome-devtools-mcp`.
3. `npx -y chrome-devtools-mcp@latest`.

The third path may make the first initialize wait on npm resolution. For faster
startup, install `chrome-devtools-mcp` alongside mcp-agents, or install it
elsewhere and point `--browser_command` at its executable. Pin it there if you
need a fixed version for a particular deployment. The browser downstream
requires the Node versions supported by the `chrome-devtools-mcp` release it
resolves to, which is currently newer than this package's Node 18 floor; the
other mcp-agents providers retain that floor.

`chrome-devtools-mcp` is intentionally a development dependency, not a runtime
dependency. A developer checkout therefore exercises the package-local path,
while consumers of the published package use the npx fallback unless they
install the package alongside mcp-agents or provide an explicit command.

| CLI flag | Default | Environment |
|----------|---------|-------------|
| `--browser_lease_command <command-or-json-argv>` | required | `MCP_AGENTS_BROWSER_LEASE_COMMAND` |
| `--browser_command <command-or-json-argv>` | resolution order above | `MCP_AGENTS_BROWSER_COMMAND` |
| `--browser_idle_timeout <seconds>` | `600`; `0` disables | `MCP_AGENTS_BROWSER_IDLE_TIMEOUT` |
| `--browser_viewport <WxH>` | `1440x900` | `MCP_AGENTS_BROWSER_VIEWPORT` |
| `--browser_app_port <port>` | omitted | `MCP_AGENTS_BROWSER_APP_PORT` |
| `--browser_log_file <path>` | omitted | `MCP_AGENTS_BROWSER_LOG_FILE` |
| `--browser_allowed_url_pattern <pattern>` | omitted; repeatable | `MCP_AGENTS_BROWSER_ALLOWED_URL_PATTERN` |

The viewport is passed to the lease helper so it can set remote Chromium's
window size; Chrome DevTools MCP's `--viewport` is intentionally omitted because
it is inert when attaching through `--browserUrl`.

Every complete downstream JSON-RPC frame resets the generation idle timer;
stderr and partial output do not. Idle release has a 60-second cleanup bound so
remote Chromium, SSH tunnels, and the box can actually stop. Shutdown release
uses a separate 15-second bound and remains tracked and reaped. Both are
best-effort cost optimizations. If Chrome disappears, the interrupted native
connect error is not replayed. A helper status of `69` enriches it with
`browser_lease_replaced`, explicitly warning that the browser was replaced, state
was lost, the interrupted outcome is unknown, and callers must inspect state
instead of blindly replaying. Status `0` preserves the native error; status `70`
remains unknown rather than being misreported as a lost lease. The next browser
call reacquires and uses Chrome DevTools MCP's reconnect path.

The client initialize frame and downstream `roots/list` request/response are
forwarded without ID or URI rewriting. On a downstream restart, responses owed
to the terminated process are discarded and its request correlations are
retired before the replacement can reuse an ID. This preserves Chrome DevTools
MCP's local file-write allowlist, so `--allowUnrestrictedPaths` is intentionally
never passed. App and MinIO preflight failures are surfaced separately and
verbatim. Performance trace and Lighthouse descriptions warn that a remote-link
measurement is not a gate, and `upload_file` warns that a local path cannot be
handed directly to remote Chromium.

URL restrictions are opt-in because a loopback-only default would break OAuth
and third-party assets. A hardened, loopback-only deployment can repeat, for
example:

```bash
--browser_allowed_url_pattern 'http://127.0.0.1/*' \
--browser_allowed_url_pattern 'https://127.0.0.1/*'
```

Use the narrowest patterns compatible with the target application. The provider
does not enable experimental page-ID routing: one process owns one lease,
profile, and port.

### `codex` (pass-through)

The codex provider passes through to Codex's native MCP server (`codex mcp-server`)
inside an isolated `CODEX_HOME`. The bridge creates each home beneath the server
startup directory's private `tmp/codex-homes/` tree, copies `auth.json`, writes a
minimal `config.toml`, and does not inherit your normal external MCP server list.
That keeps Codex from recursively starting other agent tools like Claude or Gemini
during bridge calls. The parent and generated home directories use mode `0700`;
copied credentials and generated runtime files use mode `0600`.

The isolated home is an authentication snapshot: it cannot see a later
`codex login` until the bridge reconnects. If Codex reports its typed
`unauthorized` terminal event, the wrapper suppresses the duplicate event and
returns one MCP tool error with `structuredContent.code` set to
`codex_auth_invalidated` and `action` set to `reauthenticate_and_restart`.
New Codex turns are rejected locally while status, result, cancel, peek, ping,
and other MCP operations stay available. Stop the bridge, run `codex logout`
and `codex login` as the same OS user, verify with `codex exec`, then reconnect.
On cleanup, rotated auth is written back only when the isolated copy changed
and canonical auth still matches the startup snapshot; a stale bridge therefore
cannot overwrite a newer manual login or another bridge's token rotation.

The one allowlisted user preference is Fast mode. At startup, the bridge reads the
source `$CODEX_HOME/config.toml` and enables Fast mode in the isolated home only when
it finds both top-level `service_tier = "fast"` and `[features].fast_mode = true`.
Partial, disabled, missing, or unreadable settings keep Standard mode; all other user
configuration remains isolated. Restart the MCP server after changing either setting.
[Fast mode uses higher ChatGPT credit consumption or API Priority billing](https://learn.chatgpt.com/docs/agent-configuration/speed#fast-mode).

| CLI Flag | Default | Codex config key |
|----------|---------|-----------------|
| `--model` | `gpt-5.6-sol` | `model` |
| `--model_reasoning_effort` | `xhigh` | `model_reasoning_effort` |
| `--codex-workspace-network=true\|false` | `true` | `sandbox_workspace_write.network_access` |

Other startup defaults: `sandbox_mode=workspace-write`, `approval_policy=never`
(configurable for the whole server with `--sandbox_mode` / `--approval_policy`),
`web_search=cached`, `check_for_update_on_startup=false`,
`allow_login_shell=false`, and `history.persistence=none`. Fixed bridge feature
defaults are `features.multi_agent=false`, `features.apps=false`,
`features.plugins=false`, `features.hooks=false`, and
`features.skill_mcp_dependency_install=false`; apps/plugins stay disabled to
keep ChatGPT app/plugin skills — Figma, Gmail, Presentations, etc. — out of the
bridged session context. Native subagents are additionally disabled with
`[agents] enabled = false`, because on Codex >= 0.145.0 the stabilized
`multi_agent` feature flag alone no longer removes the collab tools; sessions
opt back in per call with `allow_subagents` (see below). That `[agents]` line
is version-aware: the bridge probes `codex --version` once at startup and
omits it on Codex < 0.145.0, where a boolean under `[agents]` is a fatal
config parse error (0.102–0.144) and the feature flag still gates the collab
tools by itself. An unparseable version assumes modern Codex.

Workspace-write sessions have network access enabled by default so sandboxed
commands can reach local services such as DynamoDB, Redis, OpenSearch, and MinIO.
Set `--codex-workspace-network=false` or
`MCP_AGENTS_CODEX_WORKSPACE_NETWORK_ACCESS=false` to disable it for the whole
server; the CLI flag takes precedence over the environment variable. This is a
server-owned sandbox setting and is intentionally absent from the per-call tool
schemas.

Codex does not provide localhost-only scoping for this setting. Enabling it
allows general outbound network access from commands in workspace-write
sessions. Filesystem writes remain restricted to the workspace and other
configured writable roots; read-only and danger-full-access sessions do not use
the `sandbox_workspace_write` setting.

The bridge replaces Codex's broad config-shaped native schema with a deliberately
small contract:

| `codex` parameter | Type | Required | Description |
|-------------------|------|----------|-------------|
| `prompt` | `string` | yes | Initial user prompt |
| `cwd` | `string` | yes | Absolute working directory |
| `sandbox` | `string` | yes | `read-only`, `workspace-write`, or `danger-full-access` |
| `model` | `string` | no | `gpt-5.6-sol` or `gpt-5.6-terra`; defaults to the server model |
| `model_reasoning_effort` | `string` | no | `medium`, `high`, `xhigh`, or `max`; defaults to the server effort |
| `allow_subagents` | `boolean` | no | Let the session spawn Codex's native in-process subagents; defaults to `false` |
| `goal` | `string` | no | Standing objective; `""` suppresses a server-wide goal for this call |

| `codex-reply` parameter | Type | Required | Description |
|-------------------------|------|----------|-------------|
| `prompt` | `string` | yes | Follow-up user prompt |
| `threadId` | `string` | yes | Nonblank thread ID returned by `codex` |
| `goal` | `string` | no | Optional prompt-level reminder of the standing objective |

Both schemas set `additionalProperties: false`. Unsupported, missing, or invalid
arguments are rejected locally with JSON-RPC `-32602` before Codex runs. That
includes native escape hatches such as `config`, `approval-policy`,
`developer-instructions`, `base-instructions`, and `compact-prompt`; future
upstream schema additions stay hidden until mcp-agents intentionally adopts them.
Model values outside the two curated choices are rejected the same way.

**Native subagents.** `allow_subagents: true` on `codex` or `codex-start` lets
that session use Codex's built-in multi-agent tools (`spawn_agent`,
`wait_agent`, …). It is session-scoped exactly like `sandbox`: replies inherit
it and cannot change it, and it defaults to off. Internally the flag flips only
the native multi-agent gates (`agents.enabled` plus `features.multi_agent`,
matching the same version gate as above) via a per-call config override;
everything else about the isolated home is unchanged. In particular the `[mcp_servers]` strip stays in force, so spawned
subagents are Codex-only in-process workers — they cannot re-enter this bridge
or reach Claude, Gemini, or any other external MCP tool, and custom agent
roles from your real `$CODEX_HOME/agents/` are not copied in. The residual
caveat is concurrency, not reach: subagents inherit the session's
`sandbox_mode` and `approval_policy`, so under `workspace-write` with
`approval_policy=never` several agents may write the same workspace at once.
Codex coordinates them, but scope the commission accordingly.

`approval_policy=never` is intentional for an MCP bridge: a detached tool call
cannot reliably conduct an interactive approval conversation. Operators can pick
`untrusted` or `on-request` for the whole server with `--approval_policy`, but
callers cannot weaken or change that policy per request. Each new session must
still state its sandbox explicitly, so write authority is visible at the call site.

Startup flags (`--model`, `--model_reasoning_effort`) configure the isolated native
Codex server defaults (`gpt-5.6-sol` and `xhigh` unless overridden). Each initial
`codex` call may select one of two models and one of four allowed reasoning
efforts:

| Model | Use for |
|-------|---------|
| `gpt-5.6-sol` | Demanding, open-ended, or high-value work; the default |
| `gpt-5.6-terra` | Faster everyday work and easier jobs |

| Value | Use for |
|-------|---------|
| `medium` | Balanced speed and depth |
| `high` | Complex work that needs more analysis and checking |
| `xhigh` | Hard but bounded implementation work |
| `max` | Extra-hard, quality-first work with high architectural, concurrency, data-integrity, or security risk |

The selectors apply only when creating a session. Omitting either one uses its
server-configured default. Every `codex-reply` inherits both choices and cannot
change them. Other models and effort levels are deliberately unavailable through
the closed wrapper contract.

For example, a read-only review starts with:

```json
{
  "prompt": "Review this diff",
  "cwd": "/absolute/path/to/project",
  "sandbox": "read-only",
  "model": "gpt-5.6-terra",
  "model_reasoning_effort": "high",
  "goal": "Find correctness and security defects"
}
```

**Goal injection.** Set a default objective at server startup with
`--goal "<text>"`, or pass `goal` on a call. mcp-agents turns the initial goal into
Codex's native `developer-instructions` internally:

```json
{
  "prompt": "Refactor the parser",
  "cwd": "/absolute/path/to/project",
  "sandbox": "workspace-write",
  "model_reasoning_effort": "xhigh",
  "goal": "Keep the public API unchanged"
}
```

A developer message persists for the thread, so replies inherit it. A per-call
`goal` on `codex-reply` becomes a concise prompt reminder because the native reply
tool has no developer-instructions field. Direct developer instructions are not
exposed: `goal` is the narrow, auditable standing-objective interface. A per-call
goal overrides the server default; `""` suppresses that default for one call.

The bridge rewrites `tools/list` responses to advertise these curated schemas.
Normal native frames remain byte-for-byte pass-through except for the typed
authentication failure described above; locally generated validation and auth
errors use the same frame-safe queue/boundary discipline as progress and recovery
messages.

**Precedence within a thread.** The objective set on the initial `codex` call is
a developer-role message and persists for the whole thread, so it takes
precedence: a *different* `goal` supplied later on a `codex-reply` is only a
prompt-level reminder and will not reliably override the standing objective
(verified live — a reply goal that conflicts with the initial one is ignored in
favor of the standing one). The reply reminder works when it is *not* opposed by
a conflicting standing objective. To genuinely change the objective mid-stream,
start a new `codex` call rather than changing it on a `codex-reply`.

> **Note — this is not Codex's native `/goal`.** Codex's `/goal` slash command
> (durable, thread-scoped goal state with lifecycle/budget/evidence-based
> completion) is a TUI-only feature — it is parsed in the Codex terminal UI and
> is *not* reachable through `codex mcp-server`. Prefixing an MCP prompt with
> `/goal …` does **not** activate it; the text is just passed through as a user
> message. This wrapper therefore steers Codex with `developer-instructions`
> (the MCP-native vehicle for a standing objective), which is prompt/role
> conditioning, not the native goal-lifecycle subsystem.

**Per-call liveness.** The codex pass-through tracks every open `tools/call`
independently. `--codex_idle_timeout <seconds>` (default `600`, `0` disables)
bounds how long one call may go without correlated Codex activity. Only a Codex
event carrying that call's `_meta.requestId` (or its matching response or
interactive exchange) refreshes its idle deadline. Codex stderr, client pings,
unrelated requests, and events belonging to another call cannot keep a stalled
call alive. If a call reaches its idle deadline, the wrapper fails **only that
call** with a JSON-RPC error (`-32001`), sends Codex a `notifications/cancelled`
for that request — best-effort, so it asks Codex to stop rather than making it (see
**Cancellation** below) — suppresses the stalled call's late native response, and **keeps the connection open** — sibling calls and the stdio
transport are unaffected. This matters because a stdio transport close makes MCP
clients such as Claude Code mark the server `failed` and permanently unregister
every `mcp__codex__*` tool for the rest of the session (stdio servers are not
auto-reconnected), so a single stalled review must never take the whole bridge
down. The Codex process group is still reaped on a real teardown (client
disconnect, signal, or `stdout` `EPIPE`). The one exception: if Codex is wedged
partway through writing a response frame (no safe boundary at which to inject the
error) and also ignores the cancellation, the wrapper retries once and then
escalates to a bounded whole-bridge teardown — there is no way to emit a clean
frame into a partial one, so the client is left to reconnect to a fresh bridge.

**Cancellation.** A client cancellation (`notifications/cancelled` — every ESC,
aborted turn, or subagent teardown) is treated the same way: it costs exactly one
request. `--codex_cancel_grace <seconds>` (default `30`) bounds how long Codex may
take to acknowledge it; on expiry the wrapper settles that request id locally,
suppresses Codex's late response, and leaves the bridge and every sibling call
running. Settling the request is **not** proof Codex stopped — an unacknowledged
turn is recorded as abandoned and may keep running and writing. The mid-frame
escalation described above arms a second full grace, so that path takes roughly
twice as long before the bridge finalizes. The grace is generous on purpose — a Codex mid-turn is running sandboxed
commands and does not service MCP cancellation quickly, so a short grace would
make the escalation path the default path. This matters more than the timeout
case because the isolated `CODEX_HOME` holds Codex's `sessions/` directory: a
whole-bridge teardown makes every `threadId` in that process permanently
unresumable, and the next `codex-reply` fails with `Session not found`.

> [!WARNING]
> Abandoning a request does **not** stop Codex. The wrapper asks it to stop, but
> a turn that ignores the cancellation keeps running — and keeps writing to the
> workspace — long after the client gave up. Every abandonment is logged to
> stderr with its `thread_id` and `job_id`, and logged again if the turn later
> finishes, so an unexpectedly modified tree can be explained rather than
> guessed at. Background jobs are the sharp edge here: a `codex-start` job lives
> in this wrapper's job table, **not** in the MCP client's task registry, so a
> client-side "stop task" cannot reach it — only `codex-cancel` with its `jobId`
> can. Because a job is polled through this process it can never survive a
> reconnect, so a client disconnect cancels every non-terminal job and open
> request, and a bounded wind-down reaps the Codex process group if it keeps
> working anyway.

`--timeout <seconds>` is also enforced for Codex calls (default `7200`) as an
immutable hard deadline. Correlated activity can extend the idle window but
never this hard deadline. Set the wrapper deadline below the MCP client's own
wall-clock tool timeout when the client must always receive the wrapper's
explicit error before it gives up.

When the incoming request supplies `_meta.progressToken`, the wrapper sends
standard MCP `notifications/progress` updates using that exact token. It never
invents a progress token. The first useful status is immediate; later updates
are coalesced to at most one per second, with the latest status winning. During
otherwise silent work, a `Codex: still running` notice is sent every 10 seconds
and includes the age of the last request-correlated Codex event.

Status text is fail-closed. The bridge exposes explicitly attributed commentary,
the active plan step, and generic lifecycle summaries for commands, patches,
MCP tools, web/image work, and subagents. It does not expose final-answer text,
reasoning, prompts, command strings or output, tool arguments, search queries,
file paths, or token telemetry. Messages are whitespace-normalized and capped
at 200 Unicode code points. Native `codex/event` frames remain byte-for-byte
unchanged except that a typed `unauthorized` error event is replaced by the
single structured auth failure above; progress is a parallel MCP channel and is
normally UI status rather than additional tool-result/model context.

**Optional background jobs.** Existing `codex` and `codex-reply` calls remain
blocking and keep their current behavior. Clients that need transcript-visible
updates can instead use the six wrapper-owned job tools advertised by the Codex
bridge:

| Tool | Purpose |
| --- | --- |
| `codex-start` | Start a job with the same arguments as `codex` |
| `codex-reply-start` | Start a reply with the same arguments as `codex-reply` |
| `codex-status` | Long-poll status using the returned `jobId` and `cursor` |
| `codex-commentary` | Read retained commentary from an absolute offset |
| `codex-result` | Read the terminal answer in bounded pages |
| `codex-cancel` | Idempotently request cancellation |

**Prefer the blocking `codex` call, including for long builds.** It costs one tool
call instead of one caller turn per status change, still streams
`notifications/progress` to a progress-aware UI, and is canceled by aborting the
turn. Reach for a job only when the work must *outlive* the caller — it has to keep
running after you stop waiting, or another agent must be able to cancel it later by
`jobId`.

### `codex-peek` — is that turn still working?

A blocking call is opaque until it returns, which makes "wedged" and "busy" look
identical from outside. `codex-peek` answers that without cancelling anything to find
out: it lists every Codex turn in flight, blocking and background alike, read-only and
immediate, and takes optional `cwd` / `threadId` / `requestId` filters.

| Field | Meaning |
| --- | --- |
| `requestId` | A **client** call's handle, stable for its lifetime. This is the wrapper's internal `type:value` key, not the raw JSON-RPC id, and it is not accepted by `notifications/cancelled` |
| `jobId` | A **background job's** handle, in place of `requestId` — a job's native request runs in the wrapper's private id namespace, which is never handed out |
| `state` | `running`, or `canceling` for a turn whose cancellation is not confirmed — still executing, still writing |
| `threadId` | Present once Codex reports it; names the rollout file too |
| `cwd`, `cwdInferred`, `cwdUnknown` | The workspace; `cwdInferred` when recovered from the thread rather than the call; `cwdUnknown` when it could not be recovered at all |
| `sandbox` | The sandbox the turn was granted |
| `elapsedSeconds` | Wall clock since the call started — **not** progress |
| `lastActivitySeconds` | Since the last correlated Codex event — small and falling means healthy |

Do not look for a per-turn process instead: `codex mcp-server` is long-lived and
multiplexes every request, so there is no `codex exec` to find and a process-table
check reports nothing while a build is running.

Three answers that mean less than they look like. An **empty list** is not evidence a
turn finished — an abandoned turn keeps running inside Codex with nothing in flight
left to report, and their count comes back as `abandonedTurnsProcessWide` — named for its scope,
because an abandoned turn retains no workspace and so is never narrowed by a filter. A large `elapsedSeconds` is not a stall — it is only wall clock
— and a large `lastActivitySeconds` is not one either: a single tool call can
legitimately run silent for many minutes, so quiet is *unproven*, never *finished*.
Cancelling to find out is the one thing that cannot be undone. And a `cwd` filter never
hides a turn whose workspace is unknown — it reports it with `cwdUnknown`, because
"I cannot tell" must not silently become "nothing is running there".

The start result returns immediately with an opaque `jobId`, status `cursor`,
and the next suggested call. Repeated `codex-status` calls produce ordinary MCP
tool results, so an outer agent or subagent can relay what Codex is doing even
when its UI does not render `notifications/progress` — the one visibility a job
offers that a blocking call does not. At the current cursor a status call waits for
a change and then returns a heartbeat; `wait_ms` may be set from `0` to `60000`, and
when omitted it defaults to the status interval below (`10000` when that pacing is
disabled).

Two things end a status wait, and both matter to poll cost. A **cursor advance** is
paced server-side by `--codex_status_interval <seconds>` (default `30`), which
coalesces intermediate progress instead of bumping the cursor on every message. The
**`wait_ms` heartbeat** is the other, and it is not paced by that interval — so
`wait_ms` now tracks the status interval (capped at `60000`, so an interval above 60
seconds still heartbeats every 60) to keep a heartbeat
from out-pacing the cursor it reports on. `wait_ms` remains a ceiling on *idle*
waiting and never a floor on poll spacing: a status call returns **immediately**
whenever the cursor is already behind the head, so a poller that has fallen behind
cannot be slowed by raising it — but a caught-up one can, which is why lowering
`wait_ms` costs turns for nothing.

Only intermediate progress updates are paced; lifecycle transitions — the first
`running`, a cancellation, and any terminal state — bump the cursor and wake every
waiter directly, bypassing the interval, so raising it never delays completion. Stall detection is likewise
unaffected — `lastActivitySeconds` is stamped from raw Codex events, not from status
ticks — and `codex-commentary` still retains the full narrative. `0` restores a cursor
advance on every change; values above `60` leave the heartbeat ceiling in charge and
only let the status text go stale. Progress *notifications* keep their own, much finer
cadence and cost the caller no context — but note they are emitted only for a
**blocking** call: a background job's request carries no progress token, so a job's
only visibility is `codex-status` / `codex-commentary`.

When `commentaryEndOffset` advances, call `codex-commentary` with the last
`nextOffset`. Commentary contains only Codex messages explicitly marked with
the `commentary` phase. Hidden reasoning, prompts, final-answer drafts, command
strings and output, tool arguments, paths, search queries, and raw response
items are excluded. Unsafe terminal controls are stripped, but the remaining
text is model-authored and must still be treated as untrusted. Offsets count
Unicode code points. Each read returns at most 32,768 code points; the bridge
retains a one-MiB UTF-8 tail and reports absolute truncation boundaries when
older commentary has fallen out of the buffer.

Once status is terminal, use `codex-result` and continue from `nextOffset` until
`done` is true. Each page returns its payload as both ordinary MCP text content
and `structuredContent.text` for clients that prioritize structured results.
Result pages are also capped at 32,768 code points. A native
result frame larger than the bridge's 10 MiB capture limit fails the job
atomically instead of leaking its private response onto the MCP transport.

Jobs are deliberately connection-local: restarting or reconnecting the MCP
server loses them. At most eight jobs may be active and 32 records retained;
terminal records expire after one hour. Cancellation has the same bounded
settlement semantics as a blocking call, so inspect the working tree before
retrying a canceled write-capable job. The job API is a call-level opt-in and
does not require MCP Tasks support from the client.

These notices deliberately keep a progress-aware client's idle window alive,
leaving liveness authority with the wrapper's idle and hard deadlines. They do
not refresh `--codex_idle_timeout`, extend the wrapper's hard deadline, or
extend a client's separate hard wall-clock tool timeout. A generated progress
frame is inserted only at a native newline boundary; if Codex stalls halfway
through a frame, the latest notice waits for a safe boundary and the real idle
watchdog still terminates a permanent stall. Configure the client timeout to
exceed the longest expected Codex run plus response headroom; when it expires,
the client cancels the call and the bounded cancellation path below takes over.

**Terminal-result recovery.** Codex announces the thread ID on an early,
request-correlated session event, so the wrapper retains it before the build
finishes. If Codex later emits its terminal completion event and final agent
message but its native `tools/call` response does not arrive within the short
terminal-response grace period, the wrapper returns an equivalent successful
result containing both `content` and `structuredContent.threadId`. A matching
late native response is discarded, preserving exactly-once JSON-RPC response
semantics. This covers the failure mode where work landed in the tree but the
caller otherwise received neither the result nor the thread ID.

**Cancellation and reconnect.** Client cancellation starts a short,
non-resettable grace period bounded by `--codex_cancel_grace` (the mid-frame escalation below arms
a second one, so that path can take about twice as long). If Codex does not
settle within it, the wrapper settles that request id locally, suppresses Codex's
late response, and **leaves the bridge and every sibling call running** — a single
stalled call must never take the whole bridge down. Two bounded exceptions: a stream
wedged mid-frame that also ignores the cancellation (with no safe boundary at which
to inject an error, the wrapper retries once and then escalates to a whole-bridge
teardown), and the aggregate cap — once suppressed responses reach
`MAX_SUPPRESSED_CODEX_RESPONSES` the bridge finalizes rather than track them
indefinitely. After either, the client reconnects to a fresh bridge. A native
response that arrives inside the grace period is discarded whenever it can be
intercepted without corrupting a partially forwarded frame. The canceled,
potentially write-capable call is never replayed automatically. **Cancellation is
best-effort and does not prove Codex stopped** — an unacknowledged turn is recorded
as abandoned, not terminated, and may keep running and writing the workspace, so
inspect the working tree before manually retrying it.

This legacy bridge deliberately does **not** respawn `codex mcp-server` inside
the existing stdio connection or transparently replay threads. `codex-reply`
state belongs to the old Codex process, so a thread ID from a torn-down child
cannot be resumed after reconnect. Durable same-connection recovery requires a
separate migration from the transparent legacy pass-through to an MCP adapter
over `codex app-server` (`thread/start`, `turn/start`, `turn/interrupt`, and
`thread/resume`).

## Integration with Claude Code

Add entries to your project's `.mcp.json` using a globally installed `mcp-agents`
binary:

```json
{
  "mcpServers": {
    "codex": {
      "command": "mcp-agents",
      "args": ["--provider", "codex"],
      "timeout": 7500000
    },
    "gemini": {
      "command": "mcp-agents",
      "args": ["--provider", "gemini"]
    }
  }
}
```

**npm (global install) vs `npx` — prefer a globally installed binary.** The
`command: "mcp-agents"` form above launches a locally installed binary directly;
the [npx alternative](#alternative-using-npx) below runs `npx -y mcp-agents` on
**every** process start. That matters for reliability, not just cold-start speed:
Claude Code re-launches the stdio server whenever it (re)connects — including
after a mid-session reconnect — and `npx` performs a package-registry resolution
on each launch with no offline fallback. If that resolution is slow (VPN, captive
portal, registry hiccup), stale-cached to a version that no longer exists
(`npm error code ETARGET`), or otherwise fails, the launch fails, the transport
closes, and the tools are gone for the session. A globally installed binary (or
an absolute path to `node server.js`) removes the network dependency and one
process level from the signal/teardown path. Install once with `npm install -g
mcp-agents` (or `npm link` from a source checkout), then point the config at it.

For a **from-source checkout** used as your personal Codex bridge, a user-level
`~/.claude.json` entry can launch the tree directly and disable the per-request
idle cap (so a long, legitimately-silent review is bounded only by the client's
own wall-clock timeout rather than aborted early):

```json
{
  "mcpServers": {
    "codex": {
      "type": "stdio",
      "command": "node",
      "args": ["/absolute/path/to/mcp-agents/server.js", "--provider", "codex", "--codex_idle_timeout", "0"],
      "env": {},
      "timeout": 3600000
    }
  }
}
```

Bare `node` resolves against the MCP client's `PATH`; if `node` is managed by a
version manager (nvm/fnm/asdf) that isn't initialized in that environment, use an
absolute node path instead (`which node`, e.g. `/opt/homebrew/bin/node`).

Override codex defaults at server startup:

```json
{
  "mcpServers": {
    "codex": {
      "command": "mcp-agents",
      "args": ["--provider", "codex", "--model", "gpt-5.6-sol", "--model_reasoning_effort", "xhigh", "--codex-workspace-network=false"],
      "timeout": 7500000
    }
  }
}
```

Every initial `codex` call may select `gpt-5.6-sol` or `gpt-5.6-terra` and
`medium`, `high`, `xhigh`, or `max`; omitted selectors use the server defaults,
and replies inherit both choices. Other models, raw `config`, and per-call
approval-policy arguments are rejected before Codex runs. Add
`"--goal", "<text>"` to `args` to provide a default objective (see
[Goal injection](#codex-pass-through) above).

Claude interprets the per-server `timeout` in milliseconds as a hard wall-clock
cap; progress does not extend it. Keep it above the wrapper's `--timeout`
(7,200 seconds by default), including response headroom. A project `.mcp.json`
entry can override a user-level MCP entry of the same name, so put the timeout
on the project entry instead of relying on the user-level copy.

Except for the explicit Fast-mode pair described above, the bridge does not inherit
settings from your normal `~/.codex/config.toml`. In particular, inherited MCP
servers remain intentionally unavailable inside bridged Codex sessions.

<a id="alternative-using-npx"></a>

<details>
<summary>Alternative: using npx (zero install, less reliable launch)</summary>

```json
{
  "mcpServers": {
    "codex": {
      "command": "npx",
      "args": ["-y", "mcp-agents", "--provider", "codex"],
      "timeout": 7500000
    }
  }
}
```

`npx` only affects process launch — once connected, tool-call latency is the same
server code either way. But every launch (including each reconnect) resolves the
package against the npm registry with no offline fallback, so a slow, offline, or
stale-cached resolution can fail the launch and drop the tools mid-session (see
[npm vs npx](#integration-with-claude-code) above). Pinning `mcp-agents@x.y.z`
avoids a mid-session `@latest` picking up a freshly published version, but does
not remove the per-launch network dependency. Use `npx` only when zero install
matters more than launch reliability.

</details>

## Integration with OpenAI Codex

Add two entries to `~/.codex/config.toml` — one per provider you want available.
The 960-second Claude client timeout preserves compatibility with the blocking
900-second `claude_code` tool. Background reviews do not hold one MCP request
open: `claude-start` returns immediately and each `claude-status` poll lasts at
most 60 seconds.

```toml
[mcp_servers.claude-code]
command = "mcp-agents"
args = ["--provider", "claude"]
tool_timeout_sec = 960

[mcp_servers.claude-code.tools.claude-start]
approval_mode = "approve"

[mcp_servers.claude-code.tools.claude-status]
approval_mode = "approve"

[mcp_servers.claude-code.tools.claude-result]
approval_mode = "approve"

[mcp_servers.claude-code.tools.claude-cancel]
approval_mode = "approve"

[mcp_servers.gemini]
command = "mcp-agents"
args = ["--provider", "gemini"]
tool_timeout_sec = 360
```

In a Codex session, ask for a Claude second opinion or review and use
`claude-start` → `claude-status` → `claude-result`. Keep `claude_code` for tiny
blocking prompts; `gemini` remains a blocking tool.

## Development

```bash
npm install
npm link          # symlinks mcp-agents to your local server.js
```

After `npm link`, any edits to `server.js` take effect immediately — no reinstall needed.

Benchmark the startup paths through real `/tmp` project `.mcp.json` files:

```bash
npm run bench:mcp-startup
```

This measures MCP launch through `initialize` and `tools/list`; it does not call
the provider model/tool.

For a manual Claude background check, call `claude-start` with a short review
prompt and this repository as `cwd`, poll `claude-status` with each returned
cursor, and read the verdict with `claude-result`. For the inverse direction,
have Claude Code call `codex-start`, poll `codex-status`, and read
`codex-result`. These smoke checks use real model calls and remain separate from
the deterministic test-suite gate.

## How it works

1. An MCP client connects over stdio
2. The server reads `--provider <name>` from its argv (defaults to `codex`)
3. Gemini registers one blocking CLI tool; Claude registers its legacy blocking
   tool plus the one-shot review-job tools; Codex forwards its native tools and
   adds its background-job tools
4. Client calls `tools/call` with the tool name and a `prompt`
5. The server runs the CLI as a detached child process; Claude review jobs parse
   stream-json into safe status and retained result pages, while blocking tools
   return normalized provider output

The server keeps a small keepalive timer so Node.js does not exit prematurely
when stdin reaches EOF before an async subprocess registers an active handle.
For Claude and Gemini provider mode, that keepalive is cleared during shutdown.
When the MCP stdio connection closes, active Claude jobs receive an interrupt
and bounded TERM/KILL fallback; any remaining tracked detached provider process
groups are reaped before the server exits.

## License

MIT
