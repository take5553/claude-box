# 10 — Host config import modes: `rw` by default, `ro`/`off` per item

> **Defaults reversed by [11](11-read-only-by-default-and-telling-claude.md).** The
> three modes, the per-item variables and `CLAUDE_BOX_HOST_CONFIG` are all as described
> here and still in force. What changed is which one you get by default: `ro` for
> settings, skills, agents, commands and `CLAUDE.md` (with `plugins/` staying `rw`),
> because the permissive default handed every user the box → host write path this
> repository otherwise works to keep closed. Read
> [11](11-read-only-by-default-and-telling-claude.md) for the current defaults and for
> how the box now *tells* claude which variable to ask for.

Related: [09 — importing the host's Claude config](09-import-host-claude-config.md)
(this note replaces its fixed per-item permissions with a mode),
[08 — importing the host's global settings](08-host-global-settings-import.md)
(**amended**: its one-way, read-only import is now the `ro` mode, not the default),
[01 — isolation model](01-isolation-model.md),
[04 — YOLO by default](04-yolo-by-default.md)

## Context

[08](08-host-global-settings-import.md) and [09](09-import-host-claude-config.md)
brought the host's `~/.claude` into the box, but froze one permission per item by
fiat: settings read-only and merged, `skills/` read-write, `agents/` and `commands/`
read-only. In use, those fixed choices were wrong in both directions.

Read-only `agents/` and `commands/` meant a subagent or slash command written in the
box could not be saved — the same objection that made `skills/` read-write, applied
to two directories that behave identically. And read-only settings meant `/config`,
model and effort changes made in the box stayed in the box: you configure the same
thing twice, once per side.

Meanwhile the sharp end — how much the box may write back to the host's Claude
config — was expressed as five independent `CLAUDE_BOX_NO_*` booleans, which can say
"do not bring this in" but cannot say "bring it in, but do not let the box write to
it".

## Decision

Give every imported item the same three-valued **mode**:

| Mode | Meaning |
|---|---|
| `rw` | Share the host's file/directory. What the box writes lands on the host. |
| `ro` | Read-only. Settings are merged into the box's own copy ([08](08-host-global-settings-import.md)); `CLAUDE.md` replaces it ([09](09-import-host-claude-config.md)); directories are mounted `:ro`. The box keeps writing its own state, the host's files are never touched. |
| `off` | Not brought in at all. |

| Item | Variable | Default |
|---|---|---|
| `settings.json`, `settings.local.json` | `CLAUDE_BOX_SETTINGS` | `rw` |
| `skills/` | `CLAUDE_BOX_SKILLS` | `rw` |
| `agents/` | `CLAUDE_BOX_AGENTS` | `rw` |
| `commands/` | `CLAUDE_BOX_COMMANDS` | `rw` |
| `plugins/` | `CLAUDE_BOX_PLUGINS` | `rw` |
| `CLAUDE.md` | `CLAUDE_BOX_GLOBAL_MD_MODE` | `rw` |

- `CLAUDE_BOX_HOST_CONFIG` sets the mode for **every** item at once, and the per-item
  variables override it. The two useful global settings are `off` (a pristine box —
  what the box did before [08](08-host-global-settings-import.md)) and **`ro`**,
  which is the point of having a mode at all: bring the whole config in, and let
  nothing the box does reach the host.
- **`rw` is the default for every item, `CLAUDE.md` included.** An earlier draft kept
  `CLAUDE.md` on `ro` as a safeguard against the box rewriting its own house rules,
  but a single rule with a single exception is harder to hold in your head than a
  single rule — and the exception bought little, since `settings.json` (shared `rw`)
  can carry hooks that do far more than an instruction line. One default, one
  variable per item, documented where people actually look (a dedicated section in
  both READMEs rather than a row in a table), is the safer arrangement in practice.
  On `rw`, `#`-shortcut memories written in the box land on the host as well.
- **`plugins/` is imported too**, and not only for symmetry: which plugins are
  enabled is recorded in `settings.json`, which is already shared, so leaving
  `~/.claude/plugins` behind would tell the box to enable plugins whose marketplaces
  it does not have.
- `CLAUDE_SKILLS_DIR` and `CLAUDE_BOX_GLOBAL_MD` still name a **source**; being
  explicit, they survive `CLAUDE_BOX_HOST_CONFIG=off`, while the per-item mode
  variable still applies to them.
- An unrecognised mode is a **launch failure**, not a silently ignored value: these
  variables decide what the box is allowed to write.

`rw` for settings works because of how `claude` writes files: a temp file plus
`rename`, and — when the rename fails with `EXDEV`/`EPERM`/`EEXIST`/**`EBUSY`** — a
fallback to an in-place truncate-and-write. Renaming onto a bind-mounted *file* is
exactly the `EBUSY` case, so the fallback is the path that keeps `/config` working
against a shared `settings.json`. (Read out of the bundled writer; worth re-checking
whenever this stops behaving.) `ro` remains the escape hatch if a future version
drops that fallback.

## Consequences

### Good

- One box, one configuration: change a setting, write a skill, define a subagent
  inside the box and it is there on the host afterwards — and vice versa.
- The write direction is now a dial, not five booleans:
  `CLAUDE_BOX_HOST_CONFIG=ro` is a single, memorable way to keep a box from touching
  the host's Claude config while still inheriting all of it.
- Per-item modes cover the real cases: share skills but not settings, take settings
  read-only on a machine you do not trust, and so on.

### Trade-offs and notes

- **The default now lets the box write the host's Claude config.** This amends the
  central decision of [08](08-host-global-settings-import.md), which mounted
  settings read-only precisely so a box running YOLO ([04](04-yolo-by-default.md))
  could not plant a `hooks` entry that the *host's* Claude would later execute. That
  path is open by default now, together with `skills/`, `agents/` and `commands/`.
  It is a deliberate trade — the box is the same person's Claude, and a box whose
  configuration work is thrown away every time is the friction this repo exists to
  remove — but it is the one place where the box's blast radius reaches the host, and
  it is chosen, not inherited. `CLAUDE_BOX_HOST_CONFIG=ro` closes it in one flag, and
  because the default is the permissive one, both READMEs carry a dedicated section
  that says so in as many words rather than a table row.
- **Review what comes back.** Keeping `~/.claude` under git (or simply diffing it) is
  the cheap habit that makes the write direction visible; it is the same discipline
  as reviewing the project diff after a YOLO session.
- **`rw` settings hide the merge.** In `rw` mode there is no host-wins merge and no
  box-only keys: the box and the host share one file, so a box-specific setting
  becomes a host setting. Use `ro` when you want the box to keep its own.
- **`rw` shares only files that exist.** Nothing is created on the host, so a box
  cannot start persisting skills into a `~/.claude/skills` that is not there yet —
  create the directory (or point `CLAUDE_SKILLS_DIR` somewhere) first.
- **A mounted directory still shadows the volume's copy** at that path
  ([09](09-import-host-claude-config.md)).
- **Plugins record absolute install paths.** `plugins/known_marketplaces.json` stores
  each marketplace's `installLocation`, and the same directory is
  `/Users/you/.claude/plugins/…` on the host and `/home/node/.claude/plugins/…` in
  the box. Claude Code detects a location outside its own plugins directory and
  rewrites the entry, so each side repairs the file at startup and the plugins
  themselves work — at the cost of that one file changing back and forth.
  `CLAUDE_BOX_PLUGINS=off` avoids the churn.
- **In-box edits to `CLAUDE.md` now reach the host** (`#`-shortcut memories included).
  That is the point of `rw`, but it also means a box can rewrite your house rules —
  `CLAUDE_BOX_GLOBAL_MD_MODE=ro` keeps the old replace-from-the-host behaviour.
