# 01 — Isolation model (non-root, `cap-drop=ALL`, minimal mounts)

Related: [04 — YOLO by default](04-yolo-by-default.md),
[02 — default-deny egress](02-default-deny-egress.md),
[05 — nested containers](05-nested-containers-rootless-podman.md)

## Context

We want to run `claude` with `--dangerously-skip-permissions` (YOLO —
see [04](04-yolo-by-default.md)). For autonomous execution to be safe, the
container boundary itself has to physically constrain what Claude can reach.
Running YOLO with the whole host — or the user's `$HOME` — visible is a
non-starter. The premise of the isolation model is: *whatever happens inside the
box does not reach the host or the wider network.*

## Decision

Launch the container with least privilege (the `claude-box` script).

- **Non-root**: `claude` runs as the `node` user. Dropping root means YOLO's
  root guard is not tripped, and the old `IS_SANDBOX=1` workaround is no longer
  needed (`entrypoint.sh`).
- **`--cap-drop=ALL`, adding back only what is needed**:
  - `NET_ADMIN` / `NET_RAW` — the egress firewall (iptables).
  - `SETUID` / `SETGID` — the narrow sudo that runs the firewall, and starting
    the egress proxy under a dedicated uid ([02](02-default-deny-egress.md)).
  - `AUDIT_WRITE` — sudo's audit message (without it, warning noise).
- **Mount only the target project**: the current directory `$PWD` is mounted
  read-write at the *same absolute path as on the host* (`-v "$PWD:$PWD"
  -w "$PWD"`). Claude Code keys its session history on the current path, so a
  fixed `/workspace` would blend every project's history under one key. Launching
  from `$HOME` or `/` is explicitly refused so nothing broad is exposed by
  accident.
- **Bring in as little as possible**: `~/.gitconfig` read-only (opt-out with
  `CLAUDE_BOX_NO_GITCONFIG`); named items of the host's `~/.claude` — settings,
  `skills/`, `agents/`, `commands/`, `plugins/` and `CLAUDE.md`, shared read-write by
  default — never the directory as a whole, so credentials, history and per-project
  state stay outside ([08](08-host-global-settings-import.md),
  [09](09-import-host-claude-config.md),
  [10](10-host-config-import-modes.md): each item is `rw`/`ro`/`off`, and
  `CLAUDE_BOX_HOST_CONFIG` sets all of them at once). A GitHub token (`GH_TOKEN`) is
  never stored — it is passed as an environment variable *only at runtime*.

## Consequences

### Good

- The host filesystem exposes only the current project; the network is
  default-deny ([02](02-default-deny-egress.md)). Two walls let us run YOLO on
  the safe side.
- Capabilities are added explicitly, so "why is this privilege needed" is
  self-documented in the launcher.

### Trade-offs and notes

- Nested container execution ([05](05-nested-containers-rootless-podman.md)) is
  **off by default** and opt-in via `CLAUDE_BOX_NESTED_CONTAINERS=1`. When
  enabled it passes `seccomp=unconfined` and `systempaths=unconfined` (plus a few
  devices). The default profile is loosened, but **no capability is added and it
  stays non-root** — this is not `--privileged`. A box that never runs nested
  containers is never loosened for a feature it does not use.
- Mounting the project at an absolute path keeps path-dependent behaviour
  consistent between host and container, but co-locating several projects in one
  container is out of scope (one project per launch).
