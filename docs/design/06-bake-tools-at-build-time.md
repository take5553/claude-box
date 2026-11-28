# 06 — Bake dev tools in at build time (from official distributions)

Related: [02 — default-deny egress](02-default-deny-egress.md),
[05 — nested containers](05-nested-containers-rootless-podman.md)

## Context

We want one consistent way to install the box's dev tools (Claude Code, `gh`,
`pre-commit`, Go, ...). Two constraints:

1. **Default-deny egress** ([02](02-default-deny-egress.md)). An install method
   that reaches out at runtime widens the allow-list, and the attack surface with
   it.
2. **Debian trixie's pip is PEP 668**, refusing direct system installs; root
   `npm -g` also fails because Claude Code's self-update cannot write to the
   install location.

## Decision

The default is to **bake version-pinned official distributions into the image at
build time**, minimising runtime network dependency and ensuring reproducibility.
The optional tools can each be dropped at build time (`WITH_PODMAN`, `WITH_GO`,
`WITH_PLAYWRIGHT`, all default `1`).

- **Claude Code**: the native installer into `node`'s `~/.local` (not root
  `npm -g`), so self-update can write even as non-root. Only `downloads.claude.ai`
  is allowed.
- **gh**: the GitHub releases binary; version resolved from the releases redirect,
  pinnable with `--build-arg GH_VERSION`.
- **pre-commit**: to dodge PEP 668, a self-contained zipapp (`.pyz`) run by the
  existing `python3` through a shim; `--build-arg PRE_COMMIT_VERSION`.
- **Go toolchain** (`WITH_GO`): the `dl.google.com` tarball, baked in. pre-commit
  then finds the system go, so `language: golang` hooks do not re-download Go —
  **runtime egress narrows to the module proxy only**. `--build-arg GO_VERSION`.
  (See the 2026-11-28 update below: the module proxy alone turned out not to be
  enough for gitleaks.)
- **gitleaks**: the GitHub releases binary, verified against the release's
  checksums file; `--build-arg GITLEAKS_VERSION`. Repos run it from pre-commit as a
  `language: system` hook (`gitleaks git --pre-commit --staged --redact`).
- **Playwright Chromium** (`WITH_PLAYWRIGHT`): baked into `/opt/ms-playwright` and
  referenced via `PLAYWRIGHT_BROWSERS_PATH`, so the distribution CDN
  (`cdn.playwright.dev`) need not be allowed. Chromium only, no firefox/webkit.
  `--build-arg PLAYWRIGHT_VERSION`.
- Every version pin is a `--build-arg`.

## Consequences

### Good

- Build outputs are reproducible and versions can be pinned explicitly.
- Fewer runtime fetch destinations, keeping the egress allow-list narrow (the Go
  bake is the clearest case).
- The PEP 668 / non-root self-update pitfalls are avoided by unifying the method.

### Trade-offs and notes

- Updating a tool generally needs an **image rebuild** (Claude Code's in-place
  self-update is the exception). "latest" resolutions freeze at build time, so pin
  with `--build-arg` when reproducibility matters.
- **Anything whose version must match the user's repo breaks when it drifts.**
  Playwright wants a specific Chromium revision per package version, so bumping
  `@playwright/test` in the repo yields `Executable doesn't exist at
  .../chromium-XXXX/` until the image is rebuilt (which the box's user cannot do).
  We accepted this over keeping a CDN permanently open; if rebuild-waiting becomes
  routine, revisit the method. `WITH_PLAYWRIGHT=0` drops the bake for those who do
  not need browser checks.
- **Baking bloats the image.** Chromium (full + headless shell + ffmpeg) alone is
  ~1 GB, roughly doubling the image; this is the price of not widening runtime
  egress. Dropping unused tools with `WITH_*=0` recovers it.
- Podman / podman-compose are the exception, installed from Debian apt
  ([05](05-nested-containers-rootless-podman.md)) for version alignment.

## Update (2026-11-28): gitleaks baked in as a binary

An env-request from a project that gates commits on gitleaks reported that its
official pre-commit hook (`language: golang`) never builds inside the box. Verified
in a firewalled box: `go install github.com/zricethezav/gitleaks/v8@v8.30.1` fails
because `proxy.golang.org` redirects some module zips to `storage.googleapis.com`,
which is not allowed. The "module proxy only" assumption above holds for some
modules but not for gitleaks' dependency tree.

Decision: bake the gitleaks release binary into the image (checksum-verified), and
have repos switch the hook to `language: system`. Rejected:

- Allowing `storage.googleapis.com` — opens all of Google Cloud Storage.
- Allowing `release-assets.githubusercontent.com` — opens every GitHub release asset
  at runtime.
- An unofficial npm wrapper — reachable, but an unvetted distribution.

`proxy.golang.org` / `sum.golang.org` stay allowed for `go install` of modules that
do not redirect; a golang hook whose dependencies do redirect should get the same
treatment as gitleaks (bake the binary) rather than a wider allow-list.
