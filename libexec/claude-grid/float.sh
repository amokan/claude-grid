#!/usr/bin/env bash
# Floats a Claude pane over the center of the grid, keeping at most one pane floating.
# While a pane floats, the grid panes behind it are faded.
# Every command takes the pane it acts on, which also identifies the window.
# Usage: float.sh toggle <pane-id>    float the pane, or put it back if it already floats
#        float.sh focus <pane-id>     float the pane (used on focus when auto-float is on)
#        float.sh sink <pane-id>      put every floating pane in that window back into the grid
#        float.sh auto <pane-id>      turn auto-float on focus on or off
#        float.sh refit <pane-id>     resize floating panes in that window to the current window size
#        float.sh restyle <pane-id>   re-apply the fade in that window (after adding panes)

[ -n "${2:-}" ] || { echo "usage: float.sh toggle|focus|sink|auto|refit|restyle <pane-id>" >&2; exit 1; }
readonly PANE="$2"

w="$(tmux show -gqv @cg_float_width)"
h="$(tmux show -gqv @cg_float_height)"
fade="$(tmux show -gqv @cg_fade)"
text="$(tmux show -gqv @cg_color_text)"
readonly WIDTH="${w:-80}%" HEIGHT="${h:-78}%" LEFT="$(( (100 - ${w:-80}) / 2 ))%" TOP="$(( (100 - ${h:-78}) / 2 ))%"
readonly FADE="${fade:-55}" TEXT="${text:-#d0d0d0}"

panes() { tmux list-panes -t "$PANE" -F '#{pane_id} #{pane_floating_flag}'; }

sink_others() {
  local keep="$1" pane floating
  while read -r pane floating; do
    [ "$floating" = 1 ] && [ "$pane" != "$keep" ] && sink "$pane"
  done < <(panes)
}

is_floating() { [ "$(tmux display -p -t "$1" '#{pane_floating_flag}')" = 1 ]; }

# The pane ids in the window, in layout order.
grid_panes() { tmux display -p -t "$1" '#{P:#{pane_id} }'; }

# Puts a floating pane back into the grid. tmux returns it to its old place but can split the
# space one column or row differently than before, so the grid layout saved by lift is applied
# again, as long as the window still has the same panes.
sink() {
  tmux join-pane -s "$1" -t "$1"
  [ "$(tmux show -wqv -t "$1" @cg_grid_panes)" = "$(grid_panes "$1")" ] || return 0
  tmux select-layout -t "$1" "$(tmux show -wqv -t "$1" @cg_grid_layout)"
}

lift() {
  [ "$(tmux display -p -t "$1" '#{window_panes}')" -gt 1 ] || return 0
  tmux set -w -t "$1" @cg_grid_layout "$(tmux display -p -t "$1" '#{window_layout}')"
  tmux set -w -t "$1" @cg_grid_panes "$(grid_panes "$1")"
  tmux break-pane -W -s "$1" -x "$WIDTH" -y "$HEIGHT" -X "$LEFT" -Y "$TOP"
}

refit() {
  local pane floating
  while read -r pane floating; do
    [ "$floating" = 1 ] || continue
    tmux resize-pane -t "$pane" -x "$WIDTH" -y "$HEIGHT"
    tmux move-pane -t "$pane" -X "$LEFT" -Y "$TOP"
  done < <(panes)
}

restyle() {
  local pane floating any_floating=0
  panes | grep -q ' 1$' && any_floating=1
  while read -r pane floating; do
    if [ "$any_floating" = 1 ] && [ "$floating" = 0 ] && [ "$FADE" -gt 0 ]; then
      tmux set -p -t "$pane" window-style "fg=$TEXT dim=$FADE"
    else
      tmux set -p -u -t "$pane" window-style
    fi
  done < <(panes)
}

case "$1" in
  refit)
    refit ;;
  restyle) ;;
  toggle)
    sink_others "$PANE"
    if is_floating "$PANE"; then sink "$PANE"; else lift "$PANE"; fi ;;
  focus)
    sink_others "$PANE"
    is_floating "$PANE" || lift "$PANE" ;;
  sink)
    sink_others "" ;;
  auto)
    if [ "$(tmux show -gqv @cg_autofloat)" != off ]; then
      tmux set -g @cg_autofloat off
      sink_others ""
      tmux display-message -t "$PANE" "auto-float off"
    else
      tmux set -g @cg_autofloat on
      sink_others "$PANE"
      is_floating "$PANE" || lift "$PANE"
      tmux display-message -t "$PANE" "auto-float on: the focused Claude floats over the grid"
    fi ;;
esac
restyle
exit 0
