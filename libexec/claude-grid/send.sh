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

opt() { tmux show -gqv "$1"; }

DEFAULT_COMMANDS=("/reload-plugins" "/reload-skills")

# Prints why a command can't be sent and fails, or succeeds silently.
check_command() {
  [[ "$1" != *[[:cntrl:]]* ]] || { echo "can't contain line breaks or other control characters"; return 1; }
  [[ "$1" == /[![:space:]/]* ]] || { echo "must start with / and a command name, e.g. /reload-plugins"; return 1; }
}

# The commands the picker offers, one per line, from the file claude-grid writes for the grid.
COMMANDS=()
load_commands() {
  local file line
  file="$(opt @cg_state)/slash-commands"
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      check_command "$line" >/dev/null && COMMANDS+=("$line")
    done <"$file"
  fi
  [ ${#COMMANDS[@]} -gt 0 ] || COMMANDS=("${DEFAULT_COMMANDS[@]}")
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

# Sorts the grid's panes into READY (pane ids) and SKIPPED ("3:name (reason)").
READY=()
SKIPPED=()
survey() {
  local id index state name reason
  READY=()
  SKIPPED=()
  # @claude_hook_state is the last state a hook reported. Unlike @claude_state, focusing a pane
  # doesn't reset it, so a dialog the user has looked at but not answered still counts.
  while read -r id index state; do
    name="$(tmux display -p -t "$id" '#{@claude_name}')"
    name="${name//[[:cntrl:]]/?}"
    case "$state" in
      idle | done)
        prompt_is_empty "$id"
        case $? in
          0) READY+=("$id"); continue ;;
          1) reason="has unsent text in its prompt" ;;
          *) reason="its prompt isn't showing" ;;
        esac ;;
      working) reason="working" ;;
      waiting) reason="waiting on a dialog" ;;
      exited) reason="Claude has exited" ;;
      '') reason="no state reported yet" ;;
      *) reason="$state" ;;
    esac
    SKIPPED+=("$index:$name ($reason)")
  done < <(tmux list-panes -s -t "$PANE" -F '#{pane_id} #{pane_index} #{@claude_hook_state}')
}

plural() { if [ "$1" = 1 ]; then echo "1 pane"; else echo "$1 panes"; fi; }

# Sends the command to the ready panes and prints one line saying what happened.
send_all() {
  local command="$1" id skipped="" msg
  if ! msg="$(check_command "$command")"; then
    echo "not sent: the command $msg"
    return 2
  fi
  survey
  for id in ${READY[@]+"${READY[@]}"}; do
    # The text is typed literally, then Enter is pressed on its own.
    tmux send-keys -t "$id" -l -- "$command"
    tmux send-keys -t "$id" Enter
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

# Character counts and cuts need a UTF-8 locale, or "…" counts as 3.
use_utf8() {
  local locale
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]-8 | *[Uu][Tt][Ff]8) return ;; esac
  locale="$(locale -a 2>/dev/null | grep -i -m 1 -E '^(C|en_US)\.utf-?8$')" && export LC_ALL="$locale"
}

rgb() { local h="${1#\#}"; printf '%d;%d;%d' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"; }

# A dark popup on dark themes and a light one on light themes, judged by the status bar color.
is_light() {
  local h="${1#\#}"
  [ "${#h}" = 6 ] || return 1
  [ $(( (299 * 0x${h:0:2} + 587 * 0x${h:2:2} + 114 * 0x${h:4:2}) / 1000 )) -gt 140 ]
}

# Cuts text to a number of characters, ending in … when it's cut.
fit() {
  if [ "${#1}" -gt "$2" ]; then printf '%s…' "${1:0:$(($2 - 1))}"; else printf '%s' "$1"; fi
}

MAX_SKIPPED=8

# The picker's height in lines, borders included; draw() prints exactly this many.
picker_height() {
  local shown=${#SKIPPED[@]}
  [ "$shown" -le "$MAX_SKIPPED" ] || shown=$((MAX_SKIPPED + 1))
  echo $((11 + shown + ${#COMMANDS[@]}))
}

open_picker() {
  local width height cols rows line item active status style
  use_utf8
  load_commands
  survey
  read -r cols rows < <(tmux display -p -c "$CLIENT" '#{client_width} #{client_height}')
  width=56
  for line in "ready: $(plural ${#READY[@]})" ${SKIPPED[@]+"${SKIPPED[@]}"}; do
    [ $((${#line} + 8)) -le "$width" ] || width=$((${#line} + 8))
  done
  for item in "${COMMANDS[@]}"; do
    [ $((${#item} + 12)) -le "$width" ] || width=$((${#item} + 12))
  done
  [ "$width" -le $((cols - 4)) ] || width=$((cols - 4))
  height="$(picker_height)"
  [ "$height" -le $((rows - 2)) ] || height=$((rows - 2))
  active="$(opt @cg_color_active)"
  status="$(opt @cg_color_status)"
  if is_light "$status"; then style="bg=#fafafa fg=#101010"; else style="bg=#101010 fg=#f2f2f2"; fi
  # tmux hands the popup's command to the shell as it is (no format expansion), so the path is
  # quoted for the shell.
  tmux display-popup -c "$CLIENT" -E -w "$width" -h "$height" -b rounded -s "$style" -S "fg=$active" \
    -T "#[align=centre fg=$active bold] send to Claudes in grid $(opt @cg_grid) " \
    "$(printf '%q' "$(opt @cg_libexec)/send.sh") menu $PANE $(printf '%q' "$CLIENT")"
}

# Fades every pane, the active one included, the way a floating pane fades the grid.
fade_grid() {
  local fade text id
  fade="$(opt @cg_fade)"
  text="$(opt @cg_color_text)"
  [ "${fade:-0}" -gt 0 ] || return 0
  for id in $(tmux list-panes -s -t "$PANE" -F '#{pane_id}'); do
    tmux set -p -t "$id" window-style "fg=${text:-#d0d0d0} dim=$fade"
    tmux set -p -t "$id" window-active-style "fg=${text:-#d0d0d0} dim=$fade"
  done
}

# Undoes fade_grid, then puts back the fade a floating pane gives the grid.
unfade_grid() {
  local id window
  for id in $(tmux list-panes -s -t "$PANE" -F '#{pane_id}' 2>/dev/null); do
    tmux set -p -u -t "$id" window-active-style
    tmux set -p -u -t "$id" window-style
  done
  for window in $(tmux list-windows -t "$PANE" -F '#{window_id}' 2>/dev/null); do
    "$(opt @cg_libexec)/float.sh" restyle "$(tmux list-panes -t "$window" -F '#{pane_id}' | head -n 1)"
  done
}

ITEMS=()
KEYS=()
SELECTED=0

draw() {
  local width i shown=0 line pad key B R DIM SEL WARN
  width=$(($(tput cols 2>/dev/null || echo 60) - 4))
  B=$'\033[1m' R=$'\033[0m' DIM=$'\033[2m'
  SEL=$'\033[48;2;'"$(rgb "$ACTIVE")"$'m\033[38;2;0;0;0m'"$B"
  WARN=$'\033[38;2;'"$(rgb "$WAITING")m"
  printf '\033[H\033[2J\n'
  printf '  %s\n' "$(fit "ready: $(plural ${#READY[@]})" "$width")"
  for line in ${SKIPPED[@]+"${SKIPPED[@]}"}; do
    shown=$((shown + 1))
    if [ "$shown" -gt "$MAX_SKIPPED" ]; then
      printf '  %s%s%s\n' "$WARN" "⚠ and $((${#SKIPPED[@]} - MAX_SKIPPED)) more skipped" "$R"
      break
    fi
    printf '  %s%s%s\n' "$WARN" "$(fit "⚠ skip $line" "$width")" "$R"
  done
  for i in "${!ITEMS[@]}"; do
    [ "$i" != 0 ] && [ "$i" != "${#COMMANDS[@]}" ] || printf '\n'
    key="${KEYS[$i]}"
    [ -z "$key" ] || key="($key)"
    line="$(fit "${ITEMS[$i]}" $((width - 6)))"
    pad=$((width - 1 - ${#line} - ${#key}))
    [ "$pad" -ge 1 ] || pad=1
    line=" $line$(printf '%*s' "$pad" '')$key"
    if [ "$i" = "$SELECTED" ]; then printf '  %s%s%s\n' "$SEL" "$line" "$R"; else printf '  %s\n' "$line"; fi
  done
  printf '\n  %s%s%s' "$DIM" "$(fit "↑↓ or j/k move · Enter or a key picks · Esc closes" "$width")" "$R"
}

# Reads one key: up, down, enter, esc, or the character typed.
read_key() {
  local k rest
  IFS= read -rsn1 k || { echo esc; return; }
  case "$k" in
    '') echo enter ;;
    $'\033')
      # An arrow key arrives as Esc [ A in one write; a lone Esc has nothing after it. bash 3.2's
      # read can only wait whole seconds, so the terminal waits 0.1 s instead.
      stty min 0 time 1
      rest="$(dd bs=8 count=1 2>/dev/null)"
      stty min 1 time 0
      case "$rest" in
        '[A' | 'OA') echo up ;;
        '[B' | 'OB') echo down ;;
        '') echo esc ;;
        *) echo other ;;
      esac ;;
    k) echo up ;;
    j) echo down ;;
    *) printf '%s\n' "$k" ;;
  esac
}

# Asks for a command and puts it in CUSTOM, empty when the user leaves the line empty. It draws on
# the terminal, so it must not run inside $(...), which would capture the screen with the answer.
CUSTOM=""
ask_custom() {
  local text msg=""
  stty "$TTY_SAVED"
  printf '\033[?25h'
  while true; do
    printf '\033[H\033[2J\n  Slash command to send (Enter on an empty line goes back):\n'
    [ -z "$msg" ] || printf '  %s%s%s\n' $'\033[38;2;'"$(rgb "$WAITING")m" "$msg" $'\033[0m'
    printf '\n  '
    IFS= read -r text || text=""
    text="${text#"${text%%[![:space:]]*}"}"
    text="${text%"${text##*[![:space:]]}"}"
    [ -n "$text" ] || break
    if msg="$(check_command "$text")"; then break; fi
  done
  printf '\033[?25l'
  stty -echo -icanon min 1 time 0
  CUSTOM="$text"
}

choose() {
  local item="${ITEMS[$1]}" report
  case "$1" in
    "$((${#ITEMS[@]} - 1))") exit 0 ;;
    "${#COMMANDS[@]}")
      ask_custom
      item="$CUSTOM"
      [ -n "$item" ] || return 0 ;;
  esac
  report="$(send_all "$item")"
  if [ -n "$CLIENT" ]; then tmux display-message -c "$CLIENT" -l "$report"; else printf '%s\n' "$report" >&2; fi
  exit 0
}

run_picker() {
  local key i
  use_utf8
  load_commands
  ACTIVE="$(opt @cg_color_active)"
  WAITING="$(opt @cg_color_waiting)"
  ITEMS=("${COMMANDS[@]}" "custom…" "cancel")
  KEYS=()
  for i in "${!COMMANDS[@]}"; do
    if [ "$i" -lt 9 ]; then KEYS+=("$((i + 1))"); else KEYS+=(""); fi
  done
  KEYS+=(c q)

  TTY_SAVED="$(stty -g)"
  trap 'stty "$TTY_SAVED" 2>/dev/null; printf "\033[?25h"; unfade_grid' EXIT
  trap 'exit 1' HUP INT TERM
  stty -echo -icanon min 1 time 0
  printf '\033[?25l'
  fade_grid
  survey

  while true; do
    draw
    key="$(read_key)"
    case "$key" in
      up) SELECTED=$(((SELECTED + ${#ITEMS[@]} - 1) % ${#ITEMS[@]})) ;;
      down) SELECTED=$(((SELECTED + 1) % ${#ITEMS[@]})) ;;
      enter) choose "$SELECTED"; survey ;;
      esc) exit 0 ;;
      *)
        for i in "${!KEYS[@]}"; do
          if [ -n "${KEYS[$i]}" ] && [ "$key" = "${KEYS[$i]}" ]; then SELECTED="$i"; choose "$i"; survey; fi
        done ;;
    esac
  done
}

case "$MODE" in
  open) open_picker ;;
  menu) run_picker ;;
  send)
    [ -n "${3:-}" ] || { echo "usage: send.sh send <pane-id> <command>" >&2; exit 2; }
    if ! msg="$(check_command "$3")"; then echo "$3: $msg" >&2; exit 2; fi
    send_all "$3" ;;
  *) echo "usage: send.sh open|menu|send <pane-id> ..." >&2; exit 2 ;;
esac
