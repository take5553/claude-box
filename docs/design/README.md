# Design notes

This directory records the design decisions behind claude-box
(context → decision → consequences, in the style of
[Michael Nygard's ADRs](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions.html)).

Unlike a changelog, these describe the **current** design and the reasoning that
makes it trustworthy — what the box protects, and what it deliberately leaves
closed. This matters because claude-box's whole claim is "run YOLO safely"; you can
only believe that once you can read what is guarded and what is intentionally not
opened.

When a decision changes, update the relevant note (and add a new one if the change
is large enough to stand on its own).

| # | Title |
|---|---|
| [01](01-isolation-model.md) | Isolation model (non-root, `cap-drop=ALL`, minimal mounts) |
| [02](02-default-deny-egress.md) | Default-deny egress, decided by hostname |
| [03](03-persistent-auth-state.md) | Persist auth and state in a dedicated volume |
| [04](04-yolo-by-default.md) | Run `claude` in YOLO by default |
| [05](05-nested-containers-rootless-podman.md) | Nested containers via rootless Podman (no DinD) |
| [06](06-bake-tools-at-build-time.md) | Bake dev tools in at build time |
| [07](07-env-request-file-drop.md) | env-request as a local file drop (optional) |
| [08](08-host-global-settings-import.md) | Import the host's global settings one-way (read-only → merge) |
| [09](09-import-host-claude-config.md) | Import the host's Claude config by default (skills, instructions, agents, commands) |
| [10](10-host-config-import-modes.md) | Host config import modes: `rw` by default, `ro`/`off` per item |
| [11](11-read-only-by-default-and-telling-claude.md) | Read-only by default, and telling claude so it can ask |
| [12](12-env-request-replies.md) | env-request replies: a read-only return channel |
