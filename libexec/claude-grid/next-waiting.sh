#!/usr/bin/env bash
# Focuses the first pane whose Claude is waiting for input, else the first finished one.

panes="$(tmux list-panes -s -F '#{pane_id} #{window_id} #{@claude_state}')"
target="$(printf '%s\n' "$panes" | awk '$3=="waiting"{print $1" "$2; exit}')"
[ -n "$target" ] || target="$(printf '%s\n' "$panes" | awk '$3=="done"{print $1" "$2; exit}')"

if [ -z "$target" ]; then
  tmux display-message "No Claude is waiting"
  exit 0
fi

read -r pane window <<<"$target"
tmux select-window -t "$window" \; select-pane -t "$pane"
