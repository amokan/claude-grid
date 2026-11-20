#!/usr/bin/env bash
# Starts a new Claude pane in a grid, in a folder picked from the ones the grid's panes use, or in
# one typed in. The focused pane's folder comes first and starts selected, so the key and then
# Enter opens a new Claude next to the one you're in.
#
# Usage: new-pane.sh open <pane-id> <client> [other]   open the picker as a popup (keys c and C)
#        new-pane.sh menu <pane-id> [client] [other]   the picker itself, run inside the popup
# With "other", the picker starts by asking for a folder, and closes if none is given.

set -u

[ $# -ge 2 ] || { echo "usage: new-pane.sh open|menu <pane-id> [client] [other]" >&2; exit 2; }
readonly MODE="$1" PANE="$2"
CLIENT="${3:-}"
START="${4:-}"

# shellcheck source=libexec/claude-grid/popup.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/popup.sh"

# The grid's folders, focused pane's first, then in pane order, each listed once, with how many
# panes use it.
DIRS=()
COUNTS=()
list_folders() {
  local path i
  DIRS=("$(tmux display -p -t "$PANE" '#{pane_current_path}')")
  COUNTS=(0)
  while IFS= read -r path; do
    for i in "${!DIRS[@]}"; do
      if [ "${DIRS[$i]}" = "$path" ]; then COUNTS[i]=$((COUNTS[i] + 1)); continue 2; fi
    done
    DIRS+=("$path")
    COUNTS+=(1)
  done < <(tmux list-panes -s -t "$PANE" -F '#{pane_current_path}')
}

# A folder as shown: ~ for the home folder, control characters replaced.
show_path() {
  local path="$1"
  # shellcheck disable=SC2088 # a literal ~ for display
  case "$path" in "$HOME") path="~" ;; "$HOME"/*) path="~/${path#"$HOME"/}" ;; esac
  printf '%s' "${path//[[:cntrl:]]/?}"
}

# The folder a typed path means: ~ is the home folder, and a relative path starts at the focused
# pane's folder. Prints it, or fails when it isn't a folder.
resolve_folder() {
  local path="$1"
  # shellcheck disable=SC2088 # matching a literal ~ on purpose
  case "$path" in "~") path="$HOME" ;; "~/"*) path="$HOME/${path#"~/"}" ;; /*) ;; *) path="${DIRS[0]}/$path" ;; esac
  (cd "$path" 2>/dev/null && pwd)
}

check_folder() {
  resolve_folder "$1" >/dev/null || { echo "$1 isn't a folder"; return 1; }
}

# The picker's height in lines, borders included; draw prints exactly this many.
picker_height() { echo $((8 + ${#DIRS[@]})); }

open_picker() {
  local width=56 i line
  use_utf8
  list_folders
  for i in "${!DIRS[@]}"; do
    line="$(basename "${DIRS[$i]}")  $(show_path "${DIRS[$i]}")  focused · 2 panes"
    [ $((${#line} + 12)) -le "$width" ] || width=$((${#line} + 12))
  done
  open_popup "$width" "$(picker_height)" "new Claude in grid $(opt @cg_grid)" new-pane.sh menu "$PANE" "$CLIENT" "$START"
}

# Whether a folder is the focused pane's, and how many panes use it.
tag_of() {
  local tag=""
  [ "$1" != 0 ] || tag="focused"
  [ "${COUNTS[$1]}" -le 1 ] || tag="${tag:+$tag · }${COUNTS[$1]} panes"
  printf '%s' "$tag"
}

# Pads text with spaces to a number of characters.
pad() { printf '%s%*s' "$1" $(($2 - ${#1})) ''; }

# The list rows, in three columns: the folder's name, its path, and its tag.
build_items() {
  local width="$1" i name tag names=0 tags=0 paths
  for i in "${!DIRS[@]}"; do
    name="$(basename "${DIRS[$i]}")"
    [ "${#name}" -le "$names" ] || names=${#name}
    tag="$(tag_of "$i")"
    [ "${#tag}" -le "$tags" ] || tags=${#tag}
  done
  [ "$names" -le 20 ] || names=20
  # draw_items keeps 6 columns for the key; two spaces go between the columns.
  paths=$((width - 6 - names - 2))
  [ "$tags" = 0 ] || paths=$((paths - tags - 2))
  [ "$paths" -ge 8 ] || paths=8
  ITEMS=()
  KEYS=()
  for i in "${!DIRS[@]}"; do
    name="$(fit "$(basename "${DIRS[$i]}")" "$names")"
    name="${name//[[:cntrl:]]/?}"
    tag="$(tag_of "$i")"
    ITEMS+=("$(pad "$name" "$names")  $(pad "$(fit_path "$(show_path "${DIRS[$i]}")" "$paths")" "$paths")${tag:+  $tag}")
    if [ "$i" -lt 9 ]; then KEYS+=("$((i + 1))"); else KEYS+=(""); fi
  done
  ITEMS+=("other folder…" "cancel")
  KEYS+=(o q)
}

draw() {
  local width
  width="$(inner_width)"
  printf '\033[H\033[2J'
  draw_items "$width" "0 ${#DIRS[@]}"
  draw_hint "$width"
}

# Runs claude-grid to add the pane. On failure the popup shows why and waits for a key.
start_in() {
  local dir="$1" out
  if out="$("$(opt @cg_bin)" --grid "$(opt @cg_grid)" "$dir" 2>&1)"; then
    if [ -n "$CLIENT" ]; then tmux display-message -c "$CLIENT" -l "new Claude in $(show_path "$dir")"; fi
    exit 0
  fi
  printf '\033[H\033[2J\n  %sCouldn'"'"'t start a Claude in %s:%s\n\n' "$WARN" "$(show_path "$dir")" "$R"
  printf '%s\n' "${out//[[:cntrl:]]/?}" | fold -s -w "$(inner_width)" | sed 's/^/  /'
  printf '\n  %sPress a key to go back.%s' "$DIM" "$R"
  read_key >/dev/null
}

ask_folder() {
  ask_line "Folder for the new Claude (Tab completes; Enter on an empty line goes back):" check_folder
  [ -n "$ANSWER" ] || return 1
  ANSWER="$(resolve_folder "$ANSWER")"
}

choose() {
  case "$1" in
    "$((${#ITEMS[@]} - 1))") exit 0 ;;
    "${#DIRS[@]}") ask_folder && start_in "$ANSWER" ;;
    *) start_in "${DIRS[$1]}" ;;
  esac
}

run_picker() {
  # claude-grid adds the pane to the grid it runs inside, which it reads from $TMUX. Without it,
  # it would attach a terminal inside this popup.
  [ -n "${TMUX:-}" ] || { echo "new-pane.sh: needs to run inside the grid's tmux" >&2; exit 2; }
  list_folders
  start_picker
  build_items "$(inner_width)"
  # Typed paths and Tab completion start from the focused pane's folder.
  cd "${DIRS[0]}" 2>/dev/null || true
  if [ "$START" = other ]; then
    ask_folder || exit 0
    start_in "$ANSWER"
    SELECTED="${#DIRS[@]}"
  fi
  run_list
}

case "$MODE" in
  open) open_picker ;;
  menu) run_picker ;;
  *) echo "usage: new-pane.sh open|menu <pane-id> [client] [other]" >&2; exit 2 ;;
esac
