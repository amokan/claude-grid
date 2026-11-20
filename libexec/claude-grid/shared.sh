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

# The commands the slash command picker offers when the config lists none. slash_command= lines
# in the config replace the whole list.
# shellcheck disable=SC2034 # read by the scripts that source this
DEFAULT_SLASH_COMMANDS=("/reload-plugins" "/reload-skills")

# Prints why a slash command can't be used and fails, or succeeds silently. It's typed into
# every ready pane and followed by Enter, so a line break would send part of it early.
validate_slash_command() {
  [[ "$1" != *[[:cntrl:]]* ]] || { echo "can't contain line breaks or other control characters"; return 1; }
  [[ "$1" == /[![:space:]/]* ]] || { echo "must start with / and a command name, e.g. /reload-plugins"; return 1; }
}
