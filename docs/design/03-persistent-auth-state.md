# 03 — Persist auth and state in a dedicated volume

Related: [01 — isolation model](01-isolation-model.md),
[08 — importing the host's global settings](08-host-global-settings-import.md),
[09 — importing the host's Claude config](09-import-host-claude-config.md)

## Context

Containers are disposable (`--rm`) and relaunched per project
([01](01-isolation-model.md)). Vanilla Claude Code writes account/onboarding state
to `~/.claude.json` and settings to `~/.claude`; by default these land outside any
volume, so recreating the container **forces a re-login every time**. Sharing the
host's `~/.claude` directly would instead break isolation and mix the box's state
with the host Claude's.

## Decision

- Set `CLAUDE_CONFIG_DIR=/home/node/.claude` so all settings, state and
  credentials live in one place (`Dockerfile`).
- Mount a **dedicated named volume** (`claude-box-config`), separate from the
  host's `~/.claude`, there (`claude-box`). Auth persists across container
  recreation.
- ~~The idempotent "append the line if absent" mechanism for the global `CLAUDE.md`
  is kept, but it is **opt-in**: nothing is injected by default. A file supplied
  via `CLAUDE_BOX_GLOBAL_MD` is merged line by line — recreating the volume
  restores it, and repeated launches never duplicate.~~
  **Superseded by [09](09-import-host-claude-config.md)**: the global `CLAUDE.md` is
  now imported by default (from the host's `~/.claude/CLAUDE.md`, or the file named
  by `CLAUDE_BOX_GLOBAL_MD`) and **replaces** the box's copy instead of being
  appended to it, so a rule deleted on the host no longer lingers in the box.
- The default notification channel (`preferredNotifChannel`) is written **only
  when the key is unset**, so a manual change is not overwritten.
- The host's global `settings.json` / `settings.local.json` are the one exception to
  "nothing from the host's `~/.claude`": they are imported **one-way** — mounted
  read-only and merged into the box's own settings on every launch
  ([08](08-host-global-settings-import.md)).

## Consequences

### Good

- Even with disposable containers, you log in once.
- State is physically separated from the host; box settings do not leak into the
  host Claude (the settings import is read-only and host → box only).
- Idempotent init is safe to re-run (tolerant of re-execution).

### Trade-offs and notes

- Deleting `claude-box-config` requires a re-login; the credential material is
  concentrated there, so handling that volume *is* handling the credentials.
- "Write only if the key is absent" is good for seeding defaults but will not
  update a default value automatically (needs a manual edit or volume recreation).
