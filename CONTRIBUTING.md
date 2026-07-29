# Contributing

Thanks for working on this repo. Start with [`README.md`](README.md) for
what this project is, and [`docs/QUICKSTART.md`](docs/QUICKSTART.md) to get
a cluster running end to end. This doc covers the contributor workflow:
environment setup, branching, commit conventions, versioning, and the
shift-left checks that run before code lands.

## Local environment setup

```bash
make install
```

This is the one command a new contributor needs: it pins the CLI binaries
this repo depends on (`terraform`, `packer`, `trivy`, `tflint`,
`terraform-docs`, `sops`) into `~/bin`, approves the `.envrc` files at the
repo root and in `packer/`, `terraform/`, `ansible/` (direnv), installs the
pre-commit git hooks (see below), and creates the Python virtualenv
(`.venv/`) Ansible runs from, installing Ansible itself plus its required
collections.

Deliberately out of scope for `make install` — install these yourself via
your OS package manager: `pre-commit`, `checkov`, `direnv`, `age`.

Run `make help` to see every available target; `make debug` shows what's
currently installed and detected.

## Shift-left feedback: pre-commit

`make install` runs `make pre-commit-install`, which registers the git hooks
(both the `pre-commit` and `commit-msg` stages) for you — nothing extra to
do per clone as long as the `pre-commit` binary itself is already installed
(via your OS package manager). To (re-)run it standalone:

```bash
make pre-commit-install
```

From then on, `git commit` runs the checks in [`.pre-commit-config.yaml`](.pre-commit-config.yaml)
automatically. You can also run everything on demand:

```bash
pre-commit run --all-files
```

What runs:
- **General file hygiene** — end-of-file-fixer, trailing-whitespace,
  detect-private-key, check-merge-conflict, no-commit-to-branch (blocks
  direct commits to `main`/`master`).
- **Packer** (files under `packer/`) — `packer fmt -check` and
  `packer validate -syntax-only` against each template directory. These are
  local hooks that shell out to the `packer` binary directly (no maintained
  community pre-commit repo exists for Packer HCL); `-syntax-only` is used
  because full validation needs the real Proxmox variables, which aren't
  available in every contributor's environment.
- **Terraform** (files under `terraform/`) — `terraform fmt`,
  `terraform validate`, `terraform-docs` (keeps `terraform/README.md`'s
  generated table in sync), TFLint, Trivy, and Checkov, using the configs at
  the repo root (`.tflint.hcl`, `.trivy.yaml`, `.trivyignore`,
  `checkov.yaml`).
- **Commit messages** — commitlint, at the `commit-msg` stage, checking
  against Conventional Commits (see below).

Catching formatting/lint/policy issues here, before a PR even opens, is the
whole point — it's cheaper to fix locally than in CI review.

## Branching strategy

- `main` is the stable branch — always deployable, the base for PRs.
- Day-to-day work happens on short-lived `feature/*` (new capability) or
  `fix/*` (bug fix) branches, opened as a PR against `main`.
- `release/*` branches, if used, cut a release candidate ahead of merging to
  `main`.

This matches the `branches` config in [`.releaserc.js`](.releaserc.js):
commits merged to `main` produce a real release; commits on `release/*`
produce an `rc` prerelease; commits on `feature/*`/`fix/*` produce a
prerelease tagged with the branch name — so you can see what a change would
version as before it merges.

## Commit messages (Conventional Commits)

Commit messages are linted by commitlint
([`commitlint.config.js`](commitlint.config.js)) against
[Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(optional scope): <subject>
```

Allowed types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`,
`build`, `ci`, `chore`, `revert`. Most rules are warning-level rather than
hard failures (see `commitlint.config.js` for the exact rule levels) — but
write real Conventional Commits anyway, since **the commit type is what
drives the version bump** (see Versioning below).

Wire up the repo's commit template once, so `git commit` (no `-m`) opens
with the format and examples pre-filled:

```bash
git config commit.template .gitmessage
```

## Versioning & releases

This repo uses [semantic-release](https://semantic-release.gitbook.io/)
to compute the next version from commit history and cut a release — no
manual version bumps.

- `fix:` commits -> patch release
- `feat:` commits -> minor release
- A `BREAKING CHANGE:` footer (any type) -> major release
- `docs:`, `chore:`, `style:`, etc. -> no release by themselves

On release, semantic-release ([`.releaserc.js`](.releaserc.js)):
1. Analyzes commits since the last release (`commit-analyzer`).
2. Generates release notes (`release-notes-generator`).
3. Updates [`CHANGELOG.md`](CHANGELOG.md) (`changelog`).
4. Publishes a GitHub Release (`github`).
5. Commits the changelog back to the branch (`git`), with
   `[skip ci]` in the message.

There's no CI workflow wired up yet to run this automatically on merge —
for now, run it locally to preview what a release would look like:

```bash
npx semantic-release --dry-run
```

Wiring `npx semantic-release` into a GitHub Actions workflow on `main` is
tracked as follow-up work.

## Pull requests

- Keep PRs scoped to one logical change; commit messages inside the PR still
  matter (semantic-release reads the merge commit / squash message, not the
  PR title, depending on repo merge settings).
- `terraform validate` and `packer validate`/`packer fmt` should pass before
  requesting review — both run in pre-commit for Terraform, and are safe,
  read-only commands to run by hand for Packer.
- Actual `terraform apply` / `packer build` / `ansible-playbook` runs against
  real infrastructure are not part of pre-commit or this contributing flow —
  see the tool-specific docs under `docs/` for how those are run and gated.
