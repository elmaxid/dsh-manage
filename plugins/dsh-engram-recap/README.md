# dsh-engram-recap

Forces periodic Engram memory recall and save reminders for DeepSeek Harness
agents, so knowledge survives across sessions without depending on the model
remembering to do it unprompted.

## Problem

Engram's own MCP tool descriptions say things like *"call this PROACTIVELY —
don't wait to be asked"*, but that is advisory prose in a tool description:
nothing in the harness enforces it. In practice, an agent that is not
explicitly told to save memory tends not to, and when a session ends without
a save, everything learned in it is lost.

## What it does

Mounts a dynamic `systemPrompt` context (re-evaluated on **every** model
request, unlike a static persona section read once at session start) that:

1. **Turn 0** — reminds the agent to call `mcp__engram__mem_context` (and
   `mem_search` for anything specific) before its first substantive action.
2. **Every `remindEvery` turns** (default 6) — reminds the agent to call
   `mcp__engram__mem_save` if the recent exchanges produced a decision,
   bugfix, discovery, or lesson learned. If nothing memory-worthy happened,
   the reminder tells it to do nothing (no forced noise-saving).

The reminder is injected as a `<system-reminder>` block, the same framing
convention `dsh-agent-instructions` uses for workspace instructions.

## Why a prompt nudge and not a direct tool call

The Host plugin execution environment has no `AbortController` or `crypto`
available, so this plugin cannot safely drive `ctx.tools.execute(...)` against
Engram's MCP tools (they require an `AbortSignal`). Steering the model via
prompt context — the same mechanism `dsh-plan-mode` uses for its policy
section — is the correct approach given that constraint, and it keeps the
actual judgment (what is "memory-worthy") with the model instead of a rigid
heuristic.

## Configuration

```yaml
- id: engram-recap
  name: 'dsh-engram-recap'
  config:
    remindEvery: 6   # optional, positive integer, default 6
```

## Requirements

Requires an Engram MCP server (`mcp__engram__*` tools) mounted on the agent;
this plugin only nudges toward those tool names, it does not provide them.
With no Engram tools available, the reminders are harmless no-ops from the
model's perspective (it simply cannot act on them).

## State and lifetime

Per-session turn counts live in an in-memory `WeakMap` keyed by `Session`,
process-local and reset on restart — same lifetime tradeoff as any other
stateless per-request Cordis contribution.

## Install

```bash
dsh plugin --profile web add dsh-engram-recap
```

Or via the homologated stack in
[dsh-manage](https://github.com/) — see its `plugins/manifest.json`.
