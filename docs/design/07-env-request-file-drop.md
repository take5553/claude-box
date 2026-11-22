# 07 — env-request as a local file drop (optional)

Related: [01 — isolation model](01-isolation-model.md),
[02 — default-deny egress](02-default-deny-egress.md)

## Context

The box's customization model pushes most needs into configuration — egress via
`EXTRA_ALLOW_DOMAINS`, baked tools via the `WITH_*` build args, skills / instructions /
mounts via environment variables — so that a plain clone can track upstream with a
`git pull`. What is left over needs an actual code change (a new baked tool, a permanent
egress entry, a structural change), which the maintainer applies to their own **fork**.

`env-request` is the optional channel for that leftover: the Claude *inside* the box
proposes such a change to the maintainer. The question is how the proposal travels from
the box to the maintainer.

## Decision

Use a **local file drop**. When `CLAUDE_BOX_REQUEST_DIR` points to a host directory,
claude-box mounts it read-write into the box; the in-box `claude-box-request` CLI writes
a timestamped Markdown request there. The maintainer reads the files on the host. No
GitHub, no token, no egress.

- **On by default, with an opt-out.** The outbox defaults to `~/.claude-box/requests`
  (override the host location with `CLAUDE_BOX_REQUEST_DIR`); set
  `CLAUDE_BOX_NO_REQUEST_DIR=1` to turn the feature off entirely, in which case the CLI
  errors and the env-request skill is not loaded. It is on by default for convenience; the
  safety rests on the points below, not on the box staying unmounted.
- **The review is the control point — unchanged.** The request is written by a Claude
  that may be prompt-injected, so it is *untrusted input*. The maintainer treats the whole
  outbox as untrusted, reviews, and applies only on a branch (then rebuild +
  `scripts/smoke.sh`). Nothing is applied automatically; a dropped file is a proposal,
  never an instruction to run.
- **A dedicated, narrow mount.** The outbox is a drop folder, not the source tree. The box
  can write there, but that is the extent of the new host reach — consistent with the
  minimal-mount principle ([01](01-isolation-model.md)).

## Rejected alternative: GitHub issues

The first design filed each request as a GitHub issue via `gh`, reusing the box's existing
`GH_TOKEN` and GitHub egress. Filing an issue is *structurally unpreventable* from inside
the box (it can reach GitHub), which made "the control point is the review, not the filing"
explicit. But it also required a token with issue-create scope and a network round-trip
through GitHub.

The file drop keeps the same "review is the control point" invariant while removing the
token/egress dependency; the outbox has a sensible default and can be relocated or disabled.
Use the issue approach only if you specifically want a remote/team queue with discussion and labels;
for the common solo/fork workflow, the file drop is self-contained.

## Consequences

### Good

- Fully local: no token, no GitHub, no added egress for the request path. The box no longer
  needs GitHub for env-request at all.
- Controllable: a dedicated default outbox that can be relocated (`CLAUDE_BOX_REQUEST_DIR`)
  or disabled (`CLAUDE_BOX_NO_REQUEST_DIR`).
- Fits the fork workflow: proposals land in the maintainer's own tree.

### Trade-offs and notes

- On by default, the feature adds one read-write host mount (a narrow, dedicated,
  initially-empty drop folder at `~/.claude-box/requests`, created on first launch) into a
  possibly-injected box. Treat its contents as untrusted (see the decision above); disable
  with `CLAUDE_BOX_NO_REQUEST_DIR=1` if you do not want it.
- No built-in queue, discussion, or status labels — adopt a file convention (e.g. move
  handled requests to a `done/` subfolder).
- As decided here the channel is one-way: the maintainer cannot answer the in-box
  Claude, so outcomes have to be relayed by hand. Extended by
  [12 — env-request replies](12-env-request-replies.md) with a separate, read-only
  reply folder.
