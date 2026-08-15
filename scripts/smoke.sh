#!/usr/bin/env bash
# scripts/smoke.sh — build the image and check the core sandbox invariants in one
# command. CI calls this too. Exits non-zero on the first failure.
#
#   ./scripts/smoke.sh                                   # build (no Chromium) + checks
#   BUILD_ARGS="--build-arg WITH_PODMAN=0" ./scripts/smoke.sh
#   IMAGE=claude-box:latest SKIP_BUILD=1 ./scripts/smoke.sh   # use an existing image
#   SMOKE_NESTED=1 ./scripts/smoke.sh                    # also test nested containers
set -euo pipefail

ENGINE="${CLAUDE_BOX_ENGINE:-docker}"
IMAGE="${IMAGE:-claude-box:smoke}"
# Skip the ~1GB Chromium by default; nginx/iptables (what the firewall needs) live
# in the base layers regardless.
BUILD_ARGS="${BUILD_ARGS:---build-arg WITH_PLAYWRIGHT=0}"

# The capabilities the firewall needs — the same set the launcher grants.
FIREWALL_CAPS=(
  --cap-drop=ALL
  --cap-add=NET_ADMIN --cap-add=NET_RAW
  --cap-add=SETUID --cap-add=SETGID --cap-add=AUDIT_WRITE
)

pass() { echo "  ok: $*"; }
fail() { echo "  FAIL: $*" >&2; exit 1; }

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo "[1/7] build image ($IMAGE)"
  # shellcheck disable=SC2086  # BUILD_ARGS is intentionally word-split
  "$ENGINE" build $BUILD_ARGS -t "$IMAGE" .
fi

echo "[2/7] init-firewall startup self-check (allowed reachable, disallowed blocked)"
# The entrypoint runs init-firewall.sh, which exits non-zero if any self-check fails.
if "$ENGINE" run --rm "${FIREWALL_CAPS[@]}" "$IMAGE" true; then
  pass "startup firewall self-check passed"
else
  fail "startup firewall self-check failed"
fi

echo "[3/7] a disallowed host is blocked at runtime"
if "$ENGINE" run --rm "${FIREWALL_CAPS[@]}" "$IMAGE" \
     curl -fsS -m 10 https://example.com >/dev/null 2>&1; then
  fail "reached https://example.com (should be blocked)"
else
  pass "https://example.com blocked"
fi

echo "[4/7] runs non-root with no effective capabilities"
# The entrypoint prints firewall logs to stdout before exec-ing the command, so the
# value we want is the last line of the captured output.
who="$("$ENGINE" run --rm "${FIREWALL_CAPS[@]}" "$IMAGE" id -un | tail -n1)"
[ "$who" = "node" ] || fail "expected to run as 'node', got '$who'"
pass "runs as node"
capeff="$("$ENGINE" run --rm "${FIREWALL_CAPS[@]}" "$IMAGE" \
            sh -c 'awk "/^CapEff/ {print \$2}" /proc/self/status' | tail -n1)"
[ "$capeff" = "0000000000000000" ] || fail "expected empty CapEff, got '$capeff'"
pass "CapEff is empty (0000000000000000)"

echo "[5/7] nested container pull (optional)"
if [ "${SMOKE_NESTED:-0}" = "1" ]; then
  if "$ENGINE" run --rm "${FIREWALL_CAPS[@]}" \
       --security-opt seccomp=unconfined --security-opt systempaths=unconfined \
       --device /dev/fuse --device /dev/net/tun \
       -e CLAUDE_BOX_NESTED_CONTAINERS=1 \
       "$IMAGE" docker pull alpine:3.20 >/dev/null 2>&1; then
    pass "nested docker pull works"
  else
    fail "nested docker pull failed"
  fi
else
  echo "  skipped (set SMOKE_NESTED=1 to run; needs the nested-container relaxations)"
fi

echo "[6/7] host config in ro mode (settings merged, CLAUDE.md replaced)"
# claude-box mounts the host's files read-only at the paths below; the entrypoint
# merges settings.json into the box's copy and replaces the box's CLAUDE.md with the
# host's (design 08 / 09). A throwaway volume stands in for claude-box-config, so the
# "replaces what was already there" half is actually exercised.
HOSTCFG_TMP="$(mktemp -d)"
SMOKE_VOLUME="claude-box-smoke-config"
cleanup_smoke() { rm -rf "$HOSTCFG_TMP"; "$ENGINE" volume rm -f "$SMOKE_VOLUME" >/dev/null 2>&1 || true; }
trap cleanup_smoke EXIT
printf '{"model":"opus","permissions":{"allow":["Bash(ls)"]}}\n' > "$HOSTCFG_TMP/settings.json"
printf 'imported from the host\n' > "$HOSTCFG_TMP/CLAUDE.md"

# Seed the volume with state the import has to overwrite.
"$ENGINE" run --rm "${FIREWALL_CAPS[@]}" -v "$SMOKE_VOLUME:/home/node/.claude" \
  "$IMAGE" sh -c 'echo stale-in-box-instruction > "$CLAUDE_CONFIG_DIR/CLAUDE.md"' >/dev/null

out="$("$ENGINE" run --rm "${FIREWALL_CAPS[@]}" -v "$SMOKE_VOLUME:/home/node/.claude" \
         -v "$HOSTCFG_TMP/settings.json:/etc/claude-box/host-settings.json:ro" \
         -v "$HOSTCFG_TMP/CLAUDE.md:/etc/claude-box/global-CLAUDE.md:ro" \
         "$IMAGE" sh -c 'jq -c . "$CLAUDE_CONFIG_DIR/settings.json"; cat "$CLAUDE_CONFIG_DIR/CLAUDE.md"')"
case "$out" in
  *'"model":"opus"'*) pass "host settings merged into the box's settings.json" ;;
  *) fail "expected the host's keys in the box's settings.json, got '$out'" ;;
esac
case "$out" in
  *stale-in-box-instruction*) fail "the box's old CLAUDE.md survived the import" ;;
  *"imported from the host"*) pass "host CLAUDE.md replaced the box's copy" ;;
  *) fail "expected the host's CLAUDE.md in the box, got '$out'" ;;
esac
[ "$(cat "$HOSTCFG_TMP/settings.json")" = '{"model":"opus","permissions":{"allow":["Bash(ls)"]}}' ] \
  && [ "$(cat "$HOSTCFG_TMP/CLAUDE.md")" = 'imported from the host' ] \
  || fail "a host file was modified from inside the box"
pass "the host's files are untouched"

echo "[7/7] host config in rw mode (the default): writes reach the host's file"
# In rw mode the host's settings.json is bind-mounted as a file over the box's copy.
# claude saves settings by writing a temp file and renaming it over the target, which
# a file bind mount refuses (EBUSY) -- it then falls back to an in-place write, and
# that is the path this checks: rename fails, in-place write lands on the host
# (design 10). If this step ever fails, rw settings are broken and ro is the fallback.
printf '{"model":"from-host"}\n' > "$HOSTCFG_TMP/rw-settings.json"
rw_out="$("$ENGINE" run --rm "${FIREWALL_CAPS[@]}" \
            -v "$HOSTCFG_TMP/rw-settings.json:/home/node/.claude/settings.json" \
            "$IMAGE" sh -c '
              printf "{\"model\":\"renamed\"}\n" > /tmp/new.json
              mv /tmp/new.json "$CLAUDE_CONFIG_DIR/settings.json" 2>/dev/null \
                && echo RENAME_OK || echo RENAME_REFUSED
              printf "{\"model\":\"from-box\"}\n" > "$CLAUDE_CONFIG_DIR/settings.json" \
                && echo INPLACE_OK || echo INPLACE_FAILED')"
case "$rw_out" in
  *RENAME_OK*) echo "  note: rename over the bind-mounted file succeeded on this engine" ;;
  *) pass "rename over the bind-mounted file is refused (the fallback's trigger)" ;;
esac
case "$rw_out" in
  *INPLACE_OK*) pass "in-place write from the box succeeded" ;;
  *) fail "in-place write from the box failed — rw settings would not save" ;;
esac
[ "$(cat "$HOSTCFG_TMP/rw-settings.json")" = '{"model":"from-box"}' ] \
  || fail "the box's write did not reach the host's file (got '$(cat "$HOSTCFG_TMP/rw-settings.json")')"
pass "the box's write reached the host's settings.json"

echo "smoke: all checks passed"
