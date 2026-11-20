#!/usr/bin/env bash
# Types a slash command into every Claude pane of a grid that's ready for one, such as
# /reload-plugins after changing a plugin.
#
# A pane is skipped, and listed with the reason, when its Claude is working, is waiting on a
# dialog (Enter would answer it), has exited (the text would run in the shell), hasn't reported
# a state yet, or has unsent text in its prompt (the command would be added to it and sent as
# one prompt).
#
# Usage: send.sh open <pane-id> <client>   open the picker as a popup on that client (MENU_KEY)
#        send.sh menu <pane-id> [client]   the picker itself, run inside the popup
#        send.sh send <pane-id> <command>  send without the picker and print what happened

set -u

[ $# -ge 2 ] || { echo "usage: send.sh open|menu|send <pane-id> ..." >&2; exit 2; }
readonly MODE="$1" PANE="$2"
CLIENT="${3:-}"

# shellcheck source=libexec/claude-grid/popup.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/popup.sh"


# The commands the picker offers, one per line, from the file claude-grid writes for the grid.
COMMANDS=()
load_commands() {
  local file line
  file="$(opt @cg_state)/slash-commands"
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      validate_slash_command "$line" >/dev/null && COMMANDS+=("$line")
    done <"$file"
  fi
  [ ${#COMMANDS[@]} -gt 0 ] || COMMANDS=("${DEFAULT_SLASH_COMMANDS[@]}")
}

# Claude's prompt is the lowest screen line with ❯. It's empty, or shows a dimmed suggestion in a
# new session; anything else is text the user hasn't sent. Fails when there's no prompt line.
prompt_is_empty() {
  local line esc=$'\033'
  line="$(tmux capture-pane -e -p -t "$1" | grep -a '❯' | tail -n 1)"
  [ -n "$line" ] || return 2
  line="${line#*❯}"
  line="${line# }"
  case "$line" in "${esc}[2m"*) return 0 ;; esac
  line="$(printf '%s' "$line" | sed "s/$esc\\[[0-9;]*[A-Za-z]//g")"
  [ -z "${line//[[:space:]]/}" ]
}

# Prints why a pane can't take a command now, or nothing when it can.
# @claude_hook_state is the last state a hook reported. Unlike @claude_state, focusing a pane
# doesn't reset it, so a dialog the user has looked at but not answered still counts.
pane_problem() {
  local state
  state="$(tmux display -p -t "$1" '#{@claude_hook_state}')"
  case "$state" in
    idle | done)
      prompt_is_empty "$1"
      case $? in
        0) ;;
        1) echo "has unsent text in its prompt" ;;
        *) echo "its prompt isn't showing" ;;
      esac ;;
    working) echo "working" ;;
    waiting) echo "waiting on a dialog" ;;
    exited) echo "Claude has exited" ;;
    '') echo "no state reported yet" ;;
    *) echo "$state" ;;
  esac
}

# A pane as listed: its number and name, with control characters replaced.
pane_label() {
  local label
  label="$(tmux display -p -t "$1" '#{pane_index}:#{@claude_name}')"
  printf '%s' "${label//[[:cntrl:]]/?}"
}

# Sorts the grid's panes into READY (pane ids) and SKIPPED ("3:name (reason)").
READY=()
SKIPPED=()
survey() {
  local id reason
  READY=()
  SKIPPED=()
  for id in $(tmux list-panes -s -t "$PANE" -F '#{pane_id}'); do
    reason="$(pane_problem "$id")"
    if [ -z "$reason" ]; then READY+=("$id"); else SKIPPED+=("$(pane_label "$id") ($reason)"); fi
  done
}

plural() { if [ "$1" = 1 ]; then echo "1 pane"; else echo "$1 panes"; fi; }

# Sends the command to the ready panes and prints one line saying what happened.
send_all() {
  local command="$1" id skipped="" msg reason ready
  if ! msg="$(validate_slash_command "$command")"; then
    echo "not sent: the command $msg"
    return 2
  fi
  survey
  ready=(${READY[@]+"${READY[@]}"})
  READY=()
  for id in ${ready[@]+"${ready[@]}"}; do
    # Checked again right before typing: a pane can open a dialog while the others are sent to,
    # and Enter would answer it. The text is typed literally, then Enter pressed, in one call.
    reason="$(pane_problem "$id")"
    if [ -n "$reason" ]; then
      SKIPPED+=("$(pane_label "$id") ($reason)")
      continue
    fi
    tmux send-keys -t "$id" -l -- "$(tmux_word "$command")" \; send-keys -t "$id" Enter
    READY+=("$id")
  done
  if [ ${#SKIPPED[@]} -gt 0 ]; then
    skipped="$(printf '%s, ' "${SKIPPED[@]}")"
    skipped="; skipped ${skipped%, }"
  fi
  if [ ${#READY[@]} -gt 0 ]; then
    echo "sent $command to $(plural ${#READY[@]})$skipped"
  else
    echo "sent $command to no pane$skipped"
  fi
  [ ${#READY[@]} -gt 0 ]
}

# ---- The picker -----------------------------------------------------------------

MAX_SKIPPED=8

# The height the picker asks for, borders included. The popup can end up smaller (a short
# terminal, more panes skipped by the time it draws), so draw fits what it has instead.
picker_height() {
  local shown=${#SKIPPED[@]}
  [ "$shown" -le "$MAX_SKIPPED" ] || shown=$((MAX_SKIPPED + 1))
  echo $((11 + shown + ${#COMMANDS[@]}))
}

open_picker() {
  local width line item
  use_utf8
  load_commands
  survey
  width=56
  for line in "ready: $(plural ${#READY[@]})" ${SKIPPED[@]+"${SKIPPED[@]}"}; do
    [ $((${#line} + 8)) -le "$width" ] || width=$((${#line} + 8))
  done
  for item in "${COMMANDS[@]}"; do
    [ $((${#item} + 12)) -le "$width" ] || width=$((${#item} + 12))
  done
  open_popup "$width" "$(picker_height)" "send to Claudes in grid $(opt @cg_grid)" send.sh menu "$PANE" "$CLIENT"
}

# Lines: a blank one, ready, the skipped panes, the list (with its two blank lines), and the
# hint (a blank line and the hint). The list gets its lines first; the skipped panes get what's
# left, at least one line when any were skipped, ending in "and N more" when they don't all fit.
draw() {
  local width avail list skip shown=0 line
  width="$(inner_width)"
  avail=$(($(screen_lines) - 4))
  list=$((${#ITEMS[@]} + 2))
  skip=${#SKIPPED[@]}
  [ "$skip" -le "$MAX_SKIPPED" ] || skip=$((MAX_SKIPPED + 1))
  [ "$skip" -le $((avail - list)) ] || skip=$((avail - list))
  [ "$skip" -ge 1 ] || [ ${#SKIPPED[@]} = 0 ] || skip=1
  [ "$skip" -ge 0 ] || skip=0
  printf '\033[H\033[2J\n'
  printf '  %s\n' "$(fit "ready: $(plural ${#READY[@]})" "$width")"
  for line in ${SKIPPED[@]+"${SKIPPED[@]}"}; do
    shown=$((shown + 1))
    if [ "$shown" = "$skip" ] && [ "$skip" -lt ${#SKIPPED[@]} ]; then
      if [ "$skip" = 1 ]; then line="⚠ $(plural ${#SKIPPED[@]}) skipped"; else line="⚠ and $((${#SKIPPED[@]} - skip + 1)) more skipped"; fi
      printf '  %s%s%s\n' "$WARN" "$(fit "$line" "$width")" "$R"
      break
    fi
    printf '  %s%s%s\n' "$WARN" "$(fit "⚠ skip $line" "$width")" "$R"
  done
  draw_items "$width" "0 ${#COMMANDS[@]}" $((avail - skip))
  draw_hint "$width"
}

choose() {
  local item="${ITEMS[$1]}" report
  case "$1" in
    "$((${#ITEMS[@]} - 1))") exit 0 ;;
    "${#COMMANDS[@]}")
      ask_line "Slash command to send (Enter on an empty line goes back):" validate_slash_command
      item="$ANSWER"
      if [ -z "$item" ]; then survey; return 0; fi ;;
  esac
  report="$(send_all "$item")"
  if [ -n "$CLIENT" ]; then tmux display-message -c "$CLIENT" -l "$(tmux_word "$report")"; else printf '%s\n' "$report" >&2; fi
  exit 0
}

run_picker() {
  local i
  load_commands
  ITEMS=("${COMMANDS[@]}" "custom…" "cancel")
  KEYS=()
  for i in "${!COMMANDS[@]}"; do
    if [ "$i" -lt 9 ]; then KEYS+=("$((i + 1))"); else KEYS+=(""); fi
  done
  KEYS+=(c q)
  start_picker
  survey
  run_list
}

case "$MODE" in
  open) open_picker ;;
  menu) run_picker ;;
  send)
    [ -n "${3:-}" ] || { echo "usage: send.sh send <pane-id> <command>" >&2; exit 2; }
    if ! msg="$(validate_slash_command "$3")"; then echo "$3: $msg" >&2; exit 2; fi
    send_all "$3" ;;
  *) echo "usage: send.sh open|menu|send <pane-id> ..." >&2; exit 2 ;;
esac
