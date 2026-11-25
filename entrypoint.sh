#!/usr/bin/env bash
set -euo pipefail

# The firewall needs root, so run it via a scoped sudo (the container runs as the node user).
# It can only be disabled when SKIP_FIREWALL=1 (= egress becomes unrestricted, so warn explicitly).
#
# Its progress log goes to a file rather than the terminal. Host apps that wrap the
# terminal (orca, for one) name the conversation after the first line they see, and that
# line used to be "[firewall] generating allowlist..." in every box. The firewall still
# fails closed: a failed self-check prints the whole log and stops the box. WARN lines
# from a run that succeeded are still shown, because they mean something is off. The
# warning for a *disabled* firewall stays on the terminal unconditionally.
# CLAUDE_BOX_VERBOSE=1 brings the full log back on the terminal.
FIREWALL_LOG=/tmp/claude-box/firewall.log
if [ "${SKIP_FIREWALL:-0}" = "1" ]; then
  echo "[entrypoint] WARNING: firewall disabled (SKIP_FIREWALL=1) — outbound traffic is unrestricted"
elif [ "${CLAUDE_BOX_VERBOSE:-0}" = "1" ]; then
  sudo /usr/local/bin/init-firewall.sh
else
  mkdir -p "$(dirname "$FIREWALL_LOG")"
  if ! sudo /usr/local/bin/init-firewall.sh > "$FIREWALL_LOG" 2>&1; then
    cat "$FIREWALL_LOG" >&2
    echo "[entrypoint] ERROR: firewall setup failed — not starting (log: $FIREWALL_LOG)" >&2
    exit 1
  fi
  grep -F 'WARN' "$FIREWALL_LOG" >&2 || true
fi

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-/home/node/.claude}"

# The global CLAUDE.md, in `ro` mode (the default): claude-box mounts the host's
# ~/.claude/CLAUDE.md (or the file named by CLAUDE_BOX_GLOBAL_MD) read-only at the
# path below -- in `rw` mode it is mounted over the box's copy instead and none of
# this runs, because there is nothing to copy. Here we *replace* the
# box's copy with it on every launch. Replace, not append: the box's instructions are
# then exactly what the host file says today, so deleting a line on the host deletes
# it here too -- stale instructions that quietly keep steering Claude are worse than
# a lost in-box edit. The flip side, in return: anything written to the box's
# CLAUDE.md from inside is gone on the next launch (design 09; this supersedes the
# line-by-line append of design 03).
# Copied via cat rather than cp so the box's copy stays writable (the source is a
# read-only mount) and via a temp file so a failed write cannot truncate it.
GLOBAL_MD_SRC="/etc/claude-box/global-CLAUDE.md"
if [ -f "$GLOBAL_MD_SRC" ]; then
  CLAUDE_MD="$CONFIG_DIR/CLAUDE.md"
  cat "$GLOBAL_MD_SRC" > "$CLAUDE_MD.tmp" && mv "$CLAUDE_MD.tmp" "$CLAUDE_MD"
fi

# Bring in the host's global settings (settings.json / settings.local.json) in `ro`
# mode: claude-box mounts them read-only at the paths below (in `rw` mode they are
# mounted over the box's own copies instead, and none of this runs).
# Merge rather than replace: jq's `*` merges objects recursively, so host keys win
# while keys only the box has -- theme / effortLevel and the like, which claude
# itself writes into the box's settings.json -- survive. This runs on every launch,
# so editing the file on the host takes effect on the next start; a key *deleted* on
# the host stays behind in the box (removal is not propagated). Arrays (e.g.
# permissions.allow) are taken from the host wholesale, not concatenated.
# The box's copy is a real file in its own volume, so claude can keep writing to it;
# the host's file is only ever read (design 08).
merge_host_settings() {
  local src="$1" dst="$2"
  [ -f "$src" ] || return 0
  # Skip -- with a warning -- rather than break startup on a malformed host file.
  if ! jq -e 'type == "object"' "$src" >/dev/null 2>&1; then
    echo "[entrypoint] WARNING: $src is not a JSON object — not importing it"
    return 0
  fi
  if [ -s "$dst" ] && jq -e 'type == "object"' "$dst" >/dev/null 2>&1; then
    jq -s '.[0] * .[1]' "$dst" "$src" > "$dst.tmp" && mv "$dst.tmp" "$dst"
  else
    jq . "$src" > "$dst.tmp" && mv "$dst.tmp" "$dst"
  fi
}
merge_host_settings /etc/claude-box/host-settings.json       "$CONFIG_DIR/settings.json"
merge_host_settings /etc/claude-box/host-settings.local.json "$CONFIG_DIR/settings.local.json"

# Set the notification channel to the terminal bell (BEL). The escape sequence passes
# straight through the PTY, so it is the only path by which a terminal outside the
# container (cmux, etc.) can detect the waiting state.
# It is written "only when the key is absent", so a manual switch to another channel is not overwritten.
CLAUDE_JSON="$CONFIG_DIR/.claude.json"
if [ -s "$CLAUDE_JSON" ]; then
  if ! jq -e 'has("preferredNotifChannel")' "$CLAUDE_JSON" >/dev/null; then
    jq '.preferredNotifChannel = "terminal_bell"' "$CLAUDE_JSON" > "$CLAUDE_JSON.tmp" \
      && mv "$CLAUDE_JSON.tmp" "$CLAUDE_JSON"
  fi
else
  printf '{"preferredNotifChannel":"terminal_bell"}\n' > "$CLAUDE_JSON"
fi

# Tell the in-box claude how the host's config was imported (design 11). The import is
# read-only by default, and the two halves of "read-only" fail differently: writing into
# skills/ or agents/ fails outright (EROFS), while a settings.json or CLAUDE.md edit
# *succeeds* against the box's own copy and simply never reaches the host. The second
# kind is the dangerous one -- nothing surfaces, and the user finds out later that their
# change is not on their machine -- so rather than relying on claude noticing an error,
# state the modes up front and say what to do about them.
#
# This lives in claude's system prompt, not in ~/.claude/CLAUDE.md: in rw mode that file
# *is* the host's file, and writing the box's own notes into it would put box text on the
# user's machine -- exactly what the read-only default exists to prevent.
CLAUDE_BOX_NOTES=""
if [ -n "${CLAUDE_BOX_MODES:-}" ] && claude --help 2>/dev/null | grep -q -- '--append-system-prompt'; then
  CLAUDE_BOX_NOTES=/tmp/claude-box/box-notes.md
  mkdir -p "$(dirname "$CLAUDE_BOX_NOTES")"
  {
    echo "# claude-box"
    echo
    echo "You are running inside claude-box: a container with default-deny egress that"
    echo "mounts only the current project. The host's Claude Code config was imported"
    echo "with these modes:"
    echo
    for mode in ${CLAUDE_BOX_MODES}; do echo "- ${mode}"; done
    echo
    echo "\`ro\` means the item is here but the host's copy is never written: a write into"
    echo "\`~/.claude/skills\`, \`agents\` or \`commands\` fails with EROFS, while an edit to"
    echo "\`~/.claude/settings.json\` or \`~/.claude/CLAUDE.md\` succeeds against this"
    echo "container's own copy and is silently lost when the container is recreated."
    echo
    echo "So, when a change to \`~/.claude\` is meant to last beyond this container:"
    echo
    echo "- Do not work around a read-only mount, and do not report the change as done."
    echo "- Tell the user which variable would allow it and let them decide, e.g."
    echo "  \`CLAUDE_BOX_SKILLS=rw claude-box\` for one item, or"
    echo "  \`CLAUDE_BOX_HOST_CONFIG=rw claude-box\` for all of them. The setting takes"
    echo "  effect on the next launch, so say so before doing the work."
    echo "- A skill, subagent or command only this project needs is better placed in"
    echo "  \`.claude/\` inside the project, which is writable and versioned with the code."
    echo
    echo "\`CLAUDE_BOX_SESSIONS\` is separate from the config import (\`CLAUDE_BOX_HOST_CONFIG\`"
    echo "does not change it) and covers this project's \`~/.claude/projects/<key>/\`: the"
    echo "session transcripts and auto-memory. \`off\` keeps them in this container's"
    echo "volume, where host tools cannot see them; \`CLAUDE_BOX_SESSIONS=rw claude-box\`"
    echo "shares them. When it is \`rw\`, that directory *is* the host's: the host's Claude"
    echo "loads that memory and can resume those transcripts, and you may see the host's"
    echo "own sessions for this project. Write memory there only as you would on the host."
    echo
    echo "The egress firewall's startup log (allow-list, self-check results) is in"
    echo "\`/tmp/claude-box/firewall.log\`; read it first when a host cannot be reached."
  } > "$CLAUDE_BOX_NOTES"
fi
export CLAUDE_BOX_NOTES

# Prepare the --plugin-dir for loading the box's built-in plugin (the env-request skill).
# env-request is off by default. The feature is meaningless without a request outbox,
# so it is loaded only when one is mounted (CLAUDE_BOX_REQUEST_DIR); if unset, --plugin-dir is not
# passed and the skill is not shown. In addition, claude is auto-updated while running, so
# the flag is attached only when the currently installed version can interpret --plugin-dir
# (avoiding attaching the flag on an unsupported version and breaking every launch. Even on
# an unsupported version, filing itself is still possible via the claude-box-request command).
# The interactive shell's bashrc-claude wrapper also reads this environment variable, so
# always compute and export it.
CLAUDE_BOX_PLUGIN_DIR=""
if [ -n "${CLAUDE_BOX_REQUEST_DIR:-}" ] \
   && [ -d /opt/claude-box/plugins/box-core ] \
   && claude --help 2>/dev/null | grep -q -- '--plugin-dir'; then
  CLAUDE_BOX_PLUGIN_DIR=/opt/claude-box/plugins/box-core
fi
export CLAUDE_BOX_PLUGIN_DIR

# When launched directly as `claude-box claude ...` it does not go through an interactive
# shell, so the bashrc wrapper has no effect. Inject the box's built-in plugin / notification
# hooks here too, by the same criteria as bashrc-claude (management subcommands pass through).
if [ "${1:-}" = "claude" ]; then
  case "${2:-}" in
    login|logout|update|mcp|config|doctor|setup-token|--version|-v|--help|-h) ;;
    *)
      shift  # drop the leading "claude"
      inject=()
      [ -n "$CLAUDE_BOX_PLUGIN_DIR" ] && inject+=(--plugin-dir "$CLAUDE_BOX_PLUGIN_DIR")
      [ -n "$CLAUDE_BOX_NOTES" ] && inject+=(--append-system-prompt "$(cat "$CLAUDE_BOX_NOTES")")
      [ -n "${CLAUDE_BOX_BRIDGE_PORT:-}" ] && inject+=(--settings /etc/claude-box/notify-hooks.json)
      set -- claude "${inject[@]}" "$@"
      ;;
  esac
fi

# claude runs as node (non-root), so it does not trip the root-time
# --dangerously-skip-permissions guard. The previous IS_SANDBOX=1 is no longer needed and
# has been removed.
exec "$@"

