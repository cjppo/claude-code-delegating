#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ask_claude.sh <task> [options]
  ask_claude.sh -t <task> [options]

Task input:
  <task>                       First positional argument is the task text
  -t, --task <text>            Alias for positional task (backward compat)
  (stdin)                      Pipe task text via stdin if no arg/flag given

Multi-turn:
      --session <id>           Resume a previous session (session_id from prior run)

Options:
  -w, --workspace <path>       Workspace directory (default: current directory)
      --model <name>           Model override (sonnet, opus, haiku, or full name)
      --effort <level>         Effort level: low, medium, high (default: medium)
      --permission-mode <mode> Permission mode: default, acceptEdits, plan
      --read-only              Read-only mode (no file changes, uses plan mode)
      --system-prompt <prompt> Custom system prompt
      --allowed-tools <tools>  Restrict available tools (comma-separated)
  -o, --output <path>          Output file path
  -h, --help                   Show this help

Output (on success):
  session_id=<uuid>            Use with --session for follow-up calls
  output_path=<file>           Path to response markdown

Examples:
  # New task (positional)
  ask_claude.sh "Add error handling to api.ts"

  # With explicit workspace
  ask_claude.sh "Fix the bug" -w /other/repo

  # Continue conversation
  ask_claude.sh "Also add retry logic" --session <id>

  # Read-only analysis
  ask_claude.sh "Review this code for issues" --read-only
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[ERROR] Missing required command: $1" >&2
    exit 1
  fi
}

trim_whitespace() {
  awk 'BEGIN { RS=""; ORS="" } { gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, ""); print }' <<<"$1"
}

# --- Parse arguments ---

workspace="${PWD}"
task_text=""
model=""
effort=""
permission_mode=""
read_only=false
session_id=""
system_prompt=""
allowed_tools=""
output_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workspace)       workspace="${2:-}"; shift 2 ;;
    -t|--task)            task_text="${2:-}"; shift 2 ;;
    --model)              model="${2:-}"; shift 2 ;;
    --effort)             effort="${2:-}"; shift 2 ;;
    --permission-mode)    permission_mode="${2:-}"; shift 2 ;;
    --read-only)          read_only=true; shift ;;
    --session)            session_id="${2:-}"; shift 2 ;;
    --system-prompt)      system_prompt="${2:-}"; shift 2 ;;
    --allowed-tools)      allowed_tools="${2:-}"; shift 2 ;;
    -o|--output)          output_path="${2:-}"; shift 2 ;;
    -h|--help)            usage; exit 0 ;;
    -*)                   echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)                    if [[ -z "$task_text" ]]; then task_text="$1"; shift; else echo "[ERROR] Unexpected argument: $1" >&2; usage >&2; exit 1; fi ;;
  esac
done

require_cmd claude
require_cmd jq

# --- Validate inputs ---

if [[ ! -d "$workspace" ]]; then
  echo "[ERROR] Workspace does not exist: $workspace" >&2; exit 1
fi
workspace="$(cd "$workspace" && pwd)"

if [[ -z "$task_text" && ! -t 0 ]]; then
  task_text="$(cat)"
fi
task_text="$(trim_whitespace "$task_text")"

if [[ -z "$task_text" ]]; then
  echo "[ERROR] Request text is empty. Pass a positional arg, --task, or stdin." >&2; exit 1
fi

# --- Prepare output path ---

if [[ -z "$output_path" ]]; then
  timestamp="$(date -u +"%Y%m%d-%H%M%S")"
  skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  output_path="$skill_dir/.runtime/${timestamp}.md"
fi
mkdir -p "$(dirname "$output_path")"

# --- Build claude command ---

cmd=(claude -p --output-format stream-json)

# Add session resume if provided
if [[ -n "$session_id" ]]; then
  cmd+=(--resume "$session_id")
fi

# Add model override
[[ -n "$model" ]] && cmd+=(--model "$model")

# Add effort level
[[ -n "$effort" ]] && cmd+=(--effort "$effort")

# Handle permission mode (read-only takes precedence)
if [[ "$read_only" == true ]]; then
  cmd+=(--permission-mode plan)
elif [[ -n "$permission_mode" ]]; then
  cmd+=(--permission-mode "$permission_mode")
else
  # Default to acceptEdits for autonomous execution (like codex's full-auto)
  cmd+=(--permission-mode acceptEdits)
fi

# Add system prompt if provided
[[ -n "$system_prompt" ]] && cmd+=(--system-prompt "$system_prompt")

# Add allowed tools restriction
[[ -n "$allowed_tools" ]] && cmd+=(--allowed-tools "$allowed_tools")

# --- Progress watcher function ---

print_progress() {
  local line="$1"
  local tool_name preview
  # Fast string checks before calling jq
  case "$line" in
    *'"type":"tool_use"'*)
      tool_name=$(printf '%s' "$line" | jq -r '.name // empty' 2>/dev/null)
      [[ -n "$tool_name" ]] && echo "[claude] Tool: $tool_name" >&2
      ;;
    *'"type":"text"'*)
      preview=$(printf '%s' "$line" | jq -r '.text // empty' 2>/dev/null | head -1 | cut -c1-120)
      [[ -n "$preview" ]] && echo "[claude] $preview" >&2
      ;;
  esac
}

# --- Execute and capture JSON output ---

stderr_file="$(mktemp)"
json_file="$(mktemp)"
prompt_file="$(mktemp)"
trap 'rm -f "$stderr_file" "$json_file" "$prompt_file"' EXIT

# Write prompt to a temp file
printf "%s" "$task_text" > "$prompt_file"

# Execute claude with CLAUDECODE unset to allow nested execution
# Pipe from prompt file to avoid shell argument issues with long prompts
(
  unset CLAUDECODE
  cd "$workspace" && "${cmd[@]}" < "$prompt_file" 2>"$stderr_file"
) | while IFS= read -r line; do
  # Only process JSON lines (must start with '{')
  [[ "$line" != \{* ]] && continue
  # Write to json_file for later parsing
  printf '%s\n' "$line" >> "$json_file"
  # Show progress for relevant events
  print_progress "$line"
done

# Check for errors
if [[ -s "$stderr_file" ]] && grep -q '\[ERROR\]\|error:' "$stderr_file" 2>/dev/null; then
  echo "[ERROR] Claude command failed" >&2
  cat "$stderr_file" >&2
  exit 1
fi

if [[ -s "$stderr_file" ]]; then
  cat "$stderr_file" >&2
fi

# --- Extract session_id from JSON stream ---

# Look for session_id in the init message or result message
session_id_extracted="$(jq -r 'select(.session_id != null) | .session_id' < "$json_file" 2>/dev/null | head -1)"

# --- Build output markdown ---

{
  # 1. Show tool uses (commands/edits Claude ran)
  jq -r '
    select(.type == "tool_use")
    | "### Tool: " + (.name // "unknown") + "\n```\n" + ((.input | tostring) // "")[0:500] + "\n```\n"
  ' < "$json_file" 2>/dev/null

  # 2. Show tool results
  jq -r '
    select(.type == "tool_result")
    | if .is_error == true then
        "### Tool Error\n```\n" + ((.content // "") | tostring)[0:500] + "\n```\n"
      else
        ""
      end
  ' < "$json_file" 2>/dev/null

  # 3. Show all text responses from Claude
  jq -r '
    select(.type == "text")
    | .text // ""
  ' < "$json_file" 2>/dev/null

  # 4. Show result message if present
  jq -r '
    select(.type == "result")
    | .result // ""
  ' < "$json_file" 2>/dev/null

} > "$output_path"

# If nothing was captured, write a fallback
if [[ ! -s "$output_path" ]]; then
  echo "(no response from claude)" > "$output_path"
fi

# --- Output results ---

if [[ -n "$session_id_extracted" ]]; then
  echo "session_id=$session_id_extracted"
fi
echo "output_path=$output_path"
