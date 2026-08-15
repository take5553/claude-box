# 11 — Read-only by default, and telling claude so it can ask

Related: [10 — host config import modes](10-host-config-import-modes.md)
(**reverses its defaults**, keeps its machinery),
[09 — importing the host's Claude config](09-import-host-claude-config.md),
[08 — importing the host's global settings](08-host-global-settings-import.md),
[04 — YOLO by default](04-yolo-by-default.md)

## Context

[10](10-host-config-import-modes.md) gave every imported item an `rw`/`ro`/`off` mode
and made `rw` the uniform default, so a box shared the host's `~/.claude` outright.
That is convenient, and it is also the escape path [08](08-host-global-settings-import.md)
was written to close: the box runs YOLO ([04](04-yolo-by-default.md)), and the host's
Claude Code later loads the very files the box can write — a hook in `settings.json`,
a skill in `skills/`. Defaulting to it means every user takes that risk, including the
ones who never wanted the box to change anything on their machine.

But plain `off` is not the alternative: what makes the box usable is that your config
is *there*. `ro` already gives that — settings, skills, subagents, commands and house
rules all present — and only withholds the write direction, which is the rarer need.

The reason `rw` looked necessary was discovery: if a box cannot save a skill, how does
anyone learn that a variable would let it? By being told. The box knows its own modes;
it can hand them to claude, which is in the conversation anyway at the moment the
question arises.

One wrinkle makes "let claude notice the error" insufficient on its own. `ro` fails in
two different ways:

- `skills/`, `agents/`, `commands/` are read-only mounts — a write fails with `EROFS`,
  loudly.
- `settings.json` and `CLAUDE.md` are *copies* in the box's own volume
  ([08](08-host-global-settings-import.md), [09](09-import-host-claude-config.md)) —
  a write **succeeds** and simply never reaches the host, then disappears with the
  container. Nothing surfaces at all.

The second is the one that burns you, so the box has to say the quiet part up front
rather than wait for an error.

## Decision

- **`ro` is the default** for `settings.json` / `settings.local.json`, `skills/`,
  `agents/`, `commands/` and `CLAUDE.md`. Everything is imported; nothing the box does
  reaches the host. `rw` per item, or `CLAUDE_BOX_HOST_CONFIG=rw` for all of it, is how
  you opt in — the mode machinery from [10](10-host-config-import-modes.md) is
  unchanged, only its defaults are.
- **`plugins/` stays `rw`.** Three reasons, in order of weight: a plugin the host has
  enabled — a published security plugin, say — silently not working inside the box is
  the failure mode we least want; which plugins are enabled is recorded in
  `settings.json`, which is imported, so the box would be told to enable plugins whose
  marketplaces it does not have; and claude *writes* into this directory as a matter of
  course (repairing the absolute `installLocation` paths in `known_marketplaces.json`,
  migrating `installed_plugins.json`), so `ro` would produce errors on every launch
  instead of a signal at the moment of a real change. `CLAUDE_BOX_PLUGINS=ro` / `off`
  for anyone who weighs it differently.
- **The box tells claude how it was launched.** `claude-box` passes the resolved modes
  in as `CLAUDE_BOX_MODES`; `entrypoint.sh` renders them into a note and appends it to
  claude's system prompt (`--append-system-prompt`, injected in both launch paths
  exactly like `--plugin-dir`, behind the same "does this version support the flag"
  guard). The note states each mode, explains that `ro` fails *silently* for settings
  and `CLAUDE.md`, and says what to do: do not work around it, do not report the change
  as done, name the variable that would allow it — and remember a per-project
  `.claude/` inside the mounted project is writable anyway.
- **That guidance does not go into the user's `CLAUDE.md`.** Merging the box's notes
  into the imported instructions was the obvious-looking alternative and is wrong: in
  `rw` mode that file *is* the host's file, so the box would be writing its own text
  onto the user's machine — precisely what the read-only default exists to prevent. The
  system prompt is box-owned, mode-independent, and leaves the user's instructions
  untouched.

## Consequences

### Good

- The safe posture is the one you get without reading any documentation, and the
  permissive one is a decision you make with the reason in front of you.
- A first launch still feels like "my Claude is here" — nothing is missing, and the
  security plugin the host enabled runs in the box.
- The box argues its own case: the escalation path is offered at the moment it matters,
  in the words of the variable you need, instead of living only in a README section.
- The host's `CLAUDE.md` never gains a line the user did not write.

### Trade-offs and notes

- **For settings and `CLAUDE.md`, `ro` is enforced by a copy, not by permissions.**
  Nothing stops the in-box claude from "successfully" editing them; the note is what
  keeps that from being reported as a durable change. It is guidance, not a guarantee —
  if a session ignores it, the loss is silent. Making those two read-only mounts as
  well would turn the silence into errors, at the cost of claude failing to write
  settings it legitimately owns (theme, effort level) on every launch; that trade was
  refused, but it is the obvious lever if the guidance turns out not to hold.
- **`skills/` read-only means no user-scope skill can be created in the box.** A
  project-scoped `.claude/skills/` still works and is usually the better home; the note
  says so.
- **`plugins/` remains a box → host write channel**, and it is now the only one on by
  default. Reviewing `~/.claude/plugins` (keeping it under version control) is the
  cheap habit that makes it visible.
- **The note costs tokens in every session** and depends on a flag that could change;
  the version guard degrades to "no note" rather than a failed launch, which would then
  be a silent loss of the very guidance this note is about.
- **Changing a mode needs a relaunch.** The note says so, so claude proposes the change
  before doing work that would be thrown away rather than after.
