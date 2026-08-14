# Contributing to claude-box

Thanks for your interest. claude-box is a security tool — its value is that you can
trust it to run an autonomous agent safely — so the bar for changes is a little
specific. This guide is for human contributors; the same conventions, formatted for
the in-repo Claude, live in [`CLAUDE.md`](CLAUDE.md).

**Customizing your own box vs. contributing upstream.** Most customization needs no
code change — prefer the environment variables and build args (see the README's
*Customizing* section), and **fork** the repo if you do need code-level changes for
your own use. This guide is about changes you want to contribute **back upstream**.

## The one hard rule: don't break the security invariants

The box exists to run YOLO (`--dangerously-skip-permissions`) safely. These
invariants are what make that true:

- Non-root (`node`) operation and `--cap-drop=ALL` (only the needed capabilities
  added back).
- Default-deny egress, judged by hostname; destinations are added explicitly.
- Container-in-container is rootless Podman only — no DinD (`--privileged`), no host
  docker socket.
- Intentionally-closed destinations (e.g. AWS APIs) stay closed.

A change that weakens any of these does **not** get merged unless it comes with a
design note explaining the reasoning and an alternative safeguard. The rationale for
each invariant is in [`docs/design/`](docs/design/); read those before proposing a
change that touches them.

## Verifying a change

- **Changed the `Dockerfile`?** Rebuild: `docker build -t claude-box:latest .`
  (use `--build-arg` to pin tool versions or drop optional tools with `WITH_*=0`).
- **Changed anything egress-related?** Verify reachability on **real hardware with
  the firewall enabled**. `init-firewall.sh` self-checks at startup that disallowed
  destinations are blocked and allowed ones are reachable; that self-check must pass.
  CI runs it via `scripts/smoke.sh`; run the same checks by hand with:

  ```sh
  ./scripts/smoke.sh          # build + firewall self-check + non-root/cap checks
  SMOKE_NESTED=1 ./scripts/smoke.sh   # also exercise nested containers
  ```
- **Changed the startup flow?** Keep `claude-box` (host side) and `entrypoint.sh`
  (container side) consistent — a direct `claude-box claude` launch bypasses the
  shell wrapper, so the same injection has to exist in entrypoint too.

## Adding an egress destination

Egress additions get extra scrutiny — each one widens the attack surface. A PR that
adds a destination should:

- Append it to `DOMAINS` in `init-firewall.sh` (the CORE / OPTIONAL split — put it in
  the right group) **with a comment stating its purpose**.
- Explain why it cannot be **baked in at build time** instead (baking avoids runtime
  egress — see [06 — bake tools at build time](docs/design/06-bake-tools-at-build-time.md)),
  and why an already-allowed destination does not suffice.
- Include reachability verification on real hardware with the firewall enabled.

## Commits and pull requests

- Do not commit directly to `main`; work on a branch and open a PR.
- Commit messages: subject says **what**, body says **why** (background, rejected
  alternatives). Append a `Co-Authored-By` trailer when an agent co-authored the work.
- Keep the history legible — the reasoning in commit messages is part of the record.

## Design decisions

When you make or reverse a design choice, add a note under
[`docs/design/`](docs/design/) (Nygard style: context → decision → consequences).
Don't delete older notes; update their status and cross-reference from the new one.

## Language

The public repository's language is **English** — code, comments, design notes,
commit messages, and PR descriptions. The one exception is the README, which is kept
in **both English and Japanese** (`README.md` / `README.ja.md`). If you touch a file
that still has legacy Japanese comments, translating them to English as you go is
welcome.
