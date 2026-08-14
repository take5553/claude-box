# Security policy

claude-box makes a security claim — "run YOLO (`--dangerously-skip-permissions`)
safely" — so it owes you two things in return: a way to report problems privately,
and an honest statement of what it does *not* protect against.

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Use GitHub's private
vulnerability reporting instead:

- Go to the repository's **Security** tab → **Report a vulnerability**
  (GitHub Security Advisories).

Include what you were doing, what you observed, and — if you have one — a minimal
reproduction. You will get an acknowledgement; from there we triage, fix, and
coordinate disclosure on the advisory.

## What this box does and does not guarantee

The box is **one layer of defense in depth**, not a virtual machine. Understand its
boundaries before relying on it.

- **A container is not a VM.** It shares the host kernel. A kernel vulnerability or a
  container-runtime escape defeats the isolation. Do not treat the box as a hard
  boundary against a determined attacker with a kernel exploit.
- **Egress is judged by hostname; TLS is not decrypted.** The firewall controls
  *which hosts* can be reached, not *what* is sent to or received from an allowed
  host. Exfiltration through an allowed destination (e.g. a repo you can push to) is
  not prevented — the allow-list is about reachability, not content.
- **A `GH_TOKEN` you pass in is fully usable by the in-box Claude.** Anything that
  token can do, the box can do. Use a narrowly-scoped, short-lived token, never a
  long-lived personal token with broad scope.
- **You can turn the protections off yourself.** `SKIP_FIREWALL=1` disables egress
  filtering entirely (unrestricted outbound), and `ALLOW_DOMAINS` replaces the
  optional allow-list. These are intentional escape hatches; using them is on you.
- **The mounted project directory is writable — by design.** The whole point is to
  let Claude change your code. Run the box on a project under version control, and
  review the diff.
- **Nested containers loosen the sandbox when enabled.** `CLAUDE_BOX_NESTED_CONTAINERS=1`
  adds `seccomp=unconfined` / `systempaths=unconfined` and a couple of devices (no
  added capability, still non-root — not `--privileged`, and not host-docker-socket
  DinD). It is **off by default**; enable it only when you need it.

The design and rationale behind these boundaries are in
[`docs/design/`](docs/design/) — in particular
[01 — isolation model](docs/design/01-isolation-model.md) and
[02 — default-deny egress](docs/design/02-default-deny-egress.md).

## Supported versions

This is a build-it-yourself box: you build the image from this repository and run it.
Security fixes land on the default branch; rebuild the image to pick them up. There
are no separately maintained release branches.
