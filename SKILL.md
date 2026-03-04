---
name: claude-code-delegating
description: Delegate coding tasks to a separate Claude Code CLI session for execution or discussion. Claude Code is a powerful coding assistant - great for complex refactoring, multi-file changes, architecture exploration, and nuanced implementation tasks. Use when you need a fresh perspective or want to parallelize work.
---

# Claude-Code-Delegating - Your Claude Code Coding Partner

Delegate coding execution to a separate Claude Code CLI session. Get Claude Code's full capabilities in a delegated context.

## Critical rules

- ONLY interact with Claude Code through the bundled shell script. NEVER call `claude` CLI directly.
- Run the script ONCE per task. If it succeeds (exit code 0), read the output file and proceed. Do NOT re-run or retry.
- Do NOT read or inspect the script source code. Treat it as a black box.
- ALWAYS quote file paths containing brackets, spaces, or special characters when passing to the script (e.g. `--file "src/app/[locale]/page.tsx"`). Unquoted `[...]` triggers zsh glob expansion.
- **Keep the task prompt focused.** Aim for under ~500 words. Describe WHAT to do and key constraints, not step-by-step HOW. Claude Code is an autonomous agent with full workspace access - it reads files, explores code, and figures out implementation details on its own.
- **Reference files by mentioning them in the prompt.** Claude Code will read them directly. Don't paste file contents.
- **Don't reference or describe the SKILL.md itself in the prompt.** Claude Code doesn't need to know about this skill's configuration.

## How to call the script

The script path is:

```
~/.claude/skills/claude-code-delegating/scripts/ask_claude.sh
```

Minimal invocation:

```bash
~/.claude/skills/claude-code-delegating/scripts/ask_claude.sh "Your request in natural language"
```

With workspace context:

```bash
~/.claude/skills/claude-code-delegating/scripts/ask_claude.sh "Refactor these components to use the new API - focus on src/components/UserList.tsx and src/components/UserDetail.tsx" \
  --workspace /path/to/project
```

Multi-turn conversation (continue a previous session):

```bash
~/.claude/skills/claude-code-delegating/scripts/ask_claude.sh "Also add retry logic with exponential backoff" \
  --session <session_id from previous run>
```

The script prints on success:

```
session_id=<uuid>
output_path=<path to markdown file>
```

Read the file at `output_path` to get Claude Code's response. Save `session_id` if you plan follow-up calls.

## Decision policy

Call Claude Code when at least one of these is true:

- The implementation plan needs a fresh perspective from a separate session.
- Complex multi-file refactoring that benefits from full context isolation.
- Architecture exploration or design discussions.
- Tasks that can run in parallel with your main work.
- You want Claude Code's specific capabilities (extended thinking, different tools).
- Deep debugging or root cause analysis requiring fresh context.
- The task is too complex or nuanced for simpler tools.

## Workflow

1. Design the solution and identify the key aspects to delegate.
2. Run the script with a clear, concise task description. Tell Claude Code the goal and constraints, not step-by-step implementation details - it figures those out itself.
3. Mention relevant files in your prompt (Claude Code has full workspace access and will read them).
4. Read the output - Claude Code executes changes and reports what it did.
5. Review the changes in your workspace.

For multi-step projects, use `--session <id>` to continue with full conversation history. For independent parallel tasks, use the Task tool with `run_in_background: true`.

## Options

- `--workspace <path>` - Target workspace directory (defaults to current directory).
- `--session <id>` - Resume a previous session for multi-turn conversation.
- `--model <name>` - Override model (default: sonnet). Options: sonnet, opus, haiku, or full model name.
- `--effort <level>` - Effort level: `low`, `medium`, `high` (default: `medium`).
- `--permission-mode <mode>` - Permission mode: `default`, `acceptEdits`, `plan` (default: `acceptEdits`).
- `--read-only` - Plan mode for pure discussion/analysis, no file changes.
- `--system-prompt <prompt>` - Override the system prompt for the session.
- `--allowed-tools <tools>` - Restrict available tools (comma-separated).
- `-o, --output <path>` - Output file path (auto-generated if not provided).
