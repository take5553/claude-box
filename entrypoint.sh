#!/usr/bin/env bash
set -euo pipefail

# The firewall needs root, so run it via a scoped sudo (the container runs as the node user).
# It can only be disabled when SKIP_FIREWALL=1 (= egress becomes unrestricted, so warn explicitly).
if [ "${SKIP_FIREWALL:-0}" = "1" ]; then
  echo "[entrypoint] WARNING: firewall disabled (SKIP_FIREWALL=1) — outbound traffic is unrestricted"
else
  sudo /usr/local/bin/init-firewall.sh
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
      [ -n "${CLAUDE_BOX_BRIDGE_PORT:-}" ] && inject+=(--settings /etc/claude-box/notify-hooks.json)
      set -- claude "${inject[@]}" "$@"
      ;;
  esac
fi

# claude runs as node (non-root), so it does not trip the root-time
# --dangerously-skip-permissions guard. The previous IS_SANDBOX=1 is no longer needed and
# has been removed.
exec "$@"

