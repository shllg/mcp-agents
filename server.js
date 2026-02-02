#!/usr/bin/env node
/* eslint-disable no-console */

import { execFile } from "node:child_process";

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

const DEFAULT_TIMEOUT_MS = 120_000;
const MAX_BUFFER_BYTES = 10 * 1024 * 1024;

// ---------------------------------------------------------------------------
// CLI Backend Definitions
// ---------------------------------------------------------------------------

const CLI_BACKENDS = {
  claude: {
    command: "claude",
    toolName: "claude_code",
    description: "Run Claude Code CLI (claude -p) with a prompt.",
    buildArgs: (prompt) => ["-p", prompt],
    extraProperties: {},
  },
  gemini: {
    command: "gemini",
    toolName: "gemini",
    description: "Run Gemini CLI (gemini -p) with a prompt.",
    buildArgs: (prompt, opts) => {
      const args = [];
      if (opts.sandbox !== false) args.push("-s");
      args.push("-p", prompt);
      return args;
    },
    extraProperties: {
      sandbox: {
        type: "boolean",
        default: true,
        description: "Run in sandbox mode (-s flag). Defaults to true.",
      },
    },
  },
  codex: {
    command: "codex",
    toolName: "codex",
    description: "Run Codex CLI (codex exec) with a prompt.",
    buildArgs: (prompt) => ["exec", prompt],
    extraProperties: {},
  },
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Never write debug logs to stdout (it breaks MCP stdio transport).
 * Use stderr only.
 */
function logErr(message) {
  process.stderr.write(`${message}\n`);
}

/**
 * Defensive string conversion for tool args.
 * @param {unknown} value
 * @returns {string}
 */
function toStringArg(value) {
  if (typeof value === "string") return value;
  if (value == null) return "";
  return String(value);
}

/**
 * Parse --provider <name> from process.argv.
 * @returns {string} Provider name (defaults to "codex")
 */
function parseProvider() {
  const idx = process.argv.indexOf("--provider");
  if (idx !== -1 && idx + 1 < process.argv.length) {
    return process.argv[idx + 1];
  }
  return "codex";
}

/**
 * Run a CLI command and return stdout (or stderr if stdout is empty).
 * @param {string} command
 * @param {string[]} args
 * @param {{ timeoutMs?: number }} [opts]
 * @returns {Promise<string>}
 */
function runCli(command, args, opts = {}) {
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;

  return new Promise((resolve, reject) => {
    const child = execFile(
      command,
      args,
      {
        timeout: timeoutMs,
        maxBuffer: MAX_BUFFER_BYTES,
        env: { ...process.env, NO_COLOR: "1" },
      },
      (error, stdout, stderr) => {
        if (error) {
          const details = [
            `${command} failed: ${error.message}`,
            stderr ? `stderr:\n${stderr}` : null,
          ]
            .filter(Boolean)
            .join("\n");

          reject(new Error(details));
          return;
        }

        const out = (stdout || stderr || "").trimEnd();
        resolve(out);
      },
    );

    // Close stdin immediately so the child process doesn't wait for piped input.
    // execFile creates a pipe for stdin by default; leaving it open causes
    // the child to hang indefinitely waiting for EOF.
    child.stdin?.end();

    child.on("error", (err) => {
      reject(new Error(`Failed to start ${command}: ${err.message}`));
    });
  });
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const providerName = parseProvider();
  const backend = CLI_BACKENDS[providerName];

  if (!backend) {
    logErr(`[mcp-agents] Unknown provider: ${providerName}`);
    logErr(
      `[mcp-agents] Available: ${Object.keys(CLI_BACKENDS).join(", ")}`,
    );
    process.exitCode = 1;
    return;
  }

  const server = new Server(
    { name: "mcp-agents", version: "0.2.0" },
    { capabilities: { tools: {} } },
  );

  const properties = {
    prompt: {
      type: "string",
      description: `Prompt for ${backend.command}`,
    },
    timeout_ms: {
      type: "integer",
      minimum: 1,
      description: `Optional timeout override (default ${DEFAULT_TIMEOUT_MS})`,
    },
    ...backend.extraProperties,
  };

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: [
      {
        name: "ping",
        description:
          "Connectivity test. Returns 'pong' instantly without calling the CLI.",
        inputSchema: {
          type: "object",
          additionalProperties: false,
          properties: {},
        },
      },
      {
        name: backend.toolName,
        description: backend.description,
        inputSchema: {
          type: "object",
          additionalProperties: false,
          properties,
          required: ["prompt"],
        },
      },
    ],
  }));

  server.setRequestHandler(CallToolRequestSchema, async ({ params }) => {
    if (params.name === "ping") {
      return { content: [{ type: "text", text: "pong" }] };
    }

    if (params.name !== backend.toolName) {
      return {
        content: [
          {
            type: "text",
            text: `Unknown tool: ${params.name}`,
          },
        ],
        isError: true,
      };
    }

    const prompt = toStringArg(params.arguments?.prompt);
    const timeoutMsRaw = params.arguments?.timeout_ms;
    const timeoutMs = Number.isInteger(timeoutMsRaw)
      ? timeoutMsRaw
      : DEFAULT_TIMEOUT_MS;

    if (!prompt.trim()) {
      return {
        content: [
          {
            type: "text",
            text: "Missing required argument: prompt",
          },
        ],
        isError: true,
      };
    }

    const extraOpts = {};
    for (const key of Object.keys(backend.extraProperties)) {
      if (params.arguments?.[key] != null) {
        extraOpts[key] = params.arguments[key];
      }
    }

    const cliArgs = backend.buildArgs(prompt, extraOpts);

    logErr(`[mcp-agents] tools/call: running ${backend.command} …`);
    try {
      const output = await runCli(backend.command, cliArgs, { timeoutMs });
      logErr("[mcp-agents] tools/call: done");
      return {
        content: [{ type: "text", text: output || "" }],
      };
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      logErr(msg);
      return {
        content: [{ type: "text", text: msg }],
        isError: true,
      };
    }
  });

  const transport = new StdioServerTransport();
  await server.connect(transport);

  // Prevent premature exit when stdin EOF arrives before async
  // request handlers (tools/call -> execFile) register active handles.
  // The SDK transport doesn't listen for stdin 'end', so the event
  // loop loses its only handle when the pipe closes.
  const keepAlive = setInterval(() => {}, 60_000);
  const origOnClose = transport.onclose;
  transport.onclose = () => {
    clearInterval(keepAlive);
    origOnClose?.();
  };

  logErr(`[mcp-agents] ready (provider: ${providerName})`);
}

process.on("unhandledRejection", (reason) => {
  logErr(
    `UnhandledRejection: ${reason instanceof Error ? reason.stack : reason}`,
  );
  process.exitCode = 1;
});

process.on("uncaughtException", (err) => {
  logErr(`UncaughtException: ${err.stack || err.message}`);
  process.exitCode = 1;
});

main().catch((err) => {
  logErr(err.stack || err.message);
  process.exitCode = 1;
});
