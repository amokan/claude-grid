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
# Records each argument in brackets, so "a b" and "a" "b" look different.
cat >"$WORK/bin/claude" <<'EOF'
#!/bin/sh
printf '[%s]' "$@" >"$CG_TEST_DIR/args.$$"
echo "${CLAUDE_GRID:-unset}" >"$CG_TEST_DIR/grid.$$"
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
# bash 3.2 reads the bytes of a character like · or ─ as part of a variable name: write ${name}·.
check "no \$name directly followed by a non-ASCII character" sh -c \
  "! perl -ne 'print \"\$ARGV:\$.: \$_\" if /\\\$[A-Za-z_][A-Za-z0-9_]*[^\\x00-\\x7F]/; close ARGV if eof' '$REPO'/bin/claude-grid '$REPO'/install.sh '$REPO'/libexec/claude-grid/*.sh | grep ."
expect "--version" '^claude-grid [0-9]' cg --version
expect "-h lists the commands" 'claude-grid kill --all' cg -h
expect "unknown options are refused" 'unknown option: --bogus' cg --bogus

section "Starting a grid"
(cd "$WORK/proj" && cg a b:2 >/dev/null 2>&1)
check "grid main is running" tg main has-session -t claude
expect "three panes in two folders" '^3$' sh -c "tmux -L claude-grid-main list-panes -s -t claude | wc -l | tr -d ' '"
expect "panes are named after their folders" 'a b b' sh -c "tmux -L claude-grid-main list-panes -s -t claude -F '#{@claude_name}' | tr '\n' ' '"
wait_for sh -c "ls '$WORK'/args.* >/dev/null 2>&1"
expect "each Claude gets the generated hooks file" "\\[--settings\\]\\[$STATE/claude-hooks.json\\]" sh -c "cat '$WORK'/args.*"
if command -v jq >/dev/null; then
  # jq may be a version-manager shim that needs the real XDG folders.
  check "the hooks file is valid JSON" env -u XDG_CONFIG_HOME -u XDG_STATE_HOME jq -e '.hooks.PreToolUse[0].hooks[0].command | test("state.sh. tool$")' "$STATE/claude-hooks.json"
fi
expect "the grid knows its name" '^main$' tg main show -gqv @cg_grid
expect "the prefix is applied" '^C-Space$' tg main show -gqv prefix
expect "ls shows the grid and its panes" 'grid main \(detached\)' cg ls

expect "claude knows which grid it runs in" '^main$' sh -c "cat '$WORK'/grid.* | sort -u"

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

section "Claude flags after --"
rm -f "$WORK"/args.*
(cd "$WORK/proj" && cg --grid flags a --model opus -- --effort high --add-dir "/x y" --allowedTools 'Bash(git:*)' >/dev/null 2>&1)
wait_for sh -c "ls '$WORK'/args.* >/dev/null 2>&1"
expect "flags after -- reach claude intact, after the hooks and --model" \
  "\\[--model\\]\\[opus\\]\\[--effort\\]\\[high\\]\\[--add-dir\\]\\[/x y\\]\\[--allowedTools\\]\\[Bash\\(git:\\*\\)\\]$" sh -c "cat '$WORK'/args.*"
tg flags kill-server
for flag in --bare --safe-mode --settings=x.json -p --tmux --bg --cloud --desktop --teleport --help; do
  expect "refuses $flag" "can't pass $flag to claude in a grid" cg --grid refused "$WORK/proj/a" -- "$flag"
done
expect "explains why --settings is refused" "replaces claude-grid's hooks" cg --grid refused "$WORK/proj/a" -- --settings x.json
check "a refused flag starts no grid" sh -c "! tmux -L claude-grid-refused has-session 2>/dev/null"

section "--worktree"
for form in "--worktree feat" "-w feat" "--worktree=feat"; do
  # shellcheck disable=SC2086 # split the form into its words on purpose
  expect "refuses a named worktree for several panes: $form" 'would put all 2 new panes in the same worktree' \
    cg --grid wt "$WORK/proj/a:2" -- $form
done
expect "-w followed by a flag has no name, and needs a git repository" "needs a git repository, and $WORK/proj/a isn't one" \
  cg --grid wt "$WORK/proj/a:2" -- -w --effort high
check "a refused worktree run starts no grid" sh -c "! tmux -L claude-grid-wt has-session 2>/dev/null"
git init -q "$WORK/repo"
rm -f "$WORK"/args.*
(cd "$WORK" && cg --grid wt repo:2 -- --worktree >/dev/null 2>&1)
check "an unnamed worktree starts every pane in a git repository" tg wt has-session -t claude
wait_for sh -c "[ \$(ls '$WORK'/args.* 2>/dev/null | wc -l) -eq 2 ]"
expect "each pane gets --worktree" '^2$' sh -c "grep -l '\\[--worktree\\]$' '$WORK'/args.* | wc -l | tr -d ' '"
(cd "$WORK" && cg --grid wt repo -- -w solo >/dev/null 2>&1)
expect "a named worktree is fine for one new pane" '^3$' sh -c "tmux -L claude-grid-wt list-panes -s -t claude | wc -l | tr -d ' '"
tg wt kill-server

section "--minimal-status"
rm -f "$WORK"/args.*
(cd "$WORK/proj" && cg --grid mini a --minimal-status >/dev/null 2>&1)
wait_for sh -c "ls '$WORK'/args.* >/dev/null 2>&1"
expect "panes get the settings file with the statusLine" "\\[--settings\\]\\[$STATE/claude-minimal-status.json\\]" sh -c "cat '$WORK'/args.*"
if command -v jq >/dev/null; then
  jqx() { env -u XDG_CONFIG_HOME -u XDG_STATE_HOME jq "$@"; }
  expect "it uses the bundled one-liner in the theme's accent color" "statusline.sh' '#56B4E9'$" jqx -r .statusLine.command "$STATE/claude-minimal-status.json"
  check "it keeps the same hooks" sh -c "[ \"\$(env -u XDG_CONFIG_HOME -u XDG_STATE_HOME jq -c .hooks '$STATE/claude-minimal-status.json')\" = \"\$(env -u XDG_CONFIG_HOME -u XDG_STATE_HOME jq -c .hooks '$STATE/claude-hooks.json')\" ]"
  check "the plain hooks file has no statusLine" sh -c "env -u XDG_CONFIG_HOME -u XDG_STATE_HOME jq -e 'has(\"statusLine\") | not' '$STATE/claude-hooks.json'"
  write_config 'MINIMAL_STATUS_COMMAND=~/.claude/my "compact" line.sh'
  (cd "$WORK/proj" && cg --grid mini a --minimal-status >/dev/null 2>&1)
  expect "MINIMAL_STATUS_COMMAND replaces the one-liner" '^~/.claude/my "compact" line.sh$' jqx -r .statusLine.command "$STATE/claude-minimal-status.json"
  write_config
fi
tg mini kill-server
write_config "MINIMAL_STATUS=true"
rm -f "$WORK"/args.*
(cd "$WORK/proj" && cg --grid mini a >/dev/null 2>&1)
wait_for sh -c "ls '$WORK'/args.* >/dev/null 2>&1"
expect "MINIMAL_STATUS=true gives every new pane the minimal statusLine" "\\[$STATE/claude-minimal-status.json\\]" sh -c "cat '$WORK'/args.*"
rm -f "$WORK"/args.*
(cd "$WORK/proj" && cg --grid mini a --no-minimal-status >/dev/null 2>&1)
wait_for sh -c "ls '$WORK'/args.* >/dev/null 2>&1"
expect "--no-minimal-status keeps your own statusLine for one run" "\\[$STATE/claude-hooks.json\\]" sh -c "cat '$WORK'/args.*"
tg mini kill-server
write_config "MINIMAL_STATUS=yes"
expect "MINIMAL_STATUS must be true or false" 'MINIMAL_STATUS must be true or false' cg colors
write_config
statusline() { printf '%s' "$2" | env -i PATH="$1" "$BASH_BIN" "$REPO/libexec/claude-grid/statusline.sh" | strip; }
session='{"workspace":{"project_dir":"/r/api","current_dir":"/tmp"},"model":{"display_name":"Opus 5.5"},"effort":{"level":"high"},"context_window":{"used_percentage":41.6},"cost":{"total_cost_usd":1.2345}}'
in_worktree='{"workspace":{"project_dir":"/r/api","current_dir":"/tmp"},"worktree":{"name":"bright-fox","branch":"worktree-bright-fox"},"model":{"display_name":"Sonnet 5.5"}}'
if command -v jq >/dev/null; then
  # shellcheck disable=SC2016 # the $ is a literal dollar sign in the pattern
  expect "the one-liner shows folder, model, effort, context and cost" '^api · Opus 5.5 high · 42% context · \$1\.23$' statusline "$PATH" "$session"
  expect "in a worktree it shows the worktree and its branch" '^api \[bright-fox\] · worktree-bright-fox · Sonnet 5.5$' statusline "$PATH" "$in_worktree"
fi
mkdir -p "$WORK/nojq-git"
for tool in git cat; do ln -s "$(command -v "$tool")" "$WORK/nojq-git/$tool"; done
expect "without jq it shows the folder and branch" '^repo · (main|master)$' sh -c "cd '$WORK/repo' && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init && printf '{}' | env -i PATH='$WORK/nojq-git' '$BASH_BIN' '$REPO/libexec/claude-grid/statusline.sh' | perl -pe 's/\\e\\[[0-9;]*m//g'"

section "Launchers"
write_config "launcher=*/launched|$WORK/bin/launcher"
(cd "$WORK/proj" && cg --model opus launched -- --effort high 'Bash(git:*)' >/dev/null 2>&1)
wait_for sh -c "ls '$WORK'/launcher.* >/dev/null 2>&1"
expect "a matching folder starts through its launcher with every flag, unescaped" \
  "^--settings $STATE/claude-hooks.json --model opus --effort high Bash\\(git:\\*\\)$" sh -c "cat '$WORK'/launcher.*"
rm -f "$WORK"/launcher.*
(cd "$WORK/proj" && cg --grid mini launched --minimal-status >/dev/null 2>&1)
wait_for sh -c "ls '$WORK'/launcher.* >/dev/null 2>&1"
expect "launchers get the --minimal-status settings too" "^--settings $STATE/claude-minimal-status.json$" sh -c "cat '$WORK'/launcher.*"
tg mini kill-server
expect "a value with a space is refused for launcher panes" 'launcher, which can.t receive "be terse"' \
  cg --grid spaced "$WORK/proj/launched" -- --append-system-prompt "be terse"
check "and no grid starts" sh -c "! tmux -L claude-grid-spaced has-session 2>/dev/null"
expect "the check covers the default folder of a new grid too" 'launcher, which can.t receive "be terse"' \
  sh -c "cd '$WORK/proj/launched' && '$BASH_BIN' '$REPO/bin/claude-grid' --grid spaced -- --append-system-prompt 'be terse'"
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
# Menu numbers follow SETTING_KEYS; LAUNCHERS comes after the last setting.
on_tty '8\ngruvbox\n6\n40\n4\n500\n70\n1\nC-Spce\nC-a\n17\na\n*/proj\nmise run claude\n\ns\n' "$BASH_BIN" "$REPO/bin/claude-grid" config >"$WORK/menu.out" 2>&1
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
expect "installs a link" "$prefix/bin/claude-grid → $REPO/bin/claude-grid" "$BASH_BIN" "$REPO/install.sh" --prefix "$prefix" -y
expect "the installed command runs" '^claude-grid [0-9]' "$prefix/bin/claude-grid" --version
expect "installs a free alias" 'alias cgtest → claude-grid' "$BASH_BIN" "$REPO/install.sh" --prefix "$prefix" -y --alias cgtest
expect "the alias runs" '^claude-grid [0-9]' "$prefix/bin/cgtest" --version
expect "skips an alias that's taken" 'already uses the name sh' "$BASH_BIN" "$REPO/install.sh" --prefix "$prefix" -y --alias sh
expect "copy mode copies the support files" "$prefix/libexec/claude-grid" "$BASH_BIN" "$REPO/install.sh" --copy --prefix "$prefix" -y
expect "the copy finds its own support files" "support files \(.*/prefix/libexec/claude-grid\)" "$prefix/bin/claude-grid" doctor
expect "back to link mode removes the copy" 'removed the old copied files' "$BASH_BIN" "$REPO/install.sh" --prefix "$prefix" -y
expect "uninstall removes the alias" "removed alias $prefix/bin/cgtest" "$BASH_BIN" "$REPO/install.sh" --uninstall --prefix "$prefix"
check "uninstall removes the command" test ! -e "$prefix/bin/claude-grid"
check "uninstall keeps the settings" test -f "$CONFIG"
printf '#!/bin/sh\n' >"$prefix/bin/claude-grid"
expect "won't replace a claude-grid it didn't install" "isn't claude-grid" "$BASH_BIN" "$REPO/install.sh" --prefix "$prefix" -y

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
