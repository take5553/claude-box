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
- Credentials and history persist in a dedicated volume, kept separate from the
  host's. Named items of your `~/.claude` — settings, `skills/`, `agents/`,
  `commands/`, `plugins/` and the global `CLAUDE.md` — are imported so a box behaves
  like the Claude you configured, **shared read-write by default**;
  `CLAUDE_BOX_HOST_CONFIG=ro` (or `off`) keeps the box from writing any of it back
  ([design 10](docs/design/10-host-config-import-modes.md)).

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

### Your `~/.claude` comes into the box — and is shared, not copied

So that a box behaves like the Claude you already configured, these items are taken
from the host's `~/.claude` (`CLAUDE_CONFIG_DIR` if you set one) and, **by default,
shared read-write**:

| Item | Variable | Default |
|---|---|---|
| `settings.json`, `settings.local.json` | `CLAUDE_BOX_SETTINGS` | `rw` |
| `skills/` | `CLAUDE_BOX_SKILLS` | `rw` |
| `agents/` | `CLAUDE_BOX_AGENTS` | `rw` |
| `commands/` | `CLAUDE_BOX_COMMANDS` | `rw` |
| `plugins/` (installed plugins and marketplaces) | `CLAUDE_BOX_PLUGINS` | `rw` |
| `CLAUDE.md` | `CLAUDE_BOX_GLOBAL_MD_MODE` | `rw` |

Each variable takes `rw` (share it), `ro` (bring it in, but the box cannot write to
it) or `off` (do not bring it in). `CLAUDE_BOX_HOST_CONFIG` sets all of them at once.

> [!IMPORTANT]
> **`rw` means the box writes to your host's files.** That is what makes a skill or a
> setting produced in the box stick — but the box runs YOLO, and your host's Claude
> Code loads those same files afterwards: a hook added to `settings.json`, or a
> skill left in `skills/`, runs **on your host** later. This is the one place the
> box's blast radius reaches the host.
>
> - `CLAUDE_BOX_HOST_CONFIG=ro` — inherit all of it, write none of it back.
> - `CLAUDE_BOX_HOST_CONFIG=off` — a pristine box, nothing imported.
> - Or per item: `CLAUDE_BOX_SETTINGS=ro`, `CLAUDE_BOX_SKILLS=off`, …
>
> Keeping `~/.claude` under version control (or diffing it after a session) is the
> cheap way to see what came back.

Only paths that already exist on the host are mounted, and nothing is created there.
**Credentials, history and session state are not shared** — they stay in the box's own
volume. The reasoning is in [design 10](docs/design/10-host-config-import-modes.md).

### Environment variables

| Variable | Effect |
|---|---|
| `GH_TOKEN` | Allow GitHub operations (push/PR/issue). Pass a narrowly-scoped, short-lived token **only at runtime** (never stored). |
| `CLAUDE_SKILLS_DIR` | Skills directory to mount **instead of** the host's `~/.claude/skills`. A non-existent path is an error. |
| `CLAUDE_BOX_GLOBAL_MD` | Instructions file to use **instead of** the host's `~/.claude/CLAUDE.md`. |
| `CLAUDE_BOX_ENGINE` | Container engine (docker-compatible CLI). Default `docker`; only docker is verified. |
| `CLAUDE_BOX_IMAGE` | Image to run. Default `claude-box:latest`. |
| `CLAUDE_BOX_NESTED_CONTAINERS=1` | Enable in-container rootless Podman (adds relaxations). **Off by default** — see [Security model](#security-model). |
| `CLAUDE_BOX_NO_GITCONFIG=1` | Do not mount `~/.gitconfig` (avoids host-specific settings breaking git). |
| `CLAUDE_BOX_HOST_CONFIG` | Import mode for **everything** from the host's `~/.claude`: `rw` / `ro` / `off` (see [above](#your-claude-comes-into-the-box--and-is-shared-not-copied)). Per-item variables override it. |
| `CLAUDE_BOX_SETTINGS` | Mode for `settings.json` / `settings.local.json`. Default `rw`; `ro` merges them into the box's own copy instead. |
| `CLAUDE_BOX_SKILLS` / `CLAUDE_BOX_AGENTS` / `CLAUDE_BOX_COMMANDS` / `CLAUDE_BOX_PLUGINS` | Mode for `~/.claude/skills` / `agents` / `commands` / `plugins`. Default `rw`. |
| `CLAUDE_BOX_GLOBAL_MD_MODE` | Mode for the global `CLAUDE.md`. Default `rw`; `ro` replaces the box's copy with the host's file at startup instead of sharing it. |
| `CLAUDE_BOX_REQUEST_DIR` | Host folder for the env-request outbox. **On by default** (`~/.claude-box/requests`); set this to relocate it. |
| `CLAUDE_BOX_NO_REQUEST_DIR=1` | Turn off the env-request outbox (on by default). |
| `EXTRA_ALLOW_DOMAINS` | **Add** egress destinations (core always included; space-separated). |
| `ALLOW_DOMAINS` | Replace the optional egress list wholesale (space-separated; **core is always kept**). |
| `SKIP_FIREWALL=1` | Disable the firewall entirely (**unrestricted egress**; prints a warning). |

#### Setting them in `.zshrc`

All of these are read at launch, so `VAR=value claude-box` works for one-off runs and
`export` in your shell profile sets your normal default. A `.zshrc` block to start
from:

```sh
# ---- claude-box -----------------------------------------------------------
# Keep every variable inside the wrapper rather than exporting it into your shell.
# `command` runs the real launcher on PATH, so the function can carry the same name
# without recursing, and `local -x` un-sets each variable again when it returns.
claude-box() {
  local -x CLAUDE_BOX_IMAGE="${CLAUDE_BOX_IMAGE:-claude-box:latest}"

  # Only if you run docker / compose inside the box (adds sandbox relaxations)
  # local -x CLAUDE_BOX_NESTED_CONTAINERS="${CLAUDE_BOX_NESTED_CONTAINERS:-1}"

  # Your ~/.claude is shared read-write by default. Uncomment to keep a box from
  # writing any of it back (see the import section above).
  # local -x CLAUDE_BOX_HOST_CONFIG="${CLAUDE_BOX_HOST_CONFIG:-ro}"

  # Skills kept in their own repo rather than in ~/.claude/skills
  # local -x CLAUDE_SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/dev/my-skills}"

  # Egress destinations you always want (the core list is kept regardless)
  # local -x EXTRA_ALLOW_DOMAINS="${EXTRA_ALLOW_DOMAINS:-pypi.org files.pythonhosted.org}"

  # `claude-box --gh …` hands *this run* a GitHub token from the Keychain, so a plain
  # `claude-box` never has one. (Linux: `secret-tool lookup …`)
  if [ "${1:-}" = --gh ]; then
    shift
    local -x GH_TOKEN="$(security find-generic-password -s claude-box-gh -w)"
  fi

  command claude-box "$@"
}
# ---------------------------------------------------------------------------
```

Each variable is written as `${VAR:-default}`, so a one-off `CLAUDE_BOX_HOST_CONFIG=ro
claude-box` still wins over the wrapper's value. `GH_TOKEN` in particular is worth
keeping in here rather than in an `export`: exported, it would be handed to *every*
box — and to everything else in your shell.

### What is mounted

Only these host resources enter the box. **The home directory is not mounted.**

| Brought in | Mounted at | When / notes |
|---|---|---|
| Current project | **same absolute path as the host** (e.g. `/home/you/project`) | always, read-write. Claude Code keys its history on the current path, so a fixed `/workspace` would blend every project's history. **The matching path is why — the home directory is not mounted.** |
| Auth/settings volume | `/home/node/.claude` | always. A dedicated volume, **separate** from the host's `~/.claude`. |
| `~/.gitconfig` | `/home/node/.gitconfig` (ro) | only if the file exists. Disable with `CLAUDE_BOX_NO_GITCONFIG=1`. |
| `~/.claude/settings.json`, `settings.local.json` | `/home/node/.claude/` (**rw**, shared) | **default on** for files that exist. `/config` and permission changes made in the box write through to the host. `CLAUDE_BOX_SETTINGS=ro` mounts them at `/etc/claude-box/host-settings*.json` and merges into the box's own copy instead ([design 08](docs/design/08-host-global-settings-import.md)). |
| `~/.claude/skills`, `agents`, `commands`, `plugins` | matching paths under `/home/node/.claude` (**rw**, shared) | **default on** for directories that exist. Skills / subagents / slash commands / installed plugins written in the box persist on the host — the one place the box writes back ([design 10](docs/design/10-host-config-import-modes.md)). `CLAUDE_SKILLS_DIR` points skills elsewhere. |
| Global `CLAUDE.md` | `/home/node/.claude/CLAUDE.md` (**rw**, shared) | **default on** if the file exists. With `CLAUDE_BOX_GLOBAL_MD_MODE=ro` it is mounted at `/etc/claude-box/global-CLAUDE.md` and *replaces* the box's copy at every launch instead. Source overridable with `CLAUDE_BOX_GLOBAL_MD`. |
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

**A hook / `statusLine` fails inside the box** — the imported settings may point at
commands or paths that exist only on the host (`hooks`, `statusLine`,
`apiKeyHelper`). Set `CLAUDE_BOX_SETTINGS=off`, or move the host-specific entries out
of the global `settings.json`. With `CLAUDE_BOX_SETTINGS=ro` you can also fix it
inside the box: the box's merged copy is writable and never reaches the host.

**Changing a setting inside the box fails to save** — with the default
`CLAUDE_BOX_SETTINGS=rw` the host's `settings.json` is bind-mounted as a file, and
`claude` rewrites it through an in-place fallback because renaming onto a bind mount
is not possible. If a version ever loses that fallback, use `CLAUDE_BOX_SETTINGS=ro`
(the box then keeps its own copy) — see
[design 10](docs/design/10-host-config-import-modes.md).

**An old skill / plugin reappeared, or in-box config went missing** — the host's
`~/.claude` is mounted over the box's own copies at every launch, so the host's
`skills`, `agents`, `commands` and `plugins` directories shadow whatever the box's
volume had at those paths (it is still in the `claude-box-config` volume, just
hidden). With `CLAUDE_BOX_GLOBAL_MD_MODE=ro` the box's `CLAUDE.md` is likewise
replaced by the host's file at every launch. `CLAUDE_BOX_HOST_CONFIG=off` gives you a
box with none of it ([design 10](docs/design/10-host-config-import-modes.md)).

**`known_marketplaces.json` keeps changing** — it records each marketplace's install
path absolutely, and the same directory is `/Users/you/.claude/plugins/...` on the
host and `/home/node/.claude/plugins/...` in the box. Claude Code notices the path is
outside its own plugins directory and rewrites the entry, so each side repairs the
file on startup; the plugins themselves work. Set `CLAUDE_BOX_PLUGINS=off` if the
churn bothers you.

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
