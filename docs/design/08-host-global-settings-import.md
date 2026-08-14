# 08 — Import the host's global settings one-way (read-only → merge)

Related: [03 — persistent auth and state](03-persistent-auth-state.md),
[01 — isolation model](01-isolation-model.md),
[04 — YOLO by default](04-yolo-by-default.md)

## Context

The box keeps its Claude Code state in a dedicated volume, deliberately separate
from the host's `~/.claude` ([03](03-persistent-auth-state.md)). That separation is
right for credentials and history, but it also means the settings you have tuned on
the host — model, effort level, `statusLine`, `permissions`, `hooks` — simply do not
exist inside the box. You reconfigure every box by hand, and lose it again whenever
the volume is recreated.

Sharing the host's `~/.claude` directly is not an option:

- It breaks the minimal-mount rule ([01](01-isolation-model.md)) — credentials,
  history and every project's state would enter the box.
- It opens the **box → host** direction. The box runs YOLO
  ([04](04-yolo-by-default.md)), so a writable host `settings.json` would let it
  plant a `hooks` entry that the *host's* Claude Code then executes, outside the
  box. That is an escape hatch dressed up as a config file.

So the question is narrower: how do we get *just the settings* in, without ever
letting anything out?

## Decision

- **Mount only the two settings files, read-only.** `claude-box` mounts
  `settings.json` and `settings.local.json` from the host's config dir
  (`CLAUDE_CONFIG_DIR`, else `~/.claude`) at
  `/etc/claude-box/host-settings{,.local}.json`, `:ro`. They are *not* mounted over
  the box's own `~/.claude`, so the box keeps a writable settings file of its own —
  `claude` writes there (theme, effort level, …) and a read-only mount would make
  those writes fail.
- **Merge on every launch, host keys win.** `entrypoint.sh` merges each file into
  the box's counterpart with jq's recursive `*`. Keys the box set on its own survive;
  keys present on the host overwrite; arrays (`permissions.allow`, …) are taken from
  the host wholesale. Editing the host file takes effect on the next start, and
  recreating the volume restores the settings — the same "idempotent init" property
  as the global `CLAUDE.md` merge in [03](03-persistent-auth-state.md).
- **On by default, opt out with `CLAUDE_BOX_NO_SETTINGS=1`**, following `~/.gitconfig`
  ([01](01-isolation-model.md)): an existing host config file is brought in read-only
  when it is there, and one flag turns it off. This differs from `CLAUDE_BOX_GLOBAL_MD`,
  which stays opt-in — that one *authors instructions* for Claude, while these are the
  same user's own Claude Code configuration on the same machine, and the failure mode
  is a broken hook, not a surprise instruction.
- **A malformed host file is skipped with a warning**, never fatal: a typo in
  `settings.json` must not make the box unlaunchable.

## Consequences

### Good

- Your settings follow you into the box, and survive recreating the volume.
- The host's files are only ever read. Nothing the in-box Claude writes to its
  settings can reach the host — the direction that would matter is closed at the
  mount, not by convention.
- Only two files enter, not `~/.claude` — the minimal-mount rule still holds.

### Trade-offs and notes

- **Host-only settings can break inside the box.** `hooks`, `statusLine` and
  `apiKeyHelper` may invoke commands or paths that exist only on the host. This is
  the same class of problem as a `~/.gitconfig` with `credential.helper=osxkeychain`,
  and has the same remedy: `CLAUDE_BOX_NO_SETTINGS=1`, or move the host-specific bits
  out of the global file.
- **Deletions do not propagate.** A merge only adds and overwrites, so a key removed
  on the host lingers in the box until it is edited out there (or the volume is
  recreated).
- **Secrets in settings travel too.** An `env` block or an `apiKeyHelper` in the
  global settings is now readable inside the box. The box is egress-restricted, not
  a vault — see [SECURITY.md](../../SECURITY.md).
- **`settings.local.json` is carried in, but current Claude Code does not read it at
  user scope.** As of 2.1.x the user scope resolves to `settings.json` alone;
  `settings.local.json` is a project-scoped (gitignored) file. It is imported anyway,
  so a host that keeps one — or a future version that reads it — needs no change here.
