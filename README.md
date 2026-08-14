# claude-box

**English** · [日本語](README.ja.md)

A box for running [Claude Code](https://claude.com/claude-code) with
`--dangerously-skip-permissions` (YOLO) **safely** — inside an isolated,
egress-restricted container that mounts only the project you are working on.

The goal is to let Claude work autonomously, without per-action approval, while
keeping the blast radius inside the box: two walls — **file isolation** and a
**default-deny network** — so nothing reaches the host or the wider internet.

## What it guards — and what it deliberately leaves closed

**Guarded**

- Runs **non-root** (`node`) with `--cap-drop=ALL`, adding back only the
  capabilities the firewall needs.
- Mounts **only the current project**, at the same absolute path as on the host.
  Launching from `$HOME` or `/` is refused.
- **Default-deny egress, judged by hostname.** All 80/443 traffic is
  force-redirected through a local proxy that allows only a whitelist by TLS SNI /
  HTTP Host. TLS is **not** decrypted.
- Auth and settings persist in a dedicated volume, kept separate from the host's.
  Your global `settings.json` / `settings.local.json` are imported **one-way**
  (mounted read-only, merged in at startup — the host's copy is never written).

**Deliberately closed** (the point, not an oversight)

- **AWS API endpoints are not opened** — Terraform goes as far as `validate`;
  `apply` stays on your machine. This box verifies IaC, it does not apply it.
- **Only 80/443 leave** — no SSH (22); git uses HTTPS.
- **No DinD, no host docker socket.** Container-in-container is rootless Podman, and
  it is **off by default**.
- **TLS is not inspected**, so the box controls *which hosts* are reachable, not
  *what* is sent to an allowed one. See [SECURITY.md](SECURITY.md) for the full list
  of what is and is not guaranteed.

The reasoning behind each decision is in [`docs/design/`](docs/design/):
[isolation](docs/design/01-isolation-model.md) ·
[egress](docs/design/02-default-deny-egress.md) ·
[persistence](docs/design/03-persistent-auth-state.md) ·
[YOLO](docs/design/04-yolo-by-default.md) ·
[nested containers](docs/design/05-nested-containers-rootless-podman.md) ·
[baked tools](docs/design/06-bake-tools-at-build-time.md).

## Requirements

- A docker-compatible CLI on the host. **Verified only with Docker (Docker
  Desktop).** The engine is overridable via `CLAUDE_BOX_ENGINE` (default `docker`),
  but running on a Podman host is **untested** — Docker-specific options such as
  `--security-opt systempaths=unconfined` would need review first.
- macOS or Linux.
- The container uses the Linux user namespace and iptables, so it runs on a Linux
  host or inside the Docker Desktop Linux VM.
- On a Linux host with AppArmor enabled, nested containers additionally need
  `--security-opt apparmor=unconfined` (see [Troubleshooting](#troubleshooting)).

## Setup

```sh
# 1. Build the image
git clone <this-repo> claude-box && cd claude-box
docker build -t claude-box:latest .

# 2. Put the launcher somewhere on your PATH (example)
ln -s "$PWD/claude-box" /usr/local/bin/claude-box
```

### Build arguments

Which tools are baked into the image is selectable. The default bakes everything.

| Argument | Default | Effect |
|---|---|---|
| `WITH_PODMAN` | `1` | The rootless-Podman stack (nested container execution). `0` to drop it. |
| `WITH_GO` | `1` | The Go toolchain (for pre-commit's golang hooks). `0` to drop it. |
| `WITH_PLAYWRIGHT` | `1` | Playwright's Chromium. `0` to drop it. |
| `GH_VERSION` | latest | Pin the baked `gh` version. |
| `PRE_COMMIT_VERSION` | latest | Pin the baked pre-commit version. |
| `GO_VERSION` | latest stable | Pin the baked Go version. |
| `PLAYWRIGHT_VERSION` | latest | Pin the baked Chromium version. |

Dropping a tool with `WITH_*=0` makes the image smaller and the build faster. This
only makes the bake *selectable*; it does not move anything to runtime fetching
([design 06](docs/design/06-bake-tools-at-build-time.md)) — `WITH_PLAYWRIGHT=0` does
not reach a CDN at runtime.

- `WITH_PODMAN=0`: `docker` (= podman) is unavailable inside the box;
  `CLAUDE_BOX_NESTED_CONTAINERS=1` then has no effect, and the nested egress group
  (container registries / OS mirrors) is unnecessary.
- `WITH_GO=0`: pre-commit's golang hooks would try to fetch Go at runtime, which
  fails because `go.dev` / `dl.google.com` are not allowed — bake it in if you use
  those hooks.

```sh
# Minimal: no nested execution, no browser checks
docker build -t claude-box:latest \
  --build-arg WITH_PODMAN=0 \
  --build-arg WITH_GO=0 \
  --build-arg WITH_PLAYWRIGHT=0 .
```

## Usage

```sh
cd /path/to/your-project
claude-box            # enter a shell inside the sandbox
claude-box claude     # launch claude directly
```

Inside the box, typing `claude` launches it in YOLO mode; management subcommands
(`login` / `update` / `mcp`, etc.) pass through without the flag.

### Environment variables

| Variable | Effect |
|---|---|
| `GH_TOKEN` | Allow GitHub operations (push/PR/issue). Pass a narrowly-scoped, short-lived token **only at runtime** (never stored). |
| `CLAUDE_SKILLS_DIR` | Directory of your own skills (read-write mount). **Not mounted if unset.** A non-existent path is an error. |
| `CLAUDE_BOX_GLOBAL_MD` | A file idempotently appended to the container's global `CLAUDE.md`. **Nothing is injected if unset.** |
| `CLAUDE_BOX_ENGINE` | Container engine (docker-compatible CLI). Default `docker`; only docker is verified. |
| `CLAUDE_BOX_IMAGE` | Image to run. Default `claude-box:latest`. |
| `CLAUDE_BOX_NESTED_CONTAINERS=1` | Enable in-container rootless Podman (adds relaxations). **Off by default** — see [Security model](#security-model). |
| `CLAUDE_BOX_NO_GITCONFIG=1` | Do not mount `~/.gitconfig` (avoids host-specific settings breaking git). |
| `CLAUDE_BOX_NO_SETTINGS=1` | Do not import the host's global `settings.json` / `settings.local.json` (imported by default). |
| `CLAUDE_BOX_REQUEST_DIR` | Host folder for the env-request outbox. **On by default** (`~/.claude-box/requests`); set this to relocate it. |
| `CLAUDE_BOX_NO_REQUEST_DIR=1` | Turn off the env-request outbox (on by default). |
| `EXTRA_ALLOW_DOMAINS` | **Add** egress destinations (core always included; space-separated). |
| `ALLOW_DOMAINS` | Replace the optional egress list wholesale (space-separated; **core is always kept**). |
| `SKIP_FIREWALL=1` | Disable the firewall entirely (**unrestricted egress**; prints a warning). |

### What is mounted

Only these host resources enter the box. **The home directory is not mounted.**

| Brought in | Mounted at | When / notes |
|---|---|---|
| Current project | **same absolute path as the host** (e.g. `/home/you/project`) | always, read-write. Claude Code keys its history on the current path, so a fixed `/workspace` would blend every project's history. **The matching path is why — the home directory is not mounted.** |
| Auth/settings volume | `/home/node/.claude` | always. A dedicated volume, **separate** from the host's `~/.claude`. |
| `~/.gitconfig` | `/home/node/.gitconfig` (ro) | only if the file exists. Disable with `CLAUDE_BOX_NO_GITCONFIG=1`. |
| Global `settings.json` / `settings.local.json` | `/etc/claude-box/host-settings*.json` (ro), merged into `/home/node/.claude/` | **default on**, only for files that exist. Read-only + merged, so the host's copy is never written ([design 08](docs/design/08-host-global-settings-import.md)). Disable with `CLAUDE_BOX_NO_SETTINGS=1`. |
| Your skills | `/home/node/.claude/skills` | only if `CLAUDE_SKILLS_DIR` is set (read-write). |
| Global `CLAUDE.md` addendum | (idempotent append) | only if `CLAUDE_BOX_GLOBAL_MD` is set. |
| Containers volume | `/home/node/.local/share/containers` | only if `CLAUDE_BOX_NESTED_CONTAINERS=1`. |
| Request outbox | `/home/node/.claude-box/requests` | **default on** (host `~/.claude-box/requests`, read-write); disable with `CLAUDE_BOX_NO_REQUEST_DIR=1`. |

Launching from `$HOME` or `/` is refused, so nothing broad is exposed by accident.

### Optional features

Two extra features — cmux is opt-in, env-request is on by default:

- **cmux notifications** (opt-in) — surface the in-box Claude's waiting/finished
  notifications to a [cmux](https://github.com/manaflow-ai/cmux) pane. See
  [`contrib/cmux/`](contrib/cmux/).
- **Environment requests (`env-request`)** — **on by default**: the in-box Claude drops
  "change this box's environment" requests as files (into `~/.claude-box/requests`) for a
  maintainer to review on the host (no GitHub, no network). Relocate with
  `CLAUDE_BOX_REQUEST_DIR` or disable with `CLAUDE_BOX_NO_REQUEST_DIR=1`; see
  [`docs/env-request-operations.md`](docs/env-request-operations.md).

## Customizing

Most customization needs no code change — reach for these first, so a plain clone can
keep tracking upstream with `git pull`:

- **Egress**: add destinations at runtime with `EXTRA_ALLOW_DOMAINS`.
- **Baked tools**: `WITH_PODMAN` / `WITH_GO` / `WITH_PLAYWRIGHT` and the version
  `--build-arg`s.
- **Skills / instructions / engine / mounts / nested containers**: the environment
  variables above.

Only when you need something the knobs don't cover — a new baked tool, a permanent
egress entry in the image, a structural change — do you edit the code. For that,
**fork** the repository so you can commit your changes and still merge upstream updates.
The optional **env-request** feature is the workflow for exactly these cases: the
in-box Claude drops a change request into an outbox in your fork, which you review and
apply on a branch (see [`docs/env-request-operations.md`](docs/env-request-operations.md)).

## Troubleshooting

**`Executable doesn't exist at .../chromium-XXXX/`** — the baked Playwright Chromium
does not match the project's `@playwright/test`. Rebuild pinning the version:
`docker build --build-arg PLAYWRIGHT_VERSION=<ver> ...`. The box does not fetch it at
runtime by design ([design 06](docs/design/06-bake-tools-at-build-time.md)).

**Something can't connect** — see which hostname the egress proxy denied
(`upstream=""` / `allowed=0` mean denied):

```sh
grep 'upstream=""' /var/log/egress-proxy/tls.log    # TLS (443)
grep 'allowed=0'   /var/log/egress-proxy/http.log   # plaintext HTTP (80)
```

To allow it, add it via `EXTRA_ALLOW_DOMAINS` (runtime) or to `DOMAINS` in
`init-firewall.sh` (in the image).

**Nested `docker` / `compose` does not work** — nested containers are off by default;
enable with `CLAUDE_BOX_NESTED_CONTAINERS=1` (and `WITH_PODMAN` must be baked in). If
`docker pull` works but `docker run` fails with `Invalid argument`, the containers
volume is missing — see [design 05](docs/design/05-nested-containers-rootless-podman.md).
On a Linux host with AppArmor, also add `--security-opt apparmor=unconfined`.

**A hook / `statusLine` fails inside the box** — the imported global settings may
point at commands or paths that exist only on the host (`hooks`, `statusLine`,
`apiKeyHelper`). Turn the import off with `CLAUDE_BOX_NO_SETTINGS=1`, or move the
host-specific entries out of the global `settings.json`. Note that a merged key is
not removed by deleting it on the host — edit it inside the box, or recreate the
`claude-box-config` volume ([design 08](docs/design/08-host-global-settings-import.md)).

**git fails inside the box** — the mounted `~/.gitconfig` may reference things the
container cannot resolve (`includeIf`, signing-key paths,
`credential.helper=osxkeychain`). Disable the mount with `CLAUDE_BOX_NO_GITCONFIG=1`,
or pass only the values you need (e.g. set `user.name` / `user.email` inside the box).

## Security model

To run YOLO safely, the box keeps these as **invariants**:

- Non-root and `--cap-drop=ALL` (only needed capabilities added back).
- Egress stays default-deny; destinations are added by explicit allow-list entries.
- Container-in-container is rootless Podman only — no DinD (`--privileged`), no host
  docker socket.
- Intentionally closed: AWS APIs are not opened (Terraform `validate` only).

Loosening any of these breaks the premise of the YOLO default
([design 04](docs/design/04-yolo-by-default.md)); a change that does so needs a design
note. **Nested containers** are off by default; when enabled they add
`seccomp`/`systempaths=unconfined` and a couple of devices — **no added capability,
still non-root, not `--privileged`** (details:
[design 05](docs/design/05-nested-containers-rootless-podman.md)).

What the box does **not** guarantee, and how to report a vulnerability, are in
[SECURITY.md](SECURITY.md).

## Repository layout

| Path | Role |
|---|---|
| `Dockerfile` | Image definition (tools, rootless Podman, non-root) |
| `claude-box` | Host-side launcher (mounts, capabilities, notification bridge) |
| `entrypoint.sh` | Firewall init, optional global `CLAUDE.md` merge, hook/plugin injection |
| `init-firewall.sh` | Default-deny egress (iptables transparent redirect + hostname matching) |
| `egress-proxy.conf` | nginx config for the allow-list proxy (SNI / Host header) |
| `bashrc-claude` | Wrapper that runs `claude` in YOLO mode |
| `contrib/cmux/` | cmux notification bridge (opt-in, off by default) |
| `claude-box-request` / `plugins/box-core/` | Optional env-request skill + CLI |
| `docs/design/` | Design notes |

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Takeshi Yamazaki.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to verify changes, the security
invariants, and the conventions for commits and egress additions.
