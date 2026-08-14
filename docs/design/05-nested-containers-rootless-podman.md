# 05 — Nested containers via rootless Podman (no DinD)

Related: [01 — isolation model](01-isolation-model.md),
[02 — default-deny egress](02-default-deny-egress.md),
[06 — bake tools at build time](06-bake-tools-at-build-time.md)

## Context

We want the in-box Claude to actually build and run Dockerfiles / `docker compose`
to test them. But [01](01-isolation-model.md) rests on non-root + `cap-drop=ALL`,
which must not be broken to add container execution. The usual ways to run a
container inside a container each have a problem:

- **dockerd DinD**: `--privileged` is effectively required. cap-drop becomes
  meaningless and the isolation model collapses.
- **Mounting the host docker socket**: it launches a *sibling* container on the
  host, subject to neither the box's isolation nor its egress firewall (effectively
  host root).

## Decision

Use **rootless Podman as a docker-compatible engine**. It is **off by default**,
enabled at runtime with `CLAUDE_BOX_NESTED_CONTAINERS=1`; the whole stack can also
be dropped from the image at build time with `WITH_PODMAN=0`
([06](06-bake-tools-at-build-time.md)).

- Podman runs inside `node`'s user namespace, so `docker build` / `run` work with
  no added capability. A `/usr/local/bin/docker` → `podman` symlink and `docker.io`
  short-name resolution are configured (`Dockerfile`).
- Debian's `new{u,g}idmap` are setuid-root, which the kernel rejects for `uid_map`
  writes under cap-drop. Switching them to Fedora-style **file capabilities** lets
  them work with no added cap.
- When enabled, the launcher passes `seccomp=unconfined`, `systempaths=unconfined`,
  `/dev/fuse` and `/dev/net/tun`. **No capability is added and it stays non-root** —
  not `--privileged`. Nested egress still traverses the outer
  [02](02-default-deny-egress.md) rules.
- A dedicated image-cache volume `claude-box-containers` avoids re-pulling base
  images.
- **compose**: no real docker; `podman-compose` (from apt) is wired as the external
  provider for `docker compose` (= `podman compose`), pinned in `containers.conf`.

## Consequences

### Good

- Dockerfiles and compose can be tested in the box while keeping least privilege
  ([01](01-isolation-model.md)).
- Nested traffic is under the outer firewall too, so the egress policy applies in
  two tiers.

### Trade-offs and notes

- **Putting Podman's graphRoot on a dedicated volume is a functional requirement**,
  not a cache nicety. Without mounting `claude-box-containers` at
  `/home/node/.local/share/containers`, the graphRoot sits on Docker's own
  overlayfs — **overlay on overlay** — and nested `execve` fails with `Invalid
  argument`: `docker pull` works but `docker run` never does. When starting the box
  from a bare `docker run` for debugging, always include this volume.

  Measured (Docker Desktop / kernel 6.12.67-linuxkit / arm64):

  | Configuration | nested `docker run` |
  |---|---|
  | with the volume (normal operation) | works (`graphDriverName: overlay`) |
  | no volume + crun | fails (`exec container process: Invalid argument`) |
  | no volume + runc | fails (same) |
  | no volume + `--privileged` | fails (so it is not a privilege problem) |
  | no volume + forced fuse-overlayfs | fails |
  | no volume + `--storage-driver=vfs` | works (avoids overlay) |

- Not fully Docker-compatible; rootless-specific limits can surface (publishing
  ports below 1024, the fuse-overlayfs fallback where overlay is unavailable,
  compose inter-service networking / named-volume permissions).
- The relaxations (`seccomp` / `systempaths` unconfined) loosen the default
  profile; they are only acceptable together with the "no added capability" rule.
- Podman / podman-compose come from Debian apt — an exception to
  [06](06-bake-tools-at-build-time.md)'s "bake official standalone distributions"
  (the same apt keeps versions aligned; the standalone distribution is awkward
  here).
