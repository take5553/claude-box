# 13 — Share one project's session logs with the host (opt-in)

Related: [03 — persist auth and state in a dedicated volume](03-persistent-auth-state.md)
(**amended**: history no longer *always* stays in the volume),
[11 — read-only by default, and telling claude so it can ask](11-read-only-by-default-and-telling-claude.md),
[08 — importing the host's global settings](08-host-global-settings-import.md),
[12 — env-request replies](12-env-request-replies.md)

## Status

Accepted (2026-11-25). Amends 03.

## Context

The first request to come through the env-request channel for something other than
egress: the user drives the box's Claude through **orca**, a host-side app, and orca
could not show the box's conversation history. The in-box Claude's diagnosis was
right. Per 03, `/home/node/.claude` is the `claude-box-config` volume, so the session
transcripts (`~/.claude/projects/<key>/*.jsonl`) and the auto-memory next to them
(`<key>/memory/`) never reach the host.

The request offered two ways to bring them out:

- **A** — bind-mount the host's own `~/.claude/projects/<key>/` (this project only)
  over the volume's copy.
- **B** — bind-mount a claude-box-only directory (`~/.claude-box/projects/<key>/`)
  and point orca at it.

B was the safer shape, but it does not work with orca as shipped (1.4.274, checked in
its bundled code). orca looks for Claude sessions only under its own
`CLAUDE_CONFIG_DIR` (default `~/.claude`), under `~/.claude`, and under the homes of
the Claude accounts it manages itself (`<orca data>/claude-profiles/<id>/home`). Those
homes are created by orca's sign-in flow, no setting takes a path, and a symlinked home
is skipped. Every place orca reads is a directory that a host-side Claude also uses as
its own config dir. So getting the logs into orca means writing into the host Claude's
config dir, whichever way it is done. The only alternative was a manual export
command, which is not live. The maintainer chose A and accepted the risk.

## Decision

- `CLAUDE_BOX_SESSIONS=rw` bind-mounts `$HOST_CLAUDE_DIR/projects/<key>/` read-write
  at `/home/node/.claude/projects/<key>/`. `<key>` is the project path with every
  non-alphanumeric character replaced by `-`, which is how claude derives it. The
  project is mounted at the same path as on the host, so the key matches. The
  directory is created on the host if it is missing: this is an explicit opt-in, and
  the first box session for a project should land there too.
- **Default `off`.** Without it nothing changes: per 03, transcripts and auto-memory
  stay in the volume.
- **Only `rw` and `off`.** claude has to write its transcript, so a read-only mount
  would break it rather than protect anything. Any other value is a launch failure,
  as with the other mode variables.
- **Its own switch, not part of `CLAUDE_BOX_HOST_CONFIG`.** The family switch is
  about *config*. If `CLAUDE_BOX_HOST_CONFIG=rw` also shared transcripts and memory,
  it would open a second, different write path as a side effect.
- **One project, never `projects/` as a whole.** Other projects' logs, on both the
  host and the volume side, stay out of sight.
- **Keys over 200 characters are refused** with a warning, and the box launches
  unshared. claude shortens such keys with a hash we do not reproduce, so the
  mounted directory would not be the one it uses.
- **`projects/<key>/` is pre-created in the volume, as node.** To make the mount
  point, the engine creates it and any missing parents inside the volume, and
  creates them as root. Tested: in a fresh volume, `projects/` came out `root 755`,
  and the next box for a *different* project could no longer save its transcripts.
  The same would happen to this project if it were launched with sessions `off`
  again. The launcher therefore runs
  `mkdir -p /home/node/.claude/projects/<key>` first, in a throwaway container with
  `--cap-drop=ALL` and `--network none`, as the image's `node` user.
- The mode is passed into `CLAUDE_BOX_MODES`, and the box's system-prompt note
  (design 11) says what `rw` means: the directory *is* the host's, its memory is
  loaded by the host's Claude, and the host's own sessions for the project are
  visible.

## Consequences

### Good

- orca, the host's `claude --resume`, and anything else that reads Claude Code
  sessions see the box's conversations live. In the other direction, `/resume` in the
  box lists the host's sessions for the same project.
- The box keeps one auto-memory per project, shared with the host, instead of two
  that drift apart.

### Trade-offs and notes

- **This is a box → host write path into files the host's Claude loads.** That is
  the class of path 08 and 11 work to keep closed. A YOLO box (04) that is
  prompt-injected can plant text in `<key>/memory/`, which the host's Claude reads
  into context at its next start in this project. It can also forge a transcript,
  which becomes the host Claude's context if the user resumes it. Opt-in, one project
  and a stated note are what keep this tolerable. It is the same kind of trust as
  `CLAUDE_BOX_SETTINGS=rw`. Review `<key>/memory/` the way you review the project
  diff after a YOLO session.
- **The box can read the host's own transcripts for this project.** These can hold
  file contents and command output from host sessions, including sessions that saw
  things the box would not otherwise see.
- **Existing box sessions are shadowed, not migrated.** Whatever the volume already
  held at `projects/<key>/` is hidden while the mount is in place (as with the other
  mounts, design 09). Copy it out by hand if you want it.
- **rw needs matching uids** on Linux (design 10). The launcher's uid warning covers
  this item too, because it is listed in `CLAUDE_BOX_MODES`.
- The orca findings are about one version's bundled code. If orca adds a setting for
  extra Claude session directories, B becomes possible and is the better design:
  reopen this note when that happens.
