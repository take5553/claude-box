# 12 — env-request replies: a read-only return channel

Related: [07 — env-request as a local file drop](07-env-request-file-drop.md),
[01 — isolation model](01-isolation-model.md)

## Status

Accepted (2026-11-22). Extends 07.

## Context

07 made env-request a one-way file drop: the in-box Claude writes a request into the
outbox, the maintainer reviews it on the host. The first real batch (an egress request
for GitHub Actions logs, and one for Playwright browser downloads) showed the missing
half: once the maintainer decided, the outcome — "approved, takes effect in a new box",
"declined, but the baked browser was bumped to 1.65.1, you may unpin" — had to be
relayed to the in-box Claude by the human, in their own words. The human does not want
to carry those details; they want to say "the request was handled, check the reply"
and nothing more.

## Decision

Add a **reply folder**, separate from the outbox and mounted **read-only**.

- Host `~/.claude-box/replies` (relocate with `CLAUDE_BOX_REPLY_DIR`) is mounted at
  `/home/node/.claude-box/replies:ro`; the container sees `CLAUDE_BOX_REPLY_DIR`. It is
  on whenever the outbox is, and off with `CLAUDE_BOX_NO_REQUEST_DIR=1`.
- A reply is a Markdown file named after the request it answers, with front matter
  (`request`, `project`, `status`, `date`) and a body: decision, what changed, what to
  do next. Format in [env-request-operations](../env-request-operations.md#replying-maintainer--the-claude-inside-the-box).
- The `env-request` skill learns to read replies when the user says a request was
  handled: it selects files whose `project:` equals its working directory, acts within
  the project, and checks that box-level changes are actually live (asking for a
  restart if not).
- The launcher refuses a reply folder that contains, or is contained in, the outbox.

### Why read-only, and why not the outbox

The outbox is read-write and **shared by every box** on the host, whatever project it
runs. If replies lived there, any box — including one that has been prompt-injected —
could write a file that looks like the maintainer's reply, and another project's Claude
would read it as the maintainer's decision. A read-only mount makes the maintainer on
the host the only possible writer, which is the property that lets the in-box Claude
treat a reply as coming from the maintainer at all. `--cap-drop=ALL` leaves the box no
way to remount it. The overlap check exists because a reply folder nested inside the
outbox would be writable through the outbox mount, silently voiding the `:ro`.

## Rejected alternatives

- **Replies in the outbox (e.g. `requests/replies/`)**: simplest, but forgeable across
  boxes, as above.
- **Per-project reply folders** (mount only `replies/<project>`): would also stop one
  project's box from *reading* another's replies. Not worth the naming scheme and host
  bookkeeping for now: replies are about the box's environment, not project secrets,
  and the operations doc tells the maintainer to keep them that way. Revisit if replies
  start carrying project-specific detail.
- **Injecting the reply into the system prompt at startup** (like design 11's note):
  only reaches boxes started after the reply, and the human would still have to restart
  to deliver it. Reading on demand works for a running box too.

## Consequences

### Good

- The human's whole message can be "要望が対応されました。返答を確認してください".
- The reply is attributable: the box cannot have written it.
- Adds no egress and no write access to the host.

### Trade-offs and notes

- One more host mount, read-only and initially empty.
- Every box can read every reply. Keep replies to environment decisions.
- The box cannot mark a reply as read (read-only); the skill relies on conversation
  context and the maintainer can move old replies to a `done/` subfolder.
