---
name: env-request
description: File a change request for the claude-box environment (an egress allow-list entry, an extra tool, a capability, a mount, ...) as a Markdown file in the request outbox, for the box maintainer to review. Use ONLY when the user explicitly asks to raise a request with the maintainer (e.g. "go ahead and raise this with the maintainer"). Do not use it without an explicit signal.
---

# Filing an environment request

This box (claude-box) runs with default-deny egress, non-root, and least privilege
(see `docs/design/` in the box's repository for why). When, while working, you want
to change this box's environment — add an egress destination, install a tool, add a
capability or a mount — this skill raises that as a request for the **box maintainer**.

The request is written as a Markdown file into a mounted **outbox**
(`CLAUDE_BOX_REQUEST_DIR`); there is no GitHub and no network involved. If no outbox
is mounted, filing fails with an error. The maintainer reviews the file on the host
and decides whether to make the change — nothing is applied automatically.

## When to use it (important)

- Run this only when the user **explicitly** asks to file a request (e.g. "go ahead
  and raise this with the maintainer").
- Without such a signal, **do not file on your own**. If a request seems warranted,
  at most ask "Shall I raise this with the maintainer?".
- Only write the request file. Do not push, open PRs, or otherwise try to act on the
  box yourself.

## Steps

1. From the current conversation, compose the request as Markdown using this template:

   ```markdown
   ## Background / why it's needed
   (which task got stuck on what, and why this change is required)

   ## Concrete change requested
   Kind: egress destination / tool / capability / mount / other
   (e.g. add `example.com:443` to the egress allow-list; the purpose is ...)

   ## Impact / expected risk (self-declared)
   (what this loosens; for an egress addition, "where it goes out to and why")

   ## Alternatives considered
   (can it be baked in at build time? can an already-allowed destination do?)
   ```

2. Pipe the composed body into the CLI on stdin:

   ```sh
   printf '%s' "$body" | claude-box-request --title "<kind>: <one-line summary>"
   ```

   Make the subject a kind prefix plus a one-line summary — e.g. `egress: allow
   example.com` — so the reviewer can tell requests apart at a glance.

3. Report the written file path (printed by the CLI) to the user.

## Mindset

- What you write here is **your (the requester's) case**, not an approval. Don't
  exaggerate; state the need, the impact, and the alternatives honestly. The
  maintainer does the review.
- If "bake it in at build time so runtime egress does not grow" would do instead of
  "add an egress destination", note that as an alternative — the box leans that way.
