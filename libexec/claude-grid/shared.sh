# Helpers shared by bin/claude-grid and the scripts in this folder. Sourced, not run.
# shellcheck shell=bash

# tmux ends a command at any argument that ends in ;, and drops the ;. A backslash before it
# keeps it, so every value that isn't ours (a folder, a typed command, a message) goes through
# this before it's passed to tmux as an argument. Usage: tmux ... "$(tmux_word "$value")"
tmux_word() {
  case "$1" in
    *';') printf '%s\\;' "${1%;}" ;;
    *) printf '%s' "$1" ;;
  esac
}
