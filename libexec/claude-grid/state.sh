#!/usr/bin/env bash
# Records a Claude session's state on its tmux pane so the border can show it.
# Usage: state.sh <working|waiting|done|idle|exited|tool|notify>
# "tool" reads the PreToolUse payload and picks waiting for tools that ask the user.
# "notify" reads the Notification payload: a permission or question dialog is waiting, and
# idle_prompt (Claude has waited for input a while) is idle.

[ -n "${TMUX_PANE:-}" ] || { cat >/dev/null; exit 0; }

state="${1:-idle}"
payload="$(cat)"

# A top-level string field of the payload, made of letters and _.
field() {
  if command -v jq >/dev/null; then
    printf '%s' "$payload" | jq -r --arg key "$1" '.[$key] // empty' 2>/dev/null
  else
    # Without jq, match the top-level key. Inside a JSON string its quotes would be escaped.
    printf '%s' "$payload" | grep -oE "\"$1\" *: *\"[A-Za-z_]+\"" | head -n 1 | sed -E 's/.*"([A-Za-z_]+)"$/\1/'
  fi
}

# state ends up as what the hook reports (send.sh reads it), border as what the border shows,
# or empty to leave the border as it is.
case "$state" in
  tool)
    case "$(field tool_name)" in
      AskUserQuestion | ExitPlanMode) state="waiting" ;;
      *) state="working" ;;
    esac
    border="$state" ;;
  notify)
    if [ "$(field notification_type)" = idle_prompt ]; then
      # No hook runs when the user interrupts Claude with Esc, so this is what ends working or
      # waiting then. A done the user hasn't looked at yet stays on the border.
      state="idle"
      case "$(tmux show -pqv -t "$TMUX_PANE" @claude_state 2>/dev/null)" in
        working | waiting) border="idle" ;;
        *) border="" ;;
      esac
    else
      state="waiting"
      border="waiting"
    fi ;;
  *) border="$state" ;;
esac

[ -z "$border" ] || tmux set -p -t "$TMUX_PANE" @claude_state "$border" >/dev/null 2>&1
# Focusing a pane clears waiting and done from @claude_state once the user has seen them. This
# copy keeps what the hook reported, so send.sh can tell a dialog is still open.
tmux set -p -t "$TMUX_PANE" @claude_hook_state "$state" >/dev/null 2>&1
exit 0
