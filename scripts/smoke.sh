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
  echo "[1/6] build image ($IMAGE)"
  # shellcheck disable=SC2086  # BUILD_ARGS is intentionally word-split
  "$ENGINE" build $BUILD_ARGS -t "$IMAGE" .
fi

echo "[2/6] init-firewall startup self-check (allowed reachable, disallowed blocked)"
# The entrypoint runs init-firewall.sh, which exits non-zero if any self-check fails.
if "$ENGINE" run --rm "${FIREWALL_CAPS[@]}" "$IMAGE" true; then
  pass "startup firewall self-check passed"
else
  fail "startup firewall self-check failed"
fi

echo "[3/6] a disallowed host is blocked at runtime"
if "$ENGINE" run --rm "${FIREWALL_CAPS[@]}" "$IMAGE" \
     curl -fsS -m 10 https://example.com >/dev/null 2>&1; then
  fail "reached https://example.com (should be blocked)"
else
  pass "https://example.com blocked"
fi

echo "[4/6] runs non-root with no effective capabilities"
# The entrypoint prints firewall logs to stdout before exec-ing the command, so the
# value we want is the last line of the captured output.
who="$("$ENGINE" run --rm "${FIREWALL_CAPS[@]}" "$IMAGE" id -un | tail -n1)"
[ "$who" = "node" ] || fail "expected to run as 'node', got '$who'"
pass "runs as node"
capeff="$("$ENGINE" run --rm "${FIREWALL_CAPS[@]}" "$IMAGE" \
            sh -c 'awk "/^CapEff/ {print \$2}" /proc/self/status' | tail -n1)"
[ "$capeff" = "0000000000000000" ] || fail "expected empty CapEff, got '$capeff'"
pass "CapEff is empty (0000000000000000)"

echo "[5/6] nested container pull (optional)"
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

echo "[6/6] the host's global settings are imported (read-only) into the box's settings"
# claude-box mounts the host's settings.json read-only at the path below and the
# entrypoint merges it into the box's own settings (design 08). Check the merged
# result from inside, and that the host's file was not written to.
SETTINGS_TMP="$(mktemp -d)"
trap 'rm -rf "$SETTINGS_TMP"' EXIT
printf '{"model":"opus","permissions":{"allow":["Bash(ls)"]}}\n' > "$SETTINGS_TMP/settings.json"
merged="$("$ENGINE" run --rm "${FIREWALL_CAPS[@]}" \
            -v "$SETTINGS_TMP/settings.json:/etc/claude-box/host-settings.json:ro" \
            "$IMAGE" jq -c . /home/node/.claude/settings.json | tail -n1)"
case "$merged" in
  *'"model":"opus"'*) pass "host settings merged into the box's settings.json" ;;
  *) fail "expected the host's keys in the box's settings.json, got '$merged'" ;;
esac
[ "$(cat "$SETTINGS_TMP/settings.json")" = '{"model":"opus","permissions":{"allow":["Bash(ls)"]}}' ] \
  || fail "the host's settings.json was modified from inside the box"
pass "the host's settings.json is untouched"

echo "smoke: all checks passed"
