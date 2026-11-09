#!/usr/bin/env bash
# End-to-end tests for claude-grid. Needs tmux 3.8 or newer; run with the bash you want to test,
# e.g. `/bin/bash tests/run.sh` for the bash 3.2 that macOS ships.
#
# Everything runs against a fake `claude`, private tmux sockets and temporary config, state and
# install folders, so it never touches your own grids, settings or install.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASH_BIN="${BASH:-bash}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-grid-test.XXXXXX")"
# tmux socket paths are limited to about 100 bytes, so the socket folder stays short.
SOCKETS="$(mktemp -d /tmp/cgt.XXXXXX)"
export TMUX_TMPDIR="$SOCKETS"
export XDG_CONFIG_HOME="$WORK/config" XDG_STATE_HOME="$WORK/state"
export NO_COLOR=1 CG_TEST_DIR="$WORK"
unset TMUX TMUX_PANE
CONFIG="$XDG_CONFIG_HOME/claude-grid/config"
STATE="$XDG_STATE_HOME/claude-grid"
SOCKET_DIR="$SOCKETS/tmux-$(id -u)"

cleanup() {
  local socket
  for socket in "$SOCKET_DIR"/*; do
    [ -S "$socket" ] && tmux -S "$socket" kill-server 2>/dev/null
  done
  rm -rf "$WORK" "$SOCKETS"
}
trap cleanup EXIT

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  FAIL  %s\n' "$1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/        /'; }
section() { printf '\n%s\n' "$1"; }

# check DESCRIPTION COMMAND...: passes when the command succeeds.
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }

# expect DESCRIPTION PATTERN COMMAND...: passes when the output (stdout and stderr) matches PATTERN.
expect() {
  local d="$1" pattern="$2" out
  shift 2
  out="$("$@" 2>&1)"
  if printf '%s' "$out" | grep -Eq -- "$pattern"; then pass "$d"; else fail "$d" "expected /$pattern/, got:
$out"; fi
}

# Runs claude-grid. Starting a grid ends in `tmux attach`, which fails without a terminal; the
# grid itself is already running by then.
cg() { "$BASH_BIN" "$REPO/bin/claude-grid" "$@"; }
tg() { local grid="$1"; shift; tmux -L "claude-grid-$grid" "$@"; }

# Runs a command on a pseudo-terminal (util-linux and BSD script take different arguments).
pty() {
  if script --version >/dev/null 2>&1; then
    script -qec "$(printf '%q ' "$@")" /dev/null
  else
    script -q /dev/null "$@"
  fi
}

# Runs a command on a pseudo-terminal, feeding it the given input.
on_tty() {
  local input="$1"
  shift
  { printf '%b' "$input"; sleep 3; } | pty "$@"
}

# Waits up to 5 seconds for a command to succeed.
wait_for() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do "$@" >/dev/null 2>&1 && return 0; sleep 0.5; done
  return 1
}

strip() { perl -pe 's/\e\[[0-9;]*[A-Za-z]//g; s/\r//g'; }

mkdir -p "$WORK/bin" "$WORK/proj/a" "$WORK/proj/b" "$WORK/proj/launched" "$(dirname "$CONFIG")"
cat >"$WORK/bin/claude" <<'EOF'
#!/bin/sh
echo "$@" >"$CG_TEST_DIR/args.$$"
exec sleep 600
EOF
cat >"$WORK/bin/launcher" <<'EOF'
#!/bin/sh
echo "${CLAUDE_EXTRA_ARGS:-}" >"$CG_TEST_DIR/launcher.$$"
exec sleep 600
EOF
chmod +x "$WORK/bin/claude" "$WORK/bin/launcher"
write_config() { printf '%s\n' "CLAUDE_COMMAND=$WORK/bin/claude" "$@" >"$CONFIG"; }
write_config

# shellcheck disable=SC2016 # $BASH_VERSION is for the bash under test
echo "claude-grid tests with $("$BASH_BIN" -c 'echo bash $BASH_VERSION') and $(tmux -V)"

section "Scripts"
for script in "$REPO"/bin/claude-grid "$REPO"/install.sh "$REPO"/libexec/claude-grid/*.sh; do
  check "parses: ${script#"$REPO"/}" "$BASH_BIN" -n "$script"
done
expect "--version" '^claude-grid [0-9]' cg --version
expect "-h lists the commands" 'claude-grid kill --all' cg -h
expect "unknown options are refused" 'unknown option: --bogus' cg --bogus

section "Starting a grid"
(cd "$WORK/proj" && cg a b:2 >/dev/null 2>&1)
check "grid main is running" tg main has-session -t claude
expect "three panes in two folders" '^3$' sh -c "tmux -L claude-grid-main list-panes -s -t claude | wc -l | tr -d ' '"
expect "panes are named after their folders" 'a b b' sh -c "tmux -L claude-grid-main list-panes -s -t claude -F '#{@claude_name}' | tr '\n' ' '"
wait_for sh -c "ls '$WORK'/args.* >/dev/null 2>&1"
expect "each Claude gets the generated hooks file" "--settings $STATE/claude-hooks.json" sh -c "cat '$WORK'/args.*"
if command -v jq >/dev/null; then
  # jq may be a version-manager shim that needs the real XDG folders.
  check "the hooks file is valid JSON" env -u XDG_CONFIG_HOME -u XDG_STATE_HOME jq -e '.hooks.PreToolUse[0].hooks[0].command | test("state.sh. tool$")' "$STATE/claude-hooks.json"
fi
expect "the grid knows its name" '^main$' tg main show -gqv @cg_grid
expect "the prefix is applied" '^C-Space$' tg main show -gqv prefix
expect "ls shows the grid and its panes" 'grid main \(detached\)' cg ls

section "Floating"
pane="$(tg main list-panes -t claude -F '#{pane_id}' | head -n 1)"
tg main run-shell -t "$pane" "#{q:@cg_libexec}/float.sh toggle $pane"
expect "f floats the pane" '^1$' tg main display -p -t "$pane" '#{pane_floating_flag}'
expect "the grid behind it is faded" 'dim=55' sh -c "tmux -L claude-grid-main list-panes -t claude -F '#{pane_id}' | tail -n 1 | xargs -I{} tmux -L claude-grid-main show -pv -t {} window-style"
tg main run-shell -t "$pane" "#{q:@cg_libexec}/float.sh sink $pane"
expect "Esc puts it back" '^0$' tg main display -p -t "$pane" '#{pane_floating_flag}'

section "Pane state hook"
grid_tmux="$SOCKET_DIR/claude-grid-main,1,0"
state_of() { tg main show -pv -t "$pane" @claude_state; }
hook_with_path() {
  printf '%s' "$3" | env -i PATH="$1" TMUX="$grid_tmux" TMUX_PANE="$pane" "$BASH_BIN" "$REPO/libexec/claude-grid/state.sh" "$2"
}
mkdir -p "$WORK/nojq"
for tool in tmux grep sed head cat; do ln -s "$(command -v "$tool")" "$WORK/nojq/$tool"; done
ask='{"session_id":"s","tool_name":"AskUserQuestion","tool_input":{}}'
decoy='{"session_id":"s","tool_name":"Bash","tool_input":{"command":"echo \"tool_name\":\"AskUserQuestion\""}}'
if command -v jq >/dev/null; then
  hook_with_path "$PATH" tool "$ask"
  expect "with jq: a question marks the pane waiting" '^waiting$' state_of
fi
hook_with_path "$WORK/nojq" working '{}'
hook_with_path "$WORK/nojq" tool "$ask"
expect "without jq: a question marks the pane waiting" '^waiting$' state_of
hook_with_path "$WORK/nojq" tool "$decoy"
expect "without jq: a tool_name string inside the input isn't a question" '^working$' state_of
hook_with_path "$WORK/nojq" tool '{"session_id": "s", "tool_name": "ExitPlanMode", "tool_input": {}}'
expect "without jq: spaced JSON works too" '^waiting$' state_of

section "Several grids"
# A second "terminal": tmux won't attach without a TERM, which CI runners don't set.
(sleep 60 | TERM=xterm-256color pty tmux -L claude-grid-main attach -t claude >/dev/null 2>&1 &)
check "a client attaches to main" wait_for sh -c "[ \"\$(tmux -L claude-grid-main display -p -t claude '#{session_attached}')\" != 0 ]"
(cd "$WORK/proj/a" && cg >/dev/null 2>&1)
check "a second terminal gets grid 2 while main is attached" tg 2 has-session -t claude
(cd "$WORK/proj/a" && cg >/dev/null 2>&1)
check "a detached grid is reused instead of starting grid 3" sh -c "! tmux -L claude-grid-3 has-session -t claude 2>/dev/null"
expect "kill outside a grid refuses when several run" 'several grids are running \(main 2\)' cg kill
expect "kill NAME ends that grid" 'stopped grid 2' cg kill 2
check "the other grid keeps running" tg main has-session -t claude
(cd "$WORK/proj" && cg --grid work b >/dev/null 2>&1)
check "--grid opens a named grid" tg work has-session -t claude
expect "kill from inside a grid ends only that grid" 'stopped grid work' env TMUX="$SOCKET_DIR/claude-grid-work,1,0" "$BASH_BIN" "$REPO/bin/claude-grid" kill
check "main still runs" tg main has-session -t claude
expect "starting inside another tmux is refused" 'inside another tmux session' env TMUX="/tmp/elsewhere/default,1,0" "$BASH_BIN" "$REPO/bin/claude-grid"

section "In-grid commands"
tg main run-shell -t "$pane" "#{q:@cg_bin} --grid #{q:@cg_grid} #{q:pane_current_path}"
expect "c adds a pane to the same grid" '^4$' sh -c "tmux -L claude-grid-main list-panes -s -t claude | wc -l | tr -d ' '"
check "r reloads the grid config" tg main source-file -F "#{@cg_state}/grid.conf"

section "Launchers"
write_config "launcher=*/launched|$WORK/bin/launcher"
(cd "$WORK/proj" && cg --model opus launched >/dev/null 2>&1)
wait_for sh -c "ls '$WORK'/launcher.* >/dev/null 2>&1"
expect "a matching folder starts through its launcher with the hook flags" "^--settings $STATE/claude-hooks.json --model opus$" sh -c "cat '$WORK'/launcher.*"
write_config

section "Settings file"
write_config "THEME=nord" 'COLOR_ACTIVE="#123456"' "  FADE = 40  " "# a comment"
expect "a theme sets the colors" '#EBCB8B' cg colors
expect "a COLOR_ line overrides the theme" '#123456' cg colors
for bad in "FADE=95|FADE must be 0-90" "THEME=nope|THEME must be one of" "BOGUS=1|unknown setting BOGUS" \
  "launcher=nopipe|launcher must look like" "just words|expected KEY=value" "COLOR_TEXT=red|COLOR_TEXT must look like #RRGGBB"; do
  write_config "${bad%%|*}"
  expect "rejects ${bad%%|*}" "config:2: ${bad#*|}" cg colors
done
mkdir -p "$XDG_CONFIG_HOME/claude-grid/themes"
printf 'COLOR_WAITING=#ff0000\n' >"$XDG_CONFIG_HOME/claude-grid/themes/mine.theme"
write_config "THEME=mine"
expect "a user theme works" '#ff0000' cg colors
expect "themes lists bundled and user themes" 'tokyo-night' cg themes
write_config

section "Settings menu"
on_tty '8\ngruvbox\n6\n40\n4\n500\n70\n1\nC-Spce\nC-a\n15\na\n*/proj\nmise run claude\n\ns\n' "$BASH_BIN" "$REPO/bin/claude-grid" config >"$WORK/menu.out" 2>&1
menu="$(strip <"$WORK/menu.out")"
expect "rejects an out-of-range value" 'FLOAT_WIDTH must be 1-100' printf '%s' "$menu"
expect "rejects a key tmux doesn't know" "doesn't know the key C-Spce" printf '%s' "$menu"
expect "saves only changed values" '^FLOAT_WIDTH=70$' cat "$CONFIG"
expect "saves the theme" '^THEME=gruvbox$' cat "$CONFIG"
expect "saves the prefix" '^PREFIX=C-a$' cat "$CONFIG"
expect "saves the launcher" '^launcher=\*/proj\|mise run claude$' cat "$CONFIG"
expect "running grids pick up the new settings" 'bg=#282828' tg main show -gv status-style
check "the saved file loads again" cg colors
on_tty '10\n#112233\n8\nnord\ns\n' "$BASH_BIN" "$REPO/bin/claude-grid" config >"$WORK/menu.out" 2>&1
expect "switching themes keeps a color override" 'kept your color overrides: COLOR_ACTIVE' sh -c "perl -pe 's/\e\[[0-9;]*[A-Za-z]//g' '$WORK/menu.out'"
expect "the override is saved" '^COLOR_ACTIVE=#112233$' cat "$CONFIG"
write_config

section "Install"
prefix="$WORK/prefix"
expect "installs a link" "$prefix/bin/claude-grid → $REPO/bin/claude-grid" "$BASH_BIN" "$REPO/install.sh" --prefix "$prefix" -y --no-alias
expect "the installed command runs" '^claude-grid [0-9]' "$prefix/bin/claude-grid" --version
expect "installs a free alias" 'alias cgtest → claude-grid' "$BASH_BIN" "$REPO/install.sh" --prefix "$prefix" -y --alias cgtest
expect "the alias runs" '^claude-grid [0-9]' "$prefix/bin/cgtest" --version
expect "skips an alias that's taken" 'already uses the name sh' "$BASH_BIN" "$REPO/install.sh" --prefix "$prefix" -y --alias sh
expect "copy mode copies the support files" "$prefix/libexec/claude-grid" "$BASH_BIN" "$REPO/install.sh" --copy --prefix "$prefix" -y --no-alias
expect "the copy finds its own support files" "support files \(.*/prefix/libexec/claude-grid\)" "$prefix/bin/claude-grid" doctor
expect "back to link mode removes the copy" 'removed the old copied files' "$BASH_BIN" "$REPO/install.sh" --prefix "$prefix" -y --no-alias
expect "uninstall removes the alias" "removed alias $prefix/bin/cgtest" "$BASH_BIN" "$REPO/install.sh" --uninstall --prefix "$prefix"
check "uninstall removes the command" test ! -e "$prefix/bin/claude-grid"
check "uninstall keeps the settings" test -f "$CONFIG"
printf '#!/bin/sh\n' >"$prefix/bin/claude-grid"
expect "won't replace a claude-grid it didn't install" "isn't claude-grid" "$BASH_BIN" "$REPO/install.sh" --prefix "$prefix" -y

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
