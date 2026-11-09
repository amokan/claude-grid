#!/usr/bin/env bash
# install.sh - installs claude-grid for the current user.
#
# It writes only to the install directory (~/.local by default). Your shell rc files, your
# tmux config and your Claude Code settings are never touched.

set -euo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=libexec/claude-grid/ui.sh
. "$REPO/libexec/claude-grid/ui.sh"

PREFIX="$HOME/.local"
MODE=symlink
ACTION=install
ALIAS=""
OFFER_CONFIG=true
ASSUME_YES=false
FORCE=false

usage() {
  cat <<EOF
Usage: ./install.sh [options]

  (no options)      link PREFIX/bin/claude-grid to this checkout, so \`git pull\` upgrades it
  --copy            copy the files instead, so the checkout can be moved or deleted
  --prefix DIR      install under DIR instead of ~/.local (the command goes in DIR/bin)
  --alias NAME      also install claude-grid under a second name, if nothing on PATH uses it
  --no-config       don't offer the settings menu at the end
  --uninstall       remove claude-grid from PREFIX (your settings stay)
  --force           replace a PREFIX/bin/claude-grid that this script didn't install
  -y, --yes         accept the defaults without asking
EOF
}

die() { echo "install.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --copy) MODE=copy ;;
    --prefix)
      [ -n "${2:-}" ] || die "--prefix needs a directory"
      PREFIX="$2"; shift ;;
    --prefix=*) PREFIX="${1#--prefix=}" ;;
    --alias)
      [ -n "${2:-}" ] || die "--alias needs a name"
      ALIAS="$2"; shift ;;
    --alias=*) ALIAS="${1#--alias=}" ;;
    --no-config) OFFER_CONFIG=false ;;
    --uninstall) ACTION=uninstall ;;
    --force) FORCE=true ;;
    -y | --yes) ASSUME_YES=true ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option: $1 (see ./install.sh --help)" ;;
  esac
  shift
done

PREFIX="${PREFIX%/}"
case "$PREFIX" in
  /*) ;;
  *) die "--prefix needs an absolute path (got $PREFIX)" ;;
esac
# Installing into the checkout itself would replace its files with links to themselves.
if [ -d "$PREFIX" ]; then
  case "$(cd -P "$PREFIX" && pwd)/" in
    "$REPO"/*) die "--prefix can't be inside this checkout ($REPO)" ;;
  esac
fi
BIN_DIR="$PREFIX/bin"
LIBEXEC_DIR="$PREFIX/libexec/claude-grid"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-grid"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-grid"
INTERACTIVE=false
[ -t 0 ] && [ -t 1 ] && ! $ASSUME_YES && INTERACTIVE=true

# Asks a yes/no question. Usage: ask "Question?" y|n (the default)
ask() {
  local answer hint="[y/N]"
  [ "$2" = y ] && hint="[Y/n]"
  if ! $INTERACTIVE; then [ "$2" = y ]; return; fi
  read -r -p "  $1 $hint " answer || answer=""
  case "${answer:-$2}" in y | Y | yes) return 0 ;; *) return 1 ;; esac
}

# A claude-grid script, or a link to one (even a broken link to a moved checkout).
is_ours() {
  [ -L "$1" ] && [ ! -e "$1" ] && case "$(readlink "$1")" in */bin/claude-grid) return 0 ;; esac
  [ -f "$1" ] && sed -n 2p "$1" | grep -q '^# claude-grid - '
}

# An alias link this script made: a symlink to claude-grid in the same directory.
is_our_alias() { [ -L "$1" ] && [ "$(readlink "$1")" = claude-grid ]; }

check_requirements() {
  ui_header "Requirements"
  local version
  if command -v tmux >/dev/null; then
    version="$(tmux -V)"
    case "$version" in
      "tmux 3.8"* | "tmux 3.9"* | "tmux 4."* | "tmux next-"* | "tmux master"*) ui_ok "$version" ;;
      *) ui_warn "$version found; claude-grid needs tmux 3.8 or newer for floating panes (brew install tmux)" ;;
    esac
  else
    ui_warn "tmux not found; claude-grid needs tmux 3.8 or newer (brew install tmux)"
  fi
  if command -v claude >/dev/null; then ui_ok "claude $(ui_dim "($(command -v claude))")"; else ui_warn "claude not found on PATH; install Claude Code first"; fi
  if command -v jq >/dev/null; then ui_ok "jq"; else ui_note "jq not found (optional; question prompts use a simpler text match without it)"; fi
}

install_files() {
  ui_header "Install ($MODE)"
  local target="$BIN_DIR/claude-grid"
  if [ -e "$target" ] || [ -L "$target" ]; then
    is_ours "$target" || $FORCE || die "$target exists and isn't claude-grid; move it away or rerun with --force"
  fi
  mkdir -p "$BIN_DIR"
  if [ "$MODE" = symlink ]; then
    ln -sfn "$REPO/bin/claude-grid" "$target"
    ui_ok "$target → $REPO/bin/claude-grid"
    if [ -f "$LIBEXEC_DIR/tmux.conf" ]; then
      rm -rf "$LIBEXEC_DIR"
      ui_ok "removed the old copied files in $LIBEXEC_DIR"
    fi
  else
    rm -f "$target"
    cp "$REPO/bin/claude-grid" "$target"
    chmod 755 "$target"
    rm -rf "$LIBEXEC_DIR"
    mkdir -p "$(dirname "$LIBEXEC_DIR")"
    cp -R "$REPO/libexec/claude-grid" "$LIBEXEC_DIR"
    ui_ok "$target"
    ui_ok "$LIBEXEC_DIR"
  fi
}

# Installs the --alias name: a link to claude-grid next to it, only if no command uses the name.
install_alias() {
  local name="$ALIAS" existing re='^[A-Za-z0-9._-]+$'
  [ -n "$name" ] || return 0
  [[ "$name" =~ $re ]] && [ "$name" != claude-grid ] || die "not a usable alias name: $name"
  if is_our_alias "$BIN_DIR/$name"; then
    ui_ok "alias $name already installed"
    return 0
  fi
  existing="$(type -P "$name" 2>/dev/null || true)"
  if [ -n "$existing" ] || [ -e "$BIN_DIR/$name" ]; then
    ui_warn "skipped the alias: ${existing:-$BIN_DIR/$name} already uses the name $name"
    return 0
  fi
  ln -s claude-grid "$BIN_DIR/$name"
  ui_ok "alias $name → claude-grid"
  ui_note "a shell alias or function named $name, if you have one, still takes precedence"
}

check_path() {
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
      ui_warn "$BIN_DIR is not on your PATH. Add it in your shell's rc file, e.g."
      echo "      export PATH=\"$BIN_DIR:\$PATH\"" ;;
  esac
}

uninstall() {
  local link removed=false
  ui_header "Uninstall"
  if is_ours "$BIN_DIR/claude-grid" && [ -x "$BIN_DIR/claude-grid" ] &&
    [ -n "$("$BIN_DIR/claude-grid" ls 2>/dev/null | grep -v 'no grid running' || true)" ]; then
    ui_warn "grids are still running; they keep running until you end them (claude-grid kill --all first)"
  fi
  for link in "$BIN_DIR"/*; do
    if is_our_alias "$link"; then rm -f "$link"; ui_ok "removed alias $link"; fi
  done
  if [ -e "$BIN_DIR/claude-grid" ] || [ -L "$BIN_DIR/claude-grid" ]; then
    is_ours "$BIN_DIR/claude-grid" || $FORCE || die "$BIN_DIR/claude-grid isn't claude-grid; leaving it (use --force)"
    rm -f "$BIN_DIR/claude-grid"
    ui_ok "removed $BIN_DIR/claude-grid"
    removed=true
  fi
  if [ -f "$LIBEXEC_DIR/tmux.conf" ]; then
    rm -rf "$LIBEXEC_DIR"
    ui_ok "removed $LIBEXEC_DIR"
    removed=true
  fi
  if [ -d "$STATE_DIR" ]; then
    rm -rf "$STATE_DIR"
    ui_ok "removed generated files in $STATE_DIR"
  fi
  $removed || ui_note "claude-grid wasn't installed in $PREFIX"
  [ ! -d "$CONFIG_DIR" ] || ui_note "kept your settings in $CONFIG_DIR (delete the folder to remove them)"
  echo
}

ui_banner "#E69F00" "#56B4E9" "#3a3a3a" "installer · $(git -C "$REPO" describe --tags --always 2>/dev/null || echo "$REPO")"

if [ "$ACTION" = uninstall ]; then
  uninstall
  exit 0
fi

check_requirements
install_files
install_alias
check_path

if $OFFER_CONFIG && $INTERACTIVE && ask "Open the settings menu now (theme, prefix key, float size ...)?" y; then
  "$BIN_DIR/claude-grid" config
fi

ui_header "Done"
echo "  Start a grid:     ${UI_BOLD}claude-grid${UI_RESET}   (or claude-grid ~/project-a ~/project-b)"
echo "  Change settings:  ${UI_BOLD}claude-grid config${UI_RESET}"
echo "  Check the setup:  ${UI_BOLD}claude-grid doctor${UI_RESET}"
echo
