# repo-audits

Utility repository for auditing [waldronlab](https://github.com/waldronlab)
R / Bioconductor packages.  It contains three GitHub Actions workflows that can
be triggered manually against any repository in the organisation.

## Audits

### 1. Audit Single Repo Funding (`audit-single-repo-funding.yml`)

Checks a single target repository and opens a pull request against its `devel`
branch when grant-funder entries are missing from `Authors@R` in `DESCRIPTION`.

#### Eligibility checks (a repo is skipped when …)

| Condition | Action |
|-----------|--------|
| Not in `waldronlab` | Error |
| Is a fork | Skip |
| Is archived | Skip |
| Has no `devel` branch | Skip |
| No `DESCRIPTION` at repo root on `devel` | Skip (not an R package) |
| `DESCRIPTION` has no `Authors@R` field | Skip (manual review needed) |
| No recognised grant topics | Skip |

#### Grant number topics

Grant numbers are stored as plain **repository topics** (no prefix).
Example: a repo funded by `U24HG010263` should have the topic `u24hg010263`.

Recognised formats (case-insensitive):

```
U24<institute><digits>   e.g. u24hg010263
R01<institute><digits>   e.g. r01hg012345
```

The 2-letter NIH institute code (characters 4–5 of the grant number) is
looked up in [`scripts/nih_institutes.json`](scripts/nih_institutes.json) to
produce the agency name used in `Authors@R`.  The special case `HG` maps to
`"NHGRI AnVIL Project"` to match existing usage; all other codes use the
institute acronym (e.g. `CA` → `"NCI"`).

#### What gets added to `DESCRIPTION`

For each unrecognised grant a `person()` entry with role `"fnd"` is **appended**
to the end of the `Authors@R` vector:

```r
person("NHGRI", role = "fnd",
    comment = c(GrantNo. = "U24HG010263"))
```

Existing `fnd` entries whose `GrantNo.` already matches the topic are left
untouched.  Entries with a *different* `GrantNo.` are not overwritten; the new
entry is simply appended alongside them.

#### Running the workflow

1. Go to **Actions → Audit Single Repo Funding** in this repository.
2. Click **Run workflow**.
3. Fill in the inputs:
   - **`repo`** *(required)* – repository name within `waldronlab`,
     e.g. `MultiAssayExperiment`.
   - **`dry_run`** *(optional, default `false`)* – when `true`, the workflow
     performs all checks and logs what would change, but does **not** push any
     branch or open a PR.

#### Adding or updating NIH institute mappings

Edit [`scripts/nih_institutes.json`](scripts/nih_institutes.json).
Keys are the 2-letter institute code (uppercase); values are the string used
as the `given` argument to `person()` in `Authors@R`.

```json
{
  "HG": "NHGRI AnVIL Project",
  "CA": "NCI",
  ...
}
```

---

### 2. Migrate pr_check.yml to ci.yml (`migrate-pr-check-to-ci.yml`)

Replaces a repository's inline `.github/workflows/pr_check.yml` with a thin
`.github/workflows/ci.yml` wrapper that delegates to the shared reusable
workflow in [waldronlab/.github](https://github.com/waldronlab/.github).
Centralising CI logic means future fixes and improvements only need to be made
in one place.

#### What the migration does

- **Adds** `.github/workflows/ci.yml` – calls the
  `waldronlab/.github` reusable `bioc-pr-cmdcheck-pkgdown` workflow.
- **Removes** `.github/workflows/pr_check.yml`.
- Opens a pull request against the target branch (default: `devel`).

#### Eligibility checks (a repo is skipped when …)

| Condition | Action |
|-----------|--------|
| Not in `waldronlab` | Error |
| Is a fork | Skip |
| Is archived | Skip |
| Target branch not found | Skip |
| `pr_check.yml` not present on target branch | Skip |
| `ci.yml` already present on target branch | Skip |
| Migration PR already open | Skip |

#### Running the workflow

1. Go to **Actions → Migrate pr_check.yml to ci.yml** in this repository.
2. Click **Run workflow**.
3. Fill in the inputs:
   - **`repo`** *(required)* – repository name within `waldronlab`,
     e.g. `MultiAssayExperiment`.
   - **`branch`** *(optional, default `devel`)* – target branch to migrate,
     e.g. `devel` or `RELEASE_3_22`.
   - **`dry_run`** *(optional, default `false`)* – when `true`, the workflow
     performs all checks and logs what would happen, but does **not** push any
     branch or open a PR.

---

### 3. Add ci.yml to new package (`add-ci-to-new-package.yml`)

Adds a `.github/workflows/ci.yml` wrapper to a repository that does not yet
have one.  The generated `ci.yml` delegates to the shared reusable workflow in
[waldronlab/.github](https://github.com/waldronlab/.github) and is
customisable via the `with:` block inputs described below.

#### What the workflow does

- **Adds** `.github/workflows/ci.yml` – calls the
  `waldronlab/.github` reusable `bioc-pr-cmdcheck-pkgdown` workflow with
  the parameters specified at dispatch time.
- Opens a pull request against the target branch (default: `devel`).

#### Eligibility checks (a repo is skipped when …)

| Condition | Action |
|-----------|--------|
| Not in `waldronlab` | Error |
| Is a fork | Skip |
| Is archived | Skip |
| Target branch not found | Skip |
| `ci.yml` already present on target branch | Skip |
| Add-ci PR already open | Skip |

#### Running the workflow

1. Go to **Actions → Add ci.yml to new package** in this repository.
2. Click **Run workflow**.
3. Fill in the inputs:
   - **`repo`** *(required)* – repository name within `waldronlab`,
     e.g. `MultiAssayExperiment`.
   - **`branch`** *(optional, default `devel`)* – target branch to add
     `ci.yml` to, e.g. `devel` or `RELEASE_3_22`.
   - **`workflow_version`** *(optional, default `devel`)* – the `@<version>`
     suffix used in the `uses:` line of the generated `ci.yml`
     (e.g. `devel`, `v1`).
   - **`enable_pkgdown`** *(optional, default `true`)* – build and deploy a
     pkgdown site on `RELEASE_*` branch pushes.
   - **`enable_docker`** *(optional, default `true`)* – build and push a
     Docker image on `devel` pushes (requires a Dockerfile).
   - **`dockerfile_path`** *(optional, default `inst/docker/pkg/Dockerfile`)*
     – path to the Dockerfile, relative to the repository root.
   - **`cran`** *(optional)* – CRAN-like repository URL used to install
     packages.  Leave blank to use the reusable workflow default
     (`https://p3m.dev/cran/__linux__/noble/latest`).
   - **`dry_run`** *(optional, default `false`)* – when `true`, the workflow
     performs all checks and logs what would happen, but does **not** push any
     branch or open a PR.

---

## `scripts/ci.yml` — the ci.yml template

`scripts/ci.yml` is the canonical template that the **Migrate pr_check.yml to
ci.yml** workflow copies verbatim into target repositories.  The **Add ci.yml
to new package** workflow generates its `ci.yml` dynamically from the dispatch
inputs, but produces a file with the same structure.

```yaml
name: PR CMD check & build site

on:
  pull_request:
  push:
    paths:
      - 'DESCRIPTION'
      - '**.yml'
    branches:
      - devel
      - 'RELEASE_*'

jobs:
  ci:
    uses: waldronlab/.github/.github/workflows/bioc-pr-cmdcheck-pkgdown.yml@devel
    with:
      enable_pkgdown: true
      enable_docker: true
      dockerfile_path: inst/docker/pkg/Dockerfile
    secrets: inherit
    permissions:
      contents: write
      pages: write
      id-token: write
```

### Customisable `with:` parameters

| Parameter | Default | Description |
|---|---|---|
| `enable_pkgdown` | `true` | Build and deploy a pkgdown site on `RELEASE_*` branch pushes |
| `enable_docker` | `true` | Build and push a Docker image on `devel` pushes (requires a Dockerfile) |
| `dockerfile_path` | `inst/docker/pkg/Dockerfile` | Path to the Dockerfile, relative to the repository root |
| `cran` | *(workflow default)* | CRAN-like repository URL used to install packages |

Edit these values directly in the target repository's `.github/workflows/ci.yml`
after the PR is merged, or supply them as dispatch inputs when running the
**Add ci.yml to new package** workflow.

---

## Required secret

All three workflows use a secret named **`AUDIT_PAT`** – a GitHub
[Personal Access Token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
(classic) with at least the **`repo`** scope, stored in the `waldronlab/repo-audits`
repository secrets (or organisation secrets).

The token must have write access to the target repositories in `waldronlab` so
it can create branches, commit, and open pull requests.

> **Tip:** A [GitHub App](https://docs.github.com/en/apps) token with
> `contents: write` and `pull-requests: write` permissions installed on the
> `waldronlab` organisation is the preferred long-term alternative to a PAT.

## Repository layout

```
.github/
  workflows/
    audit-single-repo-funding.yml   # Audit 1: add missing fnd entries to DESCRIPTION
    migrate-pr-check-to-ci.yml      # Audit 2: replace pr_check.yml with ci.yml wrapper
    add-ci-to-new-package.yml       # Audit 3: add ci.yml to repos that don't have it yet
scripts/
  audit_single_repo.R               # R script: parses/updates Authors@R
  ci.yml                            # ci.yml template copied to target repos (Audit 2)
  add-ci-pr-body.md                 # PR body template for the add-ci audit
  migrate-pr-check-pr-body.md       # PR body template for the migration audit
  nih_institutes.json               # NIH institute code → agency name map
README.md
```

