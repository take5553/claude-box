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
  ([10](10-host-config-import-modes.md) briefly made the file shared read-write by
  default; [11](11-read-only-by-default-and-telling-claude.md) put the replace
  behaviour back as the default, with sharing available as
  `CLAUDE_BOX_GLOBAL_MD_MODE=rw`.)
- The default notification channel (`preferredNotifChannel`) is written **only
  when the key is unset**, so a manual change is not overwritten.
- Named items of the host's `~/.claude` are the exception to "nothing from the
  host's `~/.claude`": settings, `skills/`, `agents/`, `commands/`, `plugins/` and
  `CLAUDE.md` are imported on every launch — read-only by default, `plugins/` aside
  ([08](08-host-global-settings-import.md),
  [09](09-import-host-claude-config.md),
  [10](10-host-config-import-modes.md),
  [11](11-read-only-by-default-and-telling-claude.md)). Credentials, history and
  per-project state are not among them and stay in the volume.
  **Amended by [13](13-share-project-sessions.md)**: with the opt-in
  `CLAUDE_BOX_SESSIONS=rw`, the current project's session logs and auto-memory
  (`projects/<key>/`) are the host's own directory instead. They are off by default,
  and other projects and credentials are unaffected.

## Consequences

### Good

- Even with disposable containers, you log in once.
- State is physically separated from the host: credentials, history and session
  state never leave the volume, and the *config* items above do not flow back either
  unless you ask for it ([11](11-read-only-by-default-and-telling-claude.md)).
- Idempotent init is safe to re-run (tolerant of re-execution).

### Trade-offs and notes

- Deleting `claude-box-config` requires a re-login; the credential material is
  concentrated there, so handling that volume *is* handling the credentials.
- "Write only if the key is absent" is good for seeding defaults but will not
  update a default value automatically (needs a manual edit or volume recreation).
