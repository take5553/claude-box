# Base on Node.js 24 (the current Active LTS) atop Debian 13 (trixie).
# Pin the version explicitly (avoid lts-* tags, which jump on their own once
# Node 26 becomes LTS).
FROM node:24-trixie-slim

# 1. Required tools
#    - iptables: for the egress firewall (transparent 80/443 redirect + default DROP)
#    - dnsutils (dig) / iproute2: for inspecting networking
#    - jq: for editing .claude.json in the entrypoint
#    - sudo: to run only the firewall as root from the node user
#    - make / vim: for developing/editing inside the container
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git iptables dnsutils iproute2 jq sudo \
      python3 python3-pip python3-venv \
      make vim \
    && rm -rf /var/lib/apt/lists/*

# 1b. Hostname-based egress filter (design 02).
#     nginx's stream module (ssl_preread) peeks at the TLS SNI to decide whether
#     to allow the connection. On Debian, stream is a dynamic module
#     (libnginx-mod-stream), so install it separately.
#     Decisions are made on hostname alone and TLS is never decrypted = no MITM,
#     no CA distribution.
RUN apt-get update && apt-get install -y --no-install-recommends \
      nginx-light libnginx-mod-stream \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nginx/sites-enabled/default

# Run the proxy under a dedicated uid. If it shared the node uid with claude,
# the firewall's "only the proxy uid may go directly outbound" exemption would
# also apply to claude and let it pass straight through, so separating them is
# itself a security requirement (design 02).
#
# Create the working directories at build time as root:egressd 0775. The
# container runs with cap-drop=ALL (no CHOWN, no DAC_OVERRIDE), so at runtime
# root cannot fix ownership or write into someone else's directory. Both root
# (which generates the allowlist) and egressd (pid/logs/temp files) must be
# able to write here, and that state has to be set up now.
RUN useradd --system --no-create-home --shell /usr/sbin/nologin egressd \
 && install -d -o root -g egressd -m 0775 \
      /run/egress-proxy /var/log/egress-proxy /var/lib/egress-proxy

# 2. Rootless Podman (docker-compatible) for testing Dockerfiles / compose
#    inside the container. dockerd's DinD requires --privileged and would break
#    the sandbox, so it is not adopted. Podman runs inside the node user's user
#    namespace, so it needs no extra privileges, and nested containers' egress
#    also goes through the outer firewall.
#    podman-compose is the external provider for `docker compose`
#    (= podman compose). We do not install real docker; install it from the same
#    apt so its version matches Debian's podman (apt also resolves the dependent
#    PyYAML / python-dotenv, etc.).
#    WITH_PODMAN=0 removes this whole set (and the rootless setup that follows)
#    entirely (see README).
ARG WITH_PODMAN=1
RUN if [ "$WITH_PODMAN" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends \
        podman crun conmon uidmap slirp4netns passt fuse-overlayfs \
        netavark aardvark-dns libcap2-bin podman-compose \
      && rm -rf /var/lib/apt/lists/*; \
    fi

# subuid/subgid needed for rootless (leave untouched if the base image already has them)
RUN if [ "$WITH_PODMAN" = "1" ]; then \
      { grep -q '^node:' /etc/subuid || echo 'node:100000:65536' >> /etc/subuid; }; \
      { grep -q '^node:' /etc/subgid || echo 'node:100000:65536' >> /etc/subgid; }; \
    fi

# Debian's new{u,g}idmap are the setuid-root kind, but once euid becomes 0 the
# process is "neither the userns owner (uid 1000) nor a holder of CAP_SYS_ADMIN",
# so in this cap-dropped container the kernel rejects the write to uid_map.
# Switching them to the file-capabilities kind like Fedora (euid stays 1000 =
# full authority as the userns owner) makes it work with no extra caps.
RUN if [ "$WITH_PODMAN" = "1" ]; then \
      chmod u-s /usr/bin/newuidmap /usr/bin/newgidmap \
   && setcap cap_setuid+ep /usr/bin/newuidmap \
   && setcap cap_setgid+ep /usr/bin/newgidmap; \
    fi

# Podman tweaks:
#   - resolve short names like `FROM alpine` to docker.io
#   - no systemd/journald inside the container, so pin to the cgroupfs / file loggers
#   - empty default_sysctls: the default ping_group_range setting becomes a write
#     to the /proc/sys that Docker masks read-only and fails (only ping on the
#     nested side is sacrificed)
#   - pin the compose provider to podman-compose. By default it tries
#     docker-compose first, which is not installed, so suppress that probe and the
#     "running external provider" notice log
#   - allow invoking it as `docker` (nodocker is the marker that suppresses the
#     compatibility notice)
RUN if [ "$WITH_PODMAN" = "1" ]; then \
      mkdir -p /etc/containers/registries.conf.d /etc/containers/containers.conf.d \
   && printf 'unqualified-search-registries = ["docker.io"]\n' \
        > /etc/containers/registries.conf.d/50-docker-io.conf \
   && printf '[containers]\ndefault_sysctls = []\n\n[engine]\ncgroup_manager = "cgroupfs"\nevents_logger = "file"\ncompose_providers = ["podman-compose"]\ncompose_warning_logs = false\n' \
        > /etc/containers/containers.conf.d/50-claude-box.conf \
   && ln -s /usr/bin/podman /usr/local/bin/docker \
   && touch /etc/containers/nodocker; \
    fi

# Make editor launches (e.g. git commit) use vim
ENV EDITOR=vim

# trixie leans toward nftables. If legacy is unavailable, it auto-falls back to
# nft (swallowed by || true). The firewall uses conntrack matches so it works
# under nft too.
RUN update-alternatives --set iptables /usr/sbin/iptables-legacy || true

# Install the GitHub CLI (gh) from the release binaries.
#   - Get the version from github.com's redirect target (api.github.com tends to
#     403 without a UA)
#   - To pin it, override with  --build-arg GH_VERSION=2.96.0
ARG GH_VERSION=""
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    ver="${GH_VERSION:-$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/cli/cli/releases/latest | grep -oP 'releases/tag/v\K[^/]+')}"; \
    test -n "$ver"; \
    curl -fsSL "https://github.com/cli/cli/releases/download/v${ver}/gh_${ver}_linux_${arch}.tar.gz" -o /tmp/gh.tgz; \
    tar -xzf /tmp/gh.tgz -C /tmp; \
    install -m 0755 "/tmp/gh_${ver}_linux_${arch}/bin/gh" /usr/local/bin/gh; \
    rm -rf /tmp/gh.tgz "/tmp/gh_${ver}_linux_${arch}"; \
    gh --version

# Install pre-commit from the zipapp (.pyz) on GitHub releases.
#   - Debian trixie's pip refuses a direct system install under PEP 668
#     (externally-managed), so run the self-contained zipapp with the existing
#     python3 instead
#   - Fetching/pinning the version (--build-arg PRE_COMMIT_VERSION=4.6.0) works
#     the same way as gh
#   - Building the hook environments at runtime (repo clone / pip install) is
#     satisfied entirely by the firewall-allowed github.com / pypi.org /
#     files.pythonhosted.org
ARG PRE_COMMIT_VERSION=""
RUN set -eux; \
    ver="${PRE_COMMIT_VERSION:-$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/pre-commit/pre-commit/releases/latest | grep -oP 'releases/tag/v\K[^/]+')}"; \
    test -n "$ver"; \
    curl -fsSL "https://github.com/pre-commit/pre-commit/releases/download/v${ver}/pre-commit-${ver}.pyz" -o /usr/local/lib/pre-commit.pyz; \
    printf '#!/bin/sh\nexec python3 /usr/local/lib/pre-commit.pyz "$@"\n' > /usr/local/bin/pre-commit; \
    chmod 0755 /usr/local/bin/pre-commit; \
    pre-commit --version

# Go toolchain (for pre-commit's language: golang hooks, e.g. building gitleaks).
#   - Baking it into the image at build time makes pre-commit detect the system
#     go and stop downloading Go itself from go.dev / dl.google.com (narrowing
#     runtime egress to just the Go module proxy)
#   - The baked-in version is the latest stable, so it satisfies the version a
#     hook's go.mod requires (gitleaks is on the go 1.24 line) and no extra
#     toolchain download happens
#   - Get the version from go.dev's JSON; pin with --build-arg GO_VERSION=1.26.5
ARG GO_VERSION=""
ARG WITH_GO=1
RUN set -eux; \
    if [ "$WITH_GO" = "1" ]; then \
      arch="$(dpkg --print-architecture)"; \
      ver="${GO_VERSION:-$(curl -fsSL 'https://go.dev/dl/?mode=json' | jq -r '.[0].version' | sed 's/^go//')}"; \
      test -n "$ver"; \
      curl -fsSL "https://dl.google.com/go/go${ver}.linux-${arch}.tar.gz" -o /tmp/go.tgz; \
      rm -rf /usr/local/go; \
      tar -C /usr/local -xzf /tmp/go.tgz; \
      rm -f /tmp/go.tgz; \
      /usr/local/go/bin/go version; \
    fi
# Put go on every user's PATH (for pre-commit's system-go detection and runtime go install)
ENV PATH="/usr/local/go/bin:${PATH}"

# Playwright's Chromium (request #2 / design 06).
#   - Lets you check screens with a real browser from inside the box. Baked in at
#     build time, so it adds not a single runtime egress (cdn.playwright.dev is
#     not allowed)
#   - Placed in the all-users-shared /opt/ms-playwright and referenced via
#     PLAYWRIGHT_BROWSERS_PATH. The @playwright/test in the user repo's
#     node_modules finds this baked-in binary
#   - Chromium only. firefox / webkit are not installed (as requested)
#   - --with-deps also installs the OS libraries Chromium needs to run
#   - Pin the version with --build-arg PLAYWRIGHT_VERSION=1.56.0; default is latest.
#     If it drifts by *major/minor* from the user repo's @playwright/test, you get
#     "Executable doesn't exist at .../chromium-XXXX/" and the image must be rebuilt
#     (we accepted this tradeoff and chose not to open egress. See the review of
#     request #2)
ARG PLAYWRIGHT_VERSION=""
ARG WITH_PLAYWRIGHT=1
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN set -eux; \
    if [ "$WITH_PLAYWRIGHT" = "1" ]; then \
      ver="${PLAYWRIGHT_VERSION:-$(npm view playwright version)}"; \
      npx --yes "playwright@${ver}" install --with-deps chromium; \
      printf '%s\n' "$ver" > /opt/ms-playwright/.claude-box-version; \
      chmod -R a+rX /opt/ms-playwright; \
      rm -rf /root/.npm /var/lib/apt/lists/*; \
    fi

# Route git push authentication through gh. Written to the system config, so no
# runtime write is needed. With GH_TOKEN, push works; without it, it fails safe
# with no credentials.
RUN git config --system 'credential.https://github.com.helper' '!gh auth git-credential'

# Consolidate all of Claude Code's config and state under /home/node/.claude
# (= the persistent volume). By default the account/onboarding state is written
# to ~/.claude.json (outside the volume), which would force a login every time
# the container is recreated.
ENV CLAUDE_CONFIG_DIR=/home/node/.claude

# Apply the wrapper that makes `claude` launch in YOLO mode to every user's
# interactive shell (non-root operation, so it goes in /etc/bash.bashrc, not /root)
COPY bashrc-claude /etc/claude-box/bashrc-claude
RUN echo 'source /etc/claude-box/bashrc-claude' >> /etc/bash.bashrc

COPY init-firewall.sh  /usr/local/bin/init-firewall.sh
COPY entrypoint.sh     /usr/local/bin/entrypoint.sh
COPY egress-proxy.conf /etc/claude-box/egress-proxy.conf
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh

# Container-side parts of the notification bridge (active only when the host-side
# claude-box has stood up the bridge). forward curl-forwards the hook's stdin to
# the host's bridge, and notify-hooks.json is additively merged via --settings at
# claude startup (see bashrc-claude / entrypoint.sh). The cmux implementation of
# the generic bridge contract is in contrib/cmux/ (off by default; enable with
# CLAUDE_BOX_NOTIFY_BRIDGE).
COPY contrib/cmux/hook-forward /usr/local/bin/claude-box-notify-forward
COPY contrib/cmux/hooks.json   /etc/claude-box/notify-hooks.json
RUN chmod +x /usr/local/bin/claude-box-notify-forward

# The environment-request skill (a box-provided plugin) and the CLI that files it
# (docs/env-request-operations.md).
#   - The plugin is placed under /opt/claude-box so it is not hidden by the user's
#     ~/.claude/skills bind mount, and loaded at startup via --plugin-dir
#     (bashrc-claude / entrypoint.sh). Being namespaced (/box-core:env-request),
#     it does not collide with user skills.
#   - claude-box-request files issues directly with gh from inside the box (no
#     host mediation).
COPY plugins/box-core    /opt/claude-box/plugins/box-core
COPY claude-box-request  /usr/local/bin/claude-box-request
RUN chmod +x /usr/local/bin/claude-box-request

# Non-root operation:
#   - run claude as the node user (root would reject YOLO; no IS_SANDBOX needed)
#   - only the firewall needs root, so grant node sudo limited to init-firewall.sh
#   - create /home/node/.claude so the credentials volume is initialized owned by node
RUN printf '%s\n' \
      'Defaults:node env_keep += "ALLOW_DOMAINS CLAUDE_BOX_BRIDGE_PORT"' \
      'node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh' \
      > /etc/sudoers.d/claude-box \
 && chmod 0440 /etc/sudoers.d/claude-box \
 && mkdir -p /home/node/.claude \
 && chown -R node:node /home/node/.claude \
 && mkdir -p /home/node/.local/share/containers \
 && chown -R node:node /home/node/.local

USER node

# Install Claude Code into the node user's ~/.local via the native installer.
# With root's npm -g, auto-update fails because it cannot write to the install
# location. The container runs long-lived, so let auto-update (the latest
# channel) handle it while running, and when you want to refresh the image side,
# rebuild with  docker build --no-cache . The update check/fetch target is
# downloads.claude.ai (allowed in init-firewall.sh).
ENV PATH="/home/node/.local/bin:${PATH}"
RUN curl -fsSL https://claude.ai/install.sh | bash -s latest \
 && claude --version

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]

