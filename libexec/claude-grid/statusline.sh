#!/usr/bin/env bash
# One-line Claude Code statusLine for grid panes started with --minimal-status:
#   api · main · Opus 5.5 high · 42% context · $1.23
# Claude Code sends the session as JSON on stdin. Without jq, only the folder and branch show.
# Usage: statusline.sh [accent-color]   (#RRGGBB, used for the folder name)

accent="${1:-#56B4E9}"
input="$(cat)"
hex="${accent#\#}"
color="$(printf '\033[1;38;2;%d;%d;%dm' "$((16#${hex:0:2}))" "$((16#${hex:2:2}))" "$((16#${hex:4:2}))" 2>/dev/null)"
dim=$'\033[2m'
reset=$'\033[0m'

field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

if command -v jq >/dev/null; then
  dir="$(field '.workspace.project_dir')"
  cwd="$(field '.workspace.current_dir')"
  worktree="$(field '.worktree.name')"
  branch="$(field '.worktree.branch')"
  model="$(field '.model.display_name')"
  effort="$(field '.effort.level')"
  context="$(field '.context_window.used_percentage')"
  cost="$(field '.cost.total_cost_usd')"
fi
[ -n "${dir:-}" ] || dir="$PWD"
[ -n "${cwd:-}" ] || cwd="$PWD"
[ -n "${branch:-}" ] || branch="$(git -C "$cwd" branch --show-current 2>/dev/null)"

name="${dir##*/}"
[ -z "${worktree:-}" ] || name="$name [$worktree]"
parts=("$color$name$reset")
[ -z "$branch" ] || parts+=("$branch")
[ -z "${model:-}" ] || parts+=("$model${effort:+ $effort}")
[ -z "${context:-}" ] || parts+=("$(printf '%.0f' "$context")% context")
[ -z "${cost:-}" ] || parts+=("$(printf '$%.2f' "$cost")")

line="${parts[0]}"
for part in "${parts[@]:1}"; do line="$line ${dim}·${reset} $part"; done
printf '%s\n' "$line"
