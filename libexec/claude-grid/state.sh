#!/usr/bin/env bash
# Records a Claude session's state on its tmux pane so the border can show it.
# Usage: state.sh <working|waiting|done|idle|tool>
# "tool" reads the PreToolUse payload and picks waiting for tools that ask the user.

[ -n "${TMUX_PANE:-}" ] || { cat >/dev/null; exit 0; }

state="${1:-idle}"
payload="$(cat)"

tool_name() {
  if command -v jq >/dev/null; then
    printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null
  else
    # Without jq, match the top-level key. Inside a JSON string its quotes would be escaped.
    printf '%s' "$payload" | grep -oE '"tool_name" *: *"[A-Za-z]+"' | head -n 1 | sed -E 's/.*"([A-Za-z]+)"$/\1/'
  fi
}

if [ "$state" = "tool" ]; then
  case "$(tool_name)" in
    AskUserQuestion | ExitPlanMode) state="waiting" ;;
    *) state="working" ;;
  esac
fi

tmux set -p -t "$TMUX_PANE" @claude_state "$state" >/dev/null 2>&1
exit 0
