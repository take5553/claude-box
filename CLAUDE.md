# Working on claude-box

This repository is a box that runs Claude Code inside an isolated, egress-restricted
container (see [README.md](README.md)). These are the conventions for developing the
**box itself**.

Human contributors: see [CONTRIBUTING.md](CONTRIBUTING.md) — it holds the same
conventions, kept here where the in-repo Claude reads them automatically.

## Security invariants (top priority)

The box exists to run YOLO (`--dangerously-skip-permissions`) safely. Do not make a
change that breaks any of the following unless you first write the reasoning and an
alternative safeguard into a design note:

- Keep non-root (`node`) operation and `--cap-drop=ALL` (add back only the capabilities
  actually needed).
- Egress stays default-deny. To add a destination, append it **explicitly** to `DOMAINS`
  in `init-firewall.sh` with a comment explaining its purpose. Matching is by hostname
  ([design 02](docs/design/02-default-deny-egress.md)), so do not break the
  premise that the proxy runs under a dedicated uid, nor the `--uid-owner` fail-closed
  rule.
- The only way to run a container inside the container is rootless Podman. Do not add
  DinD (`--privileged`) or mount the host docker socket.
- Do not casually add intentionally-closed destinations (e.g. AWS APIs) to the
  allow-list.

Background lives in [`docs/design/`](docs/design/) — especially 01, 02, 04, 05.

## Verifying changes

- **Changing the `Dockerfile` requires a rebuild**: `docker build -t claude-box:latest .`
  (use `--build-arg` to pin tool versions).
- **Egress-related changes** (adding a new external dependency, etc.) must be verified
  for reachability on real hardware with the firewall enabled. `init-firewall.sh`
  self-checks at startup that disallowed destinations are blocked and allowed ones are
  reachable. Prefer baking a dependency in at build time over widening runtime egress
  ([design 06](docs/design/06-bake-tools-at-build-time.md)).
- For changes that touch the whole startup flow, confirm that `claude-box` (host side)
  and `entrypoint.sh` (container side) stay consistent — e.g. a direct `claude-box claude`
  launch does not go through the shell wrapper, so the same injection has to exist in
  entrypoint too.

## Commits / branches

- Do not commit directly to `main`; cut a working branch.
- Write commit messages in English. Subject = *what*; body = *why* (background, rejected
  alternatives). Append a `Co-Authored-By` trailer.
- Keep the history legible — the commits here double as a record of the reasoning.

## Recording design decisions

When you make or reverse a design choice, add a design note under
[`docs/design/`](docs/design/) (Nygard style). Do not delete older notes; update their
status and cross-reference them from the newer one.

## File roles

See the [Repository layout](README.md#repository-layout) table in the README — it is
the single source of truth for what each file does.
