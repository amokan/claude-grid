# Shared by the pickers claude-grid opens in a popup over a grid (send.sh, new-pane.sh): their
# look, the fade behind them, reading keys, drawing the list, and asking for a line of text.
# Sourced, not run. The script sets PANE (a pane in the grid) and CLIENT (the terminal) first.
# shellcheck shell=bash disable=SC2034 # ANSWER and the colors are read by the scripts that source this

# shellcheck source=libexec/claude-grid/shared.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shared.sh"

# Run inside the grid (its key bindings and popups), tmux finds the grid's server through $TMUX.
# `claude-grid send` runs send.sh from outside and names the server in CG_SOCKET instead: $TMUX
# can't hold a socket path with a comma in it.
if [ -n "${CG_SOCKET:-}" ]; then
  tmux() { command tmux -S "$CG_SOCKET" "$@"; }
fi

opt() { tmux show -gqv "$1"; }

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

# The same for a path, cutting the start instead, so the folder's own name stays: …/foo/bla.
fit_path() {
  if [ "$2" -lt 2 ]; then printf '…'
  elif [ "${#1}" -gt "$2" ]; then printf '…%s' "${1:$((${#1} - $2 + 1))}"
  else printf '%s' "$1"; fi
}

# Opens a popup on CLIENT that runs SCRIPT (in this folder) with ARGS.
# Usage: open_popup WIDTH HEIGHT TITLE SCRIPT [ARG...]
open_popup() {
  local width="$1" height="$2" title="$3" script="$4" cols rows active style command arg
  shift 4
  read -r cols rows < <(tmux display -p -c "$CLIENT" '#{client_width} #{client_height}')
  [ "$width" -le $((cols - 4)) ] || width=$((cols - 4))
  [ "$height" -le $((rows - 2)) ] || height=$((rows - 2))
  active="$(opt @cg_color_active)"
  active="${active:-#56B4E9}"
  if is_light "$(opt @cg_color_status)"; then style="bg=#fafafa fg=#101010"; else style="bg=#101010 fg=#f2f2f2"; fi
  # tmux hands the popup's command to the shell as it is (no format expansion), so every word is
  # quoted for the shell.
  command="$(printf '%q' "$(opt @cg_libexec)/$script")"
  for arg in "$@"; do command="$command $(printf '%q' "$arg")"; done
  tmux display-popup -c "$CLIENT" -E -w "$width" -h "$height" -b rounded -s "$style" -S "fg=$active" \
    -T "#[align=centre fg=$active bold] $title " "$(tmux_word "$command")"
}

# float.sh restyle sets every fade, so a resize or a float while the picker is open keeps it.
restyle_grid() {
  local window
  for window in $(tmux list-windows -t "$PANE" -F '#{window_id}' 2>/dev/null); do
    "$(opt @cg_libexec)/float.sh" restyle "$(tmux list-panes -t "$window" -F '#{pane_id}' | head -n 1)"
  done
}

# Fades every pane while this picker is open: it lists itself in @cg_pickers.
fade_grid() {
  tmux set -g @cg_pickers "$(opt @cg_pickers) $$"
  restyle_grid
}

# Takes this picker off @cg_pickers. The grid stays faded while another picker is open.
unfade_grid() {
  local pid kept=""
  for pid in $(opt @cg_pickers); do [ "$pid" = "$$" ] || kept="${kept:+$kept }$pid"; done
  tmux set -g @cg_pickers "$kept" 2>/dev/null
  restyle_grid
}

# Sets up the popup's terminal and fades the grid; both are undone however the script ends.
start_picker() {
  use_utf8
  ACTIVE="$(opt @cg_color_active)"
  WAITING="$(opt @cg_color_waiting)"
  ACTIVE="${ACTIVE:-#56B4E9}" WAITING="${WAITING:-#E69F00}"
  B=$'\033[1m' R=$'\033[0m' DIM=$'\033[2m'
  SEL=$'\033[48;2;'"$(rgb "$ACTIVE")"$'m\033[38;2;0;0;0m'"$B"
  WARN=$'\033[38;2;'"$(rgb "$WAITING")m"
  TTY_SAVED="$(stty -g)"
  trap 'stty "$TTY_SAVED" 2>/dev/null; printf "\033[?25h"; unfade_grid' EXIT
  trap 'exit 1' HUP INT TERM
  stty -echo -icanon min 1 time 0
  printf '\033[?25l'
  fade_grid
}

# The popup's size: the width lines can use, and its height in lines. stty asks the terminal
# itself, so it works without TERM; a terminal that reports no size gets a usable one instead.
inner_width() {
  local rows cols
  read -r rows cols < <(stty size 2>/dev/null || echo "0 0")
  [ "${cols:-0}" -ge 20 ] || cols=60
  echo $((cols - 4))
}
screen_lines() {
  local rows cols
  read -r rows cols < <(stty size 2>/dev/null || echo "0 0")
  [ "${rows:-0}" -ge 3 ] || rows=1000
  echo "$rows"
}

# The list: ITEMS with their KEYS on the right and SELECTED highlighted. A blank line goes before
# the item at each index in GAPS (a space-separated list). It prints at most MAX lines: when the
# list is longer, the part around the selected item, with ↑ more / ↓ more where it's cut.
# Usage: draw_items WIDTH GAPS MAX
ITEMS=()
KEYS=()
SELECTED=0
draw_items() {
  local width="$1" gaps=" $2 " max="${3:-1000}" i line pad key rows=() selected_row=0 start n
  for i in "${!ITEMS[@]}"; do
    case "$gaps" in *" $i "*) rows+=("") ;; esac
    key="${KEYS[$i]}"
    [ -z "$key" ] || key="($key)"
    line="$(fit "${ITEMS[$i]}" $((width - 6)))"
    pad=$((width - 1 - ${#line} - ${#key}))
    [ "$pad" -ge 1 ] || pad=1
    line=" $line$(printf '%*s' "$pad" '')$key"
    if [ "$i" = "$SELECTED" ]; then
      selected_row=${#rows[@]}
      rows+=("$SEL$line$R")
    else
      rows+=("$line")
    fi
  done
  n=${#rows[@]}
  [ "$max" -ge 1 ] || max=1
  if [ "$n" -le "$max" ]; then
    for line in "${rows[@]}"; do printf '  %s\n' "$line"; done
    return
  fi
  # A window of max rows that keeps the selected row away from the cut edges when it can.
  start=$((selected_row - (max - 1) / 2))
  [ "$start" -le $((n - max)) ] || start=$((n - max))
  [ "$start" -ge 0 ] || start=0
  for ((i = start; i < start + max; i++)); do
    if [ "$i" = "$start" ] && [ "$start" -gt 0 ] && [ "$i" != "$selected_row" ]; then
      printf '  %s%s%s\n' "$DIM" " ↑ more" "$R"
    elif [ "$i" = $((start + max - 1)) ] && [ $((start + max)) -lt "$n" ] && [ "$i" != "$selected_row" ]; then
      printf '  %s%s%s\n' "$DIM" " ↓ more" "$R"
    else
      printf '  %s\n' "${rows[$i]}"
    fi
  done
}

draw_hint() {
  printf '\n  %s%s%s' "$DIM" "$(fit "↑↓ or j/k move · Enter or a key picks · Esc closes" "$1")" "$R"
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

# Runs the list until the script exits: calls the script's draw, then choose INDEX for the item
# picked. choose exits when it's done, or returns to show the list again.
run_list() {
  local key i
  while true; do
    draw
    key="$(read_key)"
    case "$key" in
      up) SELECTED=$(((SELECTED + ${#ITEMS[@]} - 1) % ${#ITEMS[@]})) ;;
      down) SELECTED=$(((SELECTED + 1) % ${#ITEMS[@]})) ;;
      enter) choose "$SELECTED" ;;
      esc) exit 0 ;;
      *)
        for i in "${!KEYS[@]}"; do
          if [ -n "${KEYS[$i]}" ] && [ "$key" = "${KEYS[$i]}" ]; then SELECTED="$i"; choose "$i"; break; fi
        done ;;
    esac
  done
}

# Asks for a line of text and puts it in ANSWER, empty when the user leaves the line empty. CHECK
# is a function that prints why a value is wrong and fails; the question is asked again until it
# passes. Tab completes file names. It draws on the terminal, so it must not run inside $(...),
# which would capture the screen along with the answer.
# Usage: ask_line QUESTION CHECK
ANSWER=""
ask_line() {
  local question="$1" check="$2" text msg=""
  stty "$TTY_SAVED"
  printf '\033[?25h'
  while true; do
    printf '\033[H\033[2J\n  %s\n' "$question"
    [ -z "$msg" ] || printf '  %s%s%s\n' "$WARN" "$msg" "$R"
    printf '\n'
    IFS= read -r -e -p '  ' text || text=""
    text="${text#"${text%%[![:space:]]*}"}"
    text="${text%"${text##*[![:space:]]}"}"
    [ -n "$text" ] || break
    if msg="$("$check" "$text")"; then break; fi
  done
  printf '\033[?25l'
  stty -echo -icanon min 1 time 0
  ANSWER="$text"
}
