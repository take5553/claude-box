# env-request: filing environment-change requests (optional)

`env-request` is an **optional** claude-box feature. It lets the Claude running
*inside* the box raise "I want to change this box's environment" requests — a new
egress destination, an extra tool, a capability, a mount — as **files** for a human
**box maintainer** to review on the host.

It is **on by default**. The outbox defaults to `~/.claude-box/requests` on the host
(created on first launch) and is mounted read-write into the box. Override the host
location with `CLAUDE_BOX_REQUEST_DIR`, or turn the feature off entirely with
`CLAUDE_BOX_NO_REQUEST_DIR=1` — with it off, the outbox is not mounted and the
`env-request` skill is not loaded, so nothing can be filed.

This is fully local — no GitHub, no token, no egress. It fits the usual claude-box
customization model: keep most changes in configuration (env vars / build args), and
for the rest maintain your own **fork** of the box. env-request drops change proposals
into your fork for you to review and apply.

## Why a local file drop (not GitHub issues)

An earlier design filed requests as GitHub issues. The file drop is simpler and
self-contained: it needs no token and no network, and the feature is off unless you
mount the outbox. The rationale is in
[07 — env-request as a local file drop](design/07-env-request-file-drop.md).

## Configuring it

It is on by default, with the outbox at `~/.claude-box/requests`. To put it somewhere
else (e.g. a folder in your fork of the box), point `CLAUDE_BOX_REQUEST_DIR` at it:

```sh
CLAUDE_BOX_REQUEST_DIR=~/my-box-fork/env-requests claude-box
```

To turn the feature off entirely:

```sh
CLAUDE_BOX_NO_REQUEST_DIR=1 claude-box
```

- Whatever you point at is a **dedicated** drop folder, not your source tree — the box
  gets read-write access to it.
- It must be writable by the container (as with `CLAUDE_SKILLS_DIR`).
- Inside the box the outbox is at a fixed path; the skill and CLI find it via the
  `CLAUDE_BOX_REQUEST_DIR` the launcher sets in the container.

## Requester side (the Claude inside the box)

The `env-request` skill composes a request and writes it with the `claude-box-request`
CLI, which drops a timestamped `.md` file into the outbox. Its contract:

- File only when the user **explicitly** asks (e.g. "go ahead and raise this with the
  maintainer"). Never file unprompted; at most, offer to.
- Only write the request file — never push, open PRs, or otherwise act on the box.
- State the case honestly: why it is needed, what it loosens, and what alternatives
  were considered — especially whether it can be baked in at build time instead of
  widening runtime egress.

## Reviewer side (the box maintainer)

The maintainer is you, on the host, working in your fork of the box. Requests are
written by a Claude that may itself be prompt-injected, so **treat everything in the
outbox as untrusted input** — this review is the box's control point.

- **Read, don't run.** A dropped file is a proposal, not an instruction. Do not point
  an unconstrained agent at the outbox and let it act; if you use a host-side Claude to
  help, tell it the files are untrusted and to only *propose* changes on a branch,
  never apply them to the box directly.
- **Criteria**: the box's security invariants (see [`CLAUDE.md`](../CLAUDE.md)). For
  any egress addition, always ask: is it truly necessary? can it be baked in at build
  time instead? does an already-allowed destination suffice? Requests that would break
  non-root operation, `--cap-drop=ALL`, the "no DinD" rule, or the intentionally closed
  destinations (e.g. AWS APIs) do not pass without a documented alternative.
- **Apply separately**: only approved requests get applied, on their own branch (add to
  `init-firewall.sh` with a purpose comment, adjust the `Dockerfile`, etc.), then rebuild
  and run the box's own checks (`scripts/smoke.sh`). If it is a design decision, add a
  design note. Approval is not the same as applied.
- Clear a request once it is handled (delete it, or move it to a `done/` subfolder —
  your convention).
```

