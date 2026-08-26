# mcp-agents

MCP server that wraps AI CLI tools — [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [Antigravity CLI](https://antigravity.google/) (`agy`), and [Codex CLI](https://github.com/openai/codex) — and can proxy [Chrome DevTools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp) to a remotely leased browser.

## Prerequisites

- **Node.js >= 26**
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

# Temporary native MCP compatibility
mcp-agents --provider codex-legacy

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
| `codex` | curated blocking, job, thread, goal, review, interaction, and liveness tools | `codex app-server --stdio` |
| `codex-legacy` | legacy blocking, reply, job, status, commentary, result, cancellation, and peek tools | `codex mcp-server` |
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
resolves to; this package's own `>=26` floor stays at or above that as the
unpinned dependency tracks latest.

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

### `codex` (MCP adapter over App Server)

The default Codex provider is a wrapper-owned MCP server backed internally by the
documented stdio JSONL interface of
[`codex app-server`](https://learn.chatgpt.com/docs/app-server). It requires
Codex CLI 0.149.1 or newer. OpenAI currently labels the App Server command
experimental and unsupported for production workloads, so the adapter treats
it as a version-gated private dependency rather than exposing its protocol to
MCP clients. The outer MCP connection owns initialization, tool discovery,
validation, progress, jobs, and results; App Server stays a lazy child.

This provider never falls back to native MCP automatically. App Server and
native MCP have different durability, goal, recovery, and error semantics, so
silently changing transports would make a failed call impossible to reason
about. Select [`codex-legacy`](#codex-legacy-temporary-native-mcp-compatibility)
explicitly when temporary native MCP compatibility is required.

This removes the old bridge's biggest stability coupling. `initialize`,
`tools/list`, `ping`, and wrapper-local status tools do not depend on a healthy
Codex child. If a child exits, the next safe operation starts a fresh generation
against the same durable sessions. Any turn that was already dispatched is
reported as `codex_outcome_unknown` and is never replayed automatically, because
it may already have changed the workspace.

#### Core call contracts

The existing tools and result shapes remain available:

| Tool | Purpose |
| --- | --- |
| `codex` | Start a thread and block until its turn completes |
| `codex-reply` | Resume a durable thread and block for the next turn |
| `codex-start`, `codex-reply-start` | Start the equivalent work as a connection-local background job |
| `codex-status`, `codex-commentary`, `codex-result`, `codex-cancel` | Poll, read, collect, or cancel a job |
| `codex-peek` | Read content-free liveness for turns owned by this bridge |

`codex` accepts:

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `prompt` | string | yes | Initial user prompt |
| `cwd` | absolute path | yes | Working directory |
| `sandbox` | string | yes | `read-only`, `workspace-write`, or `danger-full-access` |
| `model` | string | no | `gpt-5.6-sol` or `gpt-5.6-terra` |
| `model_reasoning_effort` | string | no | `medium`, `high`, `xhigh`, or `max` |
| `allow_subagents` | boolean | no | Enable native in-process Codex subagents for this thread; default `false` |
| `goal` | string | no | Set the thread's native durable objective; `""` suppresses the server default |

`codex-reply` requires `prompt` and `threadId`, and optionally accepts
`goal` to replace or clear the native thread goal. Model, effort, sandbox, and
subagent policy are inherited. Both schemas set `additionalProperties: false`;
raw App Server config, instructions, provider selection, and per-call approval
policy remain unavailable.

The native App Server goal lifecycle is now real, rather than prompt
conditioning. Goal status, token budget, usage, and elapsed time survive bridge
restarts. On Codex versions whose goal-store layout has not been verified, goal
operations fail closed while goal-free turns remain available. Because
`--goal` makes every new thread goal-bearing, omit that server-wide default on
an unverified Codex version if ordinary turns must remain available.

#### Additional curated tools

The adapter exposes useful curated App Server functionality without exposing its
general config or filesystem APIs:

| Tool | Required arguments | Purpose |
| --- | --- | --- |
| `codex-steer` | `threadId`, `prompt` | Add input to the active turn; the wrapper supplies the current native `expectedTurnId` precondition |
| `codex-goal-set` | `threadId` plus one of `objective`, `status`, `tokenBudget` | Create or update the native durable goal |
| `codex-goal-get`, `codex-goal-clear` | `threadId` | Read counters or clear the goal |
| `codex-review`, `codex-review-start` | `threadId`, `target` | Run a native inline or detached review, blocking or as a job |
| `codex-thread-list` | — | List active or archived durable threads with cursor pagination |
| `codex-thread-read` | `threadId` | Read sanitized metadata and optionally bounded turn history |
| `codex-thread-fork` | `threadId` | Fork all history or through `lastTurnId` |
| `codex-thread-archive`, `codex-thread-unarchive` | `threadId` | Move a thread into or out of the archive |
| `codex-interactions` | — | List unresolved approvals or structured questions |
| `codex-interaction-resolve` | `interactionId` | Resolve with one decision or a set of question answers |

Review targets are closed objects: `{"type":"uncommittedChanges"}`,
`{"type":"baseBranch","branch":"main"}`,
`{"type":"commit","sha":"...","title":"..."}`, or
`{"type":"custom","instructions":"..."}`. Delivery is `inline` by default or
`detached`.

Thread reads and listings are bounded to 100 records per call. Returned history
is sanitized; the bridge does not expose raw App Server frames, hidden
reasoning, config, arbitrary filesystem operations, or private native request
IDs.

#### Durable state and recovery

Each startup working directory gets a project namespace beneath:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/mcp-agents/codex/
  projects/<sha256-of-canonical-startup-cwd>/v1/
```

The durable allowlist contains sessions, archived sessions, Codex's native
thread-writer locks, the version-gated goal store, wrapper operation leases, and
content-free bridge sidecars. General App Server SQLite state, logs, config,
cache, and auth snapshots remain in private per-generation homes and are
removed after the child exits.

| CLI flag | Default | Environment |
| --- | --- | --- |
| `--codex-state-root <path>` | XDG state path above | `MCP_AGENTS_CODEX_STATE_ROOT` |
| `--codex-session-retention-days <days>` | `30`; `0` disables expiry | `MCP_AGENTS_CODEX_SESSION_RETENTION_DAYS` |
| `--model <model>` | `gpt-5.6-sol` | — |
| `--model_reasoning_effort <effort>` | `xhigh` | — |
| `--codex-workspace-network=true\|false` | `true` | `MCP_AGENTS_CODEX_WORKSPACE_NETWORK_ACCESS` |
| `--codex_idle_timeout <seconds>` | `600`; `0` disables | — |
| `--codex_cancel_grace <seconds>` | `30` | `MCP_AGENTS_CODEX_CANCEL_GRACE_MS` |
| `--codex_status_interval <seconds>` | `30` | `MCP_AGENTS_CODEX_STATUS_INTERVAL_MS` |

A custom state root must be absolute and outside the served workspace.
Directories use mode `0700`, files use `0600`, and the process sets umask
`0077` before creating credential-bearing or durable state. Retention runs at
startup and daily, skips live or uncertain ownership, and removes only inactive
thread state older than the configured window.

Multiple bridge processes may share the project store, but wrapper operations
take a per-thread lease and Codex keeps its native writer lock. A live or
uncertain competing owner returns `codex_thread_busy`; stale wrapper leases are
recovered only after their owner PID is proven dead.

Bridge sidecars contain IDs, PIDs, generation, workspace, sandbox, timestamps,
rollout path, and lifecycle state—never prompts, commentary, model output, or
native request IDs. The lifecycle distinguishes `starting`, `active`,
`waiting_for_input`, `canceling`, `terminal_undelivered`, and
`outcome_unknown`, so external liveness checks do not turn uncertainty into
“finished.”

#### Isolation, approvals, and interactions

Each App Server generation receives an isolated `CODEX_HOME` and
`CODEX_SQLITE_HOME`. The bridge copies only authentication and the model cache,
writes a minimal config, strips external MCP servers and unrelated preferences,
and selectively mirrors an explicit Fast-mode opt-in. Native subagents stay off
unless the initial call sets `allow_subagents: true`; even then they are
Codex-only in-process workers and cannot re-enter this MCP bridge.

Workspace-write network access defaults to `true` so commands can reach local
services. Codex does not offer a localhost-only switch: enabling it permits
general outbound access while filesystem writes remain sandbox-bounded.

Approval policy is server-owned (`never` by default). Accepted startup values
are `untrusted`, `on-request`, and `never`; the old `on-failure` value is not
supported by App Server and is rejected with a migration error. App Server
approvals and structured questions are correlated to their turn, assigned
wrapper-owned interaction IDs, and resolved exactly once. A client that
advertises MCP form elicitation can answer foreground requests inline. A
foreground call from a non-eliciting client fails with
`codex_interaction_requires_background`; start that work as a background job,
then use `codex-interactions` plus `codex-interaction-resolve`. Secret-input
requests are rejected rather than queued or logged. Interaction waiting does
not turn into idle-timeout failure, but the immutable hard call deadline
continues to run.

#### Progress, cancellation, and jobs

Blocking calls remain the preferred path, including for long builds. When the
caller supplies an MCP progress token, the adapter sends throttled, privacy-safe
status without exposing prompts, final-answer drafts, command strings/output,
paths, tool arguments, or hidden reasoning.

Background jobs remain connection-local. At most eight are active and 32 are
retained for one hour; commentary and final results are read in bounded pages.
Use jobs only when work must outlive the caller or a client cannot render MCP
progress.

Cancellation maps to native `turn/interrupt` and is best-effort. A canceled or
timed-out write-capable turn may still have changed the workspace, so inspect
state before retrying. MCP deliberately emits no response after the client has
canceled that request; the bridge still settles its local handler after the
configured grace while retaining liveness and ownership for any native turn
that may still be writing. While the MCP connection stays open, elapsed time
alone never releases that ownership: native completion or generation
termination must prove the writer stopped. Client disconnect cancels
connection-local jobs and open turns, then reaps the private App Server process
group within a bounded grace period.

### `codex-legacy` (temporary native MCP compatibility)

`codex-legacy` preserves the complete 0.28 native MCP bridge and runs
`codex mcp-server` directly. OpenAI has
[deprecated that command](https://learn.chatgpt.com/docs/mcp-server), but still
documents it for existing integrations. This provider is the deliberate
migration escape hatch while supported Codex CLI releases continue to ship the
command.

It retains the legacy `codex`, `codex-reply`, `codex-start`,
`codex-reply-start`, `codex-status`, `codex-commentary`, `codex-result`,
`codex-cancel`, and `codex-peek` contracts, including native MCP framing,
validation, auth handling, watchdogs, and connection-local job behavior. It
does not expose App Server-only steering, native goals, reviews, thread
administration, structured interactions, durable project state, retention, or
cross-reconnect recovery. Its `goal` behavior remains the legacy
instruction/prompt transformation instead of App Server's native durable goal
lifecycle.

Exact compatibility also preserves the legacy private-home layout beneath the
server startup directory at `tmp/codex-homes/`. Those directories and copied
auth files remain permission-hardened and stale homes are swept, but this lane
does not adopt the App provider's external durable-state design. Keep that
storage difference in mind when choosing the temporary fallback.

The compatibility provider receives security and compatibility fixes, but no
new App Server-only capabilities. It will remain available while supported
Codex CLI releases provide `codex mcp-server`; any later removal will be called
out as a breaking change. There is intentionally no automatic fallback between
`codex` and `codex-legacy`.

To temporarily move an existing MCP server entry back to native MCP, change
only the provider argument and keep the MCP server key unchanged:

```json
{
  "mcpServers": {
    "codex": {
      "type": "stdio",
      "command": "mcp-agents",
      "args": ["--provider", "codex-legacy"],
      "timeout": 7500000
    }
  }
}
```

Keeping the key as `codex` preserves client-side tool names such as
`mcp__codex__codex`. Running both providers side by side requires two server
keys and therefore two client namespaces; permission and hook rules that match
the old namespace must then be updated explicitly. App Server state and
retention flags are rejected by `codex-legacy` instead of being silently
ignored.

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
`"--goal", "<text>"` to `args` to provide a default native durable objective
(see the [Codex adapter](#codex-mcp-adapter-over-app-server) above).

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

After `npm link`, edits to `server.js` or `codex-legacy.js` take effect
immediately — no reinstall needed.

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
3. Gemini registers one blocking CLI tool; Claude registers its blocking tool
   plus the one-shot review-job tools; `codex` registers a wrapper-owned MCP
   surface and starts App Server lazily behind it; `codex-legacy` runs the
   complete native MCP bridge
4. Client calls `tools/call` with the tool name and a `prompt`
5. The server runs the selected CLI as a detached child process. Claude review
   jobs parse stream-json; the App Server adapter correlates documented
   thread/turn/item events into safe progress, durable thread IDs, and retained
   result pages; the legacy provider transforms and observes native MCP frames;
   blocking tools return normalized provider output

The server keeps a small keepalive timer so Node.js does not exit prematurely
when stdin reaches EOF before an async subprocess registers an active handle.
For Claude and Gemini provider mode, that keepalive is cleared during shutdown.
When the MCP stdio connection closes, active Claude and Codex work receives a
native interrupt where available and bounded TERM/KILL fallback; any remaining
tracked detached provider process groups are reaped before the server exits.

## License

MIT
