# shellcheck shell=bash
# Terminal styling shared by claude-grid and install.sh (sourced, not run).
# Output is plain text when stdout isn't a terminal, TERM is dumb, or NO_COLOR is set.

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
  UI_COLOR=1
  UI_BOLD=$'\033[1m' UI_DIM=$'\033[2m' UI_RESET=$'\033[0m'
else
  UI_COLOR=0
  UI_BOLD="" UI_DIM="" UI_RESET=""
fi

# "#RRGGBB" -> "R;G;B"
ui_rgb() {
  local hex="${1#\#}"
  printf '%d;%d;%d' "$((16#${hex:0:2}))" "$((16#${hex:2:2}))" "$((16#${hex:4:2}))"
}

ui_fg() { [ "$UI_COLOR" = 1 ] && printf '\033[38;2;%sm' "$(ui_rgb "$1")" || true; }
ui_bg() { [ "$UI_COLOR" = 1 ] && printf '\033[48;2;%sm' "$(ui_rgb "$1")" || true; }

# A colored square, or [#RRGGBB] without color.
ui_chip() {
  if [ "$UI_COLOR" = 1 ]; then printf '%s    %s' "$(ui_bg "$1")" "$UI_RESET"; else printf '[%s]' "$1"; fi
}

# The logo: a 2x2 grid of state colors next to the name.
# Usage: ui_banner [waiting-color] [active-color] [border-color] [tagline]
ui_banner() {
  local w="${1:-#E69F00}" a="${2:-#56B4E9}" b="${3:-#3a3a3a}" tagline="${4:-}"
  local cw ca cb r="$UI_RESET"
  cw="$(ui_fg "$w")" ca="$(ui_fg "$a")" cb="$(ui_fg "$b")"
  echo
  printf '  %s██%s  %s██%s   %s%s┏━╸╻  ┏━┓╻ ╻╺┳┓┏━╸%s   %s%s┏━╸┏━┓╻╺┳┓%s\n' "$cw" "$r" "$ca" "$r" "$UI_BOLD" "$cw" "$r" "$UI_BOLD" "$ca" "$r"
  printf '           %s%s┃  ┃  ┣━┫┃ ┃ ┃┃┣╸ %s%s╺━╸┃╺┓┣┳┛┃ ┃┃%s\n' "$UI_BOLD" "$cw" "$r" "$UI_BOLD$ca" "$r"
  printf '  %s██%s  %s██%s   %s%s┗━╸┗━╸╹ ╹┗━┛╺┻┛┗━╸%s   %s%s┗━┛╹┗╸╹╺┻┛%s\n' "$cb" "$r" "$cb" "$r" "$UI_BOLD" "$cw" "$r" "$UI_BOLD" "$ca" "$r"
  [ -z "$tagline" ] || printf '           %s%s%s\n' "$UI_DIM" "$tagline" "$r"
  echo
}

# A section heading: ── Title ─────
ui_header() {
  local title="$1" line="" i
  for ((i = ${#title}; i < 54; i++)); do line="${line}─"; done
  printf '\n%s──%s %s%s%s %s%s%s\n' "$UI_DIM" "$UI_RESET" "$UI_BOLD" "$title" "$UI_RESET" "$UI_DIM" "$line" "$UI_RESET"
}

ui_ok() { printf '  %s✓%s %s\n' "$(ui_fg '#5fd787')" "$UI_RESET" "$*"; }
ui_note() { printf '  %s•%s %s\n' "$(ui_fg '#56B4E9')" "$UI_RESET" "$*"; }
ui_warn() { printf '  %s!%s %s\n' "$(ui_fg '#E69F00')" "$UI_RESET" "$*"; }
ui_fail() { printf '  %s✗%s %s\n' "$(ui_fg '#ff5f5f')" "$UI_RESET" "$*"; }
ui_dim() { printf '%s%s%s' "$UI_DIM" "$*" "$UI_RESET"; }

# Clears the screen in a terminal; prints a blank line otherwise.
ui_clear() { if [ "$UI_COLOR" = 1 ]; then printf '\033[H\033[2J'; else echo; fi; }
