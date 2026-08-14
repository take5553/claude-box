#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Default-deny egress filter (hostname-based / design 02).
#
# Two layers:
#   1) iptables (the unbreakable outer shell): force 80/443 into a local proxy
#      via transparent redirect, and DROP everything else outbound. Only the
#      proxy's dedicated uid can reach the outside directly. This does not rely
#      on the HTTP(S)_PROXY env vars at all, so the Claude inside the box cannot
#      bypass it by unsetting env.
#   2) nginx (the decision): match the hostname from the SNI / Host header
#      against the allowlist. The domains written in the allowlist and what is
#      actually blocked stay in agreement.
#
# Previously we dig'd the allowed domains at startup and pinned their IPs into
# an ipset, but:
#   - CDNs rotate their response IPs with a TTL of tens of seconds, so a pinned
#     IP later becomes unreachable (DNS drift)
#   - allowing a shared CDN's IP also lets you reach unrelated sites that ride
#     on that same IP
# On these two counts, the "allow written as a domain" and what was actually
# blocked diverged. See design 02.
#
# Run as root via sudo from the node user. Requires NET_ADMIN.
# ---------------------------------------------------------------------------
set -euo pipefail

PROXY_USER="egressd"
PROXY_CONF="/etc/claude-box/egress-proxy.conf"
RUN_DIR="/run/egress-proxy"
LOG_DIR="/var/log/egress-proxy"
LIB_DIR="/var/lib/egress-proxy"
TLS_PORT=3128
HTTP_PORT=3129

# The allowed domains are split into "core" and "optional":
#   - CORE     : without these Claude Code itself will not run. Always included
#                (cannot be removed = self-destruct prevention).
#   - OPTIONAL : per-use-case. Can be replaced wholesale via ALLOW_DOMAINS
#                (but CORE always remains).
# To add, use EXTRA_ALLOW_DOMAINS (appended to CORE + OPTIONAL); to fully
# replace, use ALLOW_DOMAINS. Input from any of these paths always passes
# through the downstream hostname validation (injection prevention into the
# nginx config).

# Core: Claude Code authentication (OAuth), API, and updates. The claude.ai /
# claude.com family and api.anthropic.com ride on the same Anthropic shared CDN.
# With hostname-based judgment they will not pass unless listed explicitly (the
# flip side of the loophole design 02 closed, namely "you could also reach
# unrelated sites riding on a shared CDN IP").
# First-party hosts intentionally left out: api-staging.anthropic.com /
# preview.claude.ai (for testing), *.mcp.claude.com / mcp-proxy.anthropic.com
# (Anthropic-hosted MCP connectors). Add when needed.
CORE_DOMAINS="
api.anthropic.com
console.anthropic.com
statsig.anthropic.com
claude.ai
claude.com
code.claude.com
platform.claude.com
downloads.claude.ai
"

# Optional (per-use-case). Destinations you do not use can be narrowed via
# ALLOW_DOMAINS (CORE remains).
#   github : gh / git operations. codeload is in none of the meta ranges, so
#            under the old IP scheme github would pass while codeload alone was
#            blocked (made explicit by hostname judgment, approved in request #1).
#   pkgs   : npm / PyPI package fetches.
#   nested : base image pull for in-container Podman, plus apt/apk
#            (CLAUDE_BOX_NESTED_CONTAINERS).
#   iac    : provider fetch for terraform init/validate (registry = meta/DL
#            resolution, releases = official distribution). validate only does
#            schema validation, connecting to neither AWS nor using creds. The
#            AWS API that plan/apply would need is intentionally not allowed =
#            this box goes as far as validating IaC, but does not apply it.
#   golang : the Go module proxy / checksum DB used when pre-commit's
#            language:golang hooks (gitleaks, etc.) are built via go install.
#            Go itself is baked in, so go.dev / dl.google.com are not needed.
OPTIONAL_DOMAINS="
github.com
api.github.com
codeload.github.com
uploads.github.com
objects.githubusercontent.com
raw.githubusercontent.com
registry.npmjs.org
pypi.org
files.pythonhosted.org
registry-1.docker.io
auth.docker.io
index.docker.io
production.cloudfront.docker.com
deb.debian.org
security.debian.org
archive.ubuntu.com
security.ubuntu.com
dl-cdn.alpinelinux.org
registry.terraform.io
releases.hashicorp.com
proxy.golang.org
sum.golang.org
"
# The optional part can be replaced wholesale via ALLOW_DOMAINS (CORE always
# remains). To add, use EXTRA_ALLOW_DOMAINS.
OPTIONAL_DOMAINS="${ALLOW_DOMAINS:-$OPTIONAL_DOMAINS}"
DOMAINS="$CORE_DOMAINS $OPTIONAL_DOMAINS ${EXTRA_ALLOW_DOMAINS:-}"

# The actual GitHub Actions logs/artifacts are stored on Azure Blob (the 302
# target from the API). The account names take the form
# productionresultssaNN.blob.core.windows.net, so instead of opening up all of
# *.blob.core.windows.net we allow only this pattern.
BLOB_REGEX='~^productionresultssa[0-9]+\.blob\.core\.windows\.net$'

echo "[firewall] generating allowlist..."
# The working directories are already provisioned on the image side as
# root:egressd 0775 (Dockerfile). This container is cap-drop=ALL, so even root
# lacks CHOWN / DAC_OVERRIDE and cannot recreate them or fix ownership here. If
# they are missing, do not proceed silently; fail.
for d in "$RUN_DIR" "$LOG_DIR" "$LIB_DIR"; do
  if [ ! -d "$d" ] || [ ! -w "$d" ]; then
    echo "[firewall] ERROR: $d is missing or not writable (image may be stale)" >&2
    exit 1
  fi
done

# Resolver for nginx to resolve upstream destinations. iptables is v4-only, so
# ipv6=off.
nameservers="$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | grep -v ':' | head -n3 | tr '\n' ' ')"
if [ -z "$nameservers" ]; then
  echo "[firewall] ERROR: no IPv4 nameserver in /etc/resolv.conf" >&2
  exit 1
fi
printf 'resolver %s valid=30s ipv6=off;\nresolver_timeout 5s;\n' "$nameservers" > "$RUN_DIR/resolver.conf"

# Generate the nginx map from the allowlist. Since arbitrary strings can come in
# via ALLOW_DOMAINS / EXTRA_ALLOW_DOMAINS, only let through those that are valid
# as hostnames (injection prevention into the nginx config). Even if CORE and
# EXTRA etc. overlap, an nginx map does not permit duplicate keys, so dedupe.
: > "$RUN_DIR/allow-tls.map"
: > "$RUN_DIR/allow-http.map"
allow_count=0
declare -A seen_domains=()
for domain in $DOMAINS; do
  if ! [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
    echo "[firewall] WARN: ignoring invalid domain specification: $domain" >&2
    continue
  fi
  [ -n "${seen_domains[$domain]:-}" ] && continue
  seen_domains[$domain]=1
  printf '%s %s:443;\n' "$domain" "$domain" >> "$RUN_DIR/allow-tls.map"
  printf '%s 1;\n'      "$domain"           >> "$RUN_DIR/allow-http.map"
  allow_count=$((allow_count + 1))
done
printf '%s $ssl_preread_server_name:443;\n' "$BLOB_REGEX" >> "$RUN_DIR/allow-tls.map"
echo "[firewall] allowed hosts: ${allow_count} (+ blob pattern for Actions logs)"

echo "[firewall] starting egress proxy..."
# If it is already running, stop it before swapping in the new one (this allows
# re-running this script)
if [ -f "$RUN_DIR/nginx.pid" ] && kill -0 "$(cat "$RUN_DIR/nginx.pid")" 2>/dev/null; then
  kill -QUIT "$(cat "$RUN_DIR/nginx.pid")" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$(cat "$RUN_DIR/nginx.pid" 2>/dev/null || echo 0)" 2>/dev/null || break
    sleep 0.1
  done
fi
# Run the proxy under a dedicated uid. If it were the same as node (= the uid
# claude runs as), the downstream --uid-owner exclusion would also apply to
# claude, letting everything through.
nginx_start=(runuser -u "$PROXY_USER" -- nginx
             -p "$LIB_DIR" -c "$PROXY_CONF" -e "$LOG_DIR/error.log")
if ! nginx_test="$("${nginx_start[@]}" -t 2>&1)"; then
  echo "$nginx_test" >&2
  echo "[firewall] ERROR: egress proxy configuration is invalid. Aborting" >&2
  exit 1
fi
"${nginx_start[@]}"

PROXY_UID="$(id -u "$PROXY_USER")"

echo "[firewall] resetting..."
iptables -F
iptables -X 2>/dev/null || true
iptables -t nat -F
iptables -t nat -X 2>/dev/null || true

# Keep things open until we finish installing the rules
iptables -P INPUT   ACCEPT
iptables -P FORWARD DROP
iptables -P OUTPUT  ACCEPT

# Prevent unknowingly letting traffic through in an environment where
# --uid-owner is unavailable (fail-close)
if ! iptables -t nat -A OUTPUT -m owner --uid-owner "$PROXY_UID" -j RETURN 2>/dev/null; then
  echo "[firewall] ERROR: iptables owner match is unavailable (xt_owner). Aborting" >&2
  exit 1
fi
iptables -t nat -D OUTPUT -m owner --uid-owner "$PROXY_UID" -j RETURN

# Destination of the notification bridge (stood up by the host-side claude-box).
# host.docker.internal is placed into /etc/hosts via --add-host, so look it up
# with getent (dig only sees DNS). iptables is v4-only, so restrict to IPv4 with
# ahostsv4.
host_ip=""
if [[ "${CLAUDE_BOX_BRIDGE_PORT:-}" =~ ^[0-9]+$ ]]; then
  host_ip="$(getent ahostsv4 host.docker.internal | cut -d' ' -f1 | head -n1 || true)"
  [ -z "$host_ip" ] && echo "[firewall] WARN: could not resolve host.docker.internal (notifications will not arrive)" >&2
fi

echo "[firewall] transparently redirecting 80/443 to the proxy..."
# Local destinations and the proxy itself pass through directly. All other
# 80/443 traffic necessarily goes through the proxy.
iptables -t nat -A OUTPUT -d 127.0.0.0/8 -j RETURN
iptables -t nat -A OUTPUT -m owner --uid-owner "$PROXY_UID" -j RETURN
[ -n "$host_ip" ] && iptables -t nat -A OUTPUT -d "$host_ip" -j RETURN
iptables -t nat -A OUTPUT -p tcp --dport 443 -j REDIRECT --to-ports "$TLS_PORT"
iptables -t nat -A OUTPUT -p tcp --dport 80  -j REDIRECT --to-ports "$HTTP_PORT"

iptables -A INPUT  -i lo -j ACCEPT
iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# After REDIRECT the packet's destination is rewritten to 127.0.0.1, but the
# output interface stays as it was (eth0), so `-o lo` cannot catch it. Allow it
# explicitly by destination.
iptables -A OUTPUT -d 127.0.0.0/8 -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# The only thing that can reach the outside is the proxy uid's 80/443. Which
# host to connect to has already been judged by hostname in nginx, so here we do
# not care about the destination IP.
iptables -A OUTPUT -m owner --uid-owner "$PROXY_UID" -p tcp -m multiport --dports 80,443 -j ACCEPT

# Only the notification bridge is allowed per-port without going through the
# proxy (it is HTTP, but the destination is within the host)
if [ -n "$host_ip" ]; then
  iptables -A OUTPUT -p tcp -d "$host_ip" --dport "$CLAUDE_BOX_BRIDGE_PORT" -j ACCEPT
  echo "[firewall] notification bridge allowed: $host_ip:$CLAUDE_BOX_BRIDGE_PORT"
fi

iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
iptables -P OUTPUT DROP

# IPv6 is not covered by the transparent redirect, so close it off to avoid
# letting traffic through (keep only DNS, in case resolv.conf is v6).
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -F 2>/dev/null || true
  ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
  ip6tables -A OUTPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || true
  ip6tables -A OUTPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
  ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
  ip6tables -P OUTPUT DROP 2>/dev/null || echo "[firewall] WARN: cannot close IPv6" >&2
fi

echo "[firewall] verifying behavior..."
fail=0

# 1. Non-allowed TLS -> the SNI is not in the allowlist, so it is not relayed
if curl -fsS --max-time 5 -o /dev/null https://example.com 2>/dev/null; then
  echo "[firewall] ERROR: https://example.com got through (should be blocked)" >&2
  fail=1
fi
# 2. Non-allowed plaintext HTTP -> the Host is not in the allowlist, so 403
if curl -fsS --max-time 5 -o /dev/null http://example.com 2>/dev/null; then
  echo "[firewall] ERROR: http://example.com got through (should be blocked)" >&2
  fail=1
fi
# 3. Allowed destination -> passes. Also check Claude Code's own upstreams (this
#    is the very reason the box exists, so we do not want to proceed unaware that
#    a missing allow entry leaves claude unable to start).
# We do not pass -f because, as long as it is reachable, we do not care about the
# HTTP status (302/403, etc.). When it is denied, the connection itself is reset
# and curl exits non-zero.
for u in https://api.github.com/zen https://claude.com/ https://code.claude.com/ \
         https://platform.claude.com/; do
  if ! curl -sS --max-time 15 -o /dev/null "$u" 2>/dev/null; then
    echo "[firewall] WARN: cannot reach $u (check the allowlist / DNS)" >&2
  fi
done
# 4. The destination IP is decided by the proxy's own re-resolution, not by the
#    client's specification = it is unaffected by DNS drift, and SNI spoofing
#    cannot connect you to a different IP
if ! curl -fsS --max-time 15 -o /dev/null \
      --resolve api.github.com:443:192.0.2.1 https://api.github.com/zen 2>/dev/null; then
  echo "[firewall] WARN: the proxy-side name re-resolution may not be in effect" >&2
fi
# 5. Confirm there is no path to connect to a different host by spoofing an
#    allowed hostname (Host header spoofing)
if curl -fsS --max-time 5 -o /dev/null -H 'Host: example.com' http://deb.debian.org/ 2>/dev/null; then
  echo "[firewall] ERROR: Host header spoofing lets you out to non-allowed destinations" >&2
  fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "[firewall] done. default outbound: DROP (80/443 only via the hostname filter)"
