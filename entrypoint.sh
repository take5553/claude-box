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

# Optional: append to the global CLAUDE.md (by default nothing is injected).
# Only when CLAUDE_BOX_GLOBAL_MD is set on the host is its content mounted read-only
# at the path below. It appends per line "only if absent", so it is restored even after
# recreating the volume and never duplicates across two launches (the idempotent-append
# mechanism itself is kept).
GLOBAL_MD_SRC="/etc/claude-box/global-CLAUDE.md"
if [ -f "$GLOBAL_MD_SRC" ]; then
  CLAUDE_MD="$CONFIG_DIR/CLAUDE.md"
  while IFS= read -r line; do
    grep -qxF "$line" "$CLAUDE_MD" 2>/dev/null || printf '%s\n' "$line" >> "$CLAUDE_MD"
  done < "$GLOBAL_MD_SRC"
fi

# Bring in the host's global settings (settings.json / settings.local.json), which
# claude-box mounts read-only at the paths below unless CLAUDE_BOX_NO_SETTINGS=1.
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

