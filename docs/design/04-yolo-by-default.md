# 04 — Run `claude` in YOLO by default

Related: [01 — isolation model](01-isolation-model.md),
[02 — default-deny egress](02-default-deny-egress.md)

## Context

The box exists to let Claude work autonomously without per-action approval.
Vanilla `claude` prompts for permission on each action, which is friction in an
isolated environment. Using `--dangerously-skip-permissions` (YOLO) unconditionally
would normally be extremely dangerous — it becomes acceptable only because **the
isolation model itself is the safety boundary**.

## Decision

- In interactive shells, `claude` is a wrapper function that adds
  `--dangerously-skip-permissions` by default (`bashrc-claude`).
- When launched directly as `claude-box claude ...` the wrapper is bypassed, so
  `entrypoint.sh` injects the same flags.
- Management subcommands — `login`, `logout`, `update`, `mcp`, `config`, `doctor`,
  `setup-token`, `--version`, `--help` — are passed through untouched (the flag
  would break them or is pointless). The wrapper and entrypoint use the same list.
- Safety rests not on Claude's own confirmations but on
  [01](01-isolation-model.md) (non-root, cap-drop, minimal mounts) and
  [02](02-default-deny-egress.md) (default-deny egress).

## Consequences

### Good

- Inside the box, autonomous work runs without confirmation prompts — the intended
  use (isolated automatic execution) is achieved directly.
- Non-root operation avoids YOLO's root guard, letting the old `IS_SANDBOX=1` be
  dropped.

### Trade-offs and notes

- YOLO depends strongly on "safe only inside the box". If either the isolation
  model ([01](01-isolation-model.md)) or egress ([02](02-default-deny-egress.md))
  is broken, this decision's risk is realised directly — so 01 and 02 are
  preconditions of this note and must not be loosened on their own.
- The management-subcommand pass-through list is hard-coded; if Claude Code adds a
  new management subcommand, both the wrapper and entrypoint must be updated.
