# 09 — Import the host's Claude config by default (skills, instructions, agents, commands)

Related: [08 — importing the host's global settings](08-host-global-settings-import.md),
[03 — persistent auth and state](03-persistent-auth-state.md) (supersedes its
append-based `CLAUDE.md` injection),
[01 — isolation model](01-isolation-model.md),
[04 — YOLO by default](04-yolo-by-default.md)

## Context

[08](08-host-global-settings-import.md) brought the host's `settings.json` into the
box and settled the shape of the answer: mount the specific files, one-way, merge at
startup. But settings are only part of what makes *your* Claude yours. Skills,
the global `CLAUDE.md`, subagent definitions and slash commands all still stopped at
the box's edge, so a box behaved like a stranger's Claude — and the friction landed
exactly where the box is supposed to help: you noticed the missing skill or the
missing house rule mid-task.

The knobs existed (`CLAUDE_SKILLS_DIR`, `CLAUDE_BOX_GLOBAL_MD`) but were opt-in and
each pointed at an arbitrary path, so the common case — "use what is already in my
`~/.claude`" — took explicit setup on every machine.

## Decision

Import the host's `~/.claude` config **by default**, item by item, still never the
directory as a whole (credentials, history and per-project state stay outside the
box — [01](01-isolation-model.md)). The host config dir follows `CLAUDE_CONFIG_DIR`,
as `claude` itself does.

| Item | Mount | Applied by |
|---|---|---|
| `settings.json` / `settings.local.json` | read-only, under `/etc/claude-box/` | merged into the box's copy ([08](08-host-global-settings-import.md)) |
| `skills/` | **read-write**, at `/home/node/.claude/skills` | directly |
| `agents/`, `commands/` | read-only, at the matching paths | directly |
| `CLAUDE.md` | read-only, at `/etc/claude-box/global-CLAUDE.md` | **replaces** the box's copy at startup |

- **Per-item opt-outs** (`CLAUDE_BOX_NO_SETTINGS` / `_NO_SKILLS` / `_NO_AGENTS` /
  `_NO_COMMANDS` / `_NO_GLOBAL_MD`), plus `CLAUDE_BOX_NO_HOST_CONFIG=1` to turn the
  whole family off in one go — the pristine box, for testing the box itself.
- `CLAUDE_SKILLS_DIR` and `CLAUDE_BOX_GLOBAL_MD` keep working as **source
  overrides**, and stay independent of the family switch.
- **`CLAUDE.md` is replaced, not appended.** This reverses the line-by-line
  idempotent append of [03](03-persistent-auth-state.md). Appending never removed
  anything, so a rule deleted on the host kept steering Claude inside the box
  forever — a stale instruction is worse than a lost in-box edit, and "the box says
  exactly what the host file says today" is the property that is actually easy to
  reason about.
- **`skills/` is mounted read-write**, deliberately unlike everything else here.
  Skills are the one part of this config Claude is expected to *write*: generating
  and refining a skill inside the box is the point, and a skill that evaporates with
  the container is not worth writing. So this is an accepted, explicit exception to
  "the box never writes to the host" (see the trade-off below).

## Consequences

### Good

- A box behaves like the Claude you already configured — skills, house rules,
  subagents and slash commands included — with no per-machine setup.
- Instructions cannot go stale: the box's `CLAUDE.md` is the host's file, every
  launch, deletions included.
- Skills written inside the box survive it, and are usable on the host.
- Turning any of it off is one environment variable; the previous fully-isolated
  behaviour is `CLAUDE_BOX_NO_HOST_CONFIG=1`.

### Trade-offs and notes

- **The read-write `skills/` mount is a box → host write channel, and it is on by
  default.** The box runs YOLO ([04](04-yolo-by-default.md)), so anything it writes
  there lands in a directory the *host's* Claude loads — the very hole
  [08](08-host-global-settings-import.md) closed for `settings.json` by mounting it
  read-only. It is opened knowingly, in exchange for skills that persist; it is the
  one place where the box's blast radius reaches the host by design. Mitigations, in
  order of bluntness: point `CLAUDE_SKILLS_DIR` at a scratch directory, or set
  `CLAUDE_BOX_NO_SKILLS=1` / `CLAUDE_BOX_NO_HOST_CONFIG=1`. Reviewing `git diff` in
  the skills directory after a session is the cheap habit that makes it visible.
- **In-box edits to `CLAUDE.md` do not survive a launch** (including `#`-shortcut
  memories written to the global file). Write them on the host, or keep them in the
  project's `CLAUDE.md`, which is in the mounted project and untouched by this.
- **`agents/` and `commands/` are read-only**, so creating a subagent or a slash
  command *inside* the box fails to save. That is the trade for keeping those
  directories out of the write channel above; `CLAUDE_SKILLS_DIR`-style overrides can
  be added later if the need is real.
- **A mounted directory shadows whatever the volume had at that path.** Skills or
  agents created in an earlier box (before this change) are hidden while the host's
  directories are mounted — they are still in the `claude-box-config` volume.
- **More of the host's Claude config is now readable inside the box**, so secrets
  parked in any of these files travel with it — see [SECURITY.md](../../SECURITY.md).
