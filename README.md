# repo-audits

Utility repository for auditing [waldronlab](https://github.com/waldronlab)
R / Bioconductor packages.  It contains two GitHub Actions workflows that can
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

### 3. Security Audit (`security-audit.yml`)

Checks a single target repository for missing security infrastructure and
opens a pull request to add whatever is absent.  It also enables GitHub's
built-in security features for the repository via the API.

#### What the audit checks

| File / setting | Action when absent |
|----------------|--------------------|
| `SECURITY.md` | Added via PR |
| `.github/dependabot.yml` | Added via PR |
| Dependabot vulnerability alerts | Enabled via GitHub API |
| Automated security fixes (Dependabot PRs) | Enabled via GitHub API |

#### Eligibility checks (a repo is skipped when …)

| Condition | Action |
|-----------|--------|
| Not in `waldronlab` | Error |
| Is a fork | Skip |
| Is archived | Skip |
| Target branch not found | Skip |

#### What gets added

- **`SECURITY.md`** – Security-disclosure policy based on
  [`scripts/SECURITY.md`](scripts/SECURITY.md).  Describes supported versions
  and how to report vulnerabilities privately via GitHub Security Advisories.
- **`.github/dependabot.yml`** – Dependabot configuration based on
  [`scripts/dependabot.yml`](scripts/dependabot.yml).  Keeps GitHub Actions
  pinned to the latest versions with weekly checks.

All missing files are bundled into a single PR against the target branch.

#### Running the workflow

1. Go to **Actions → Security Audit** in this repository.
2. Click **Run workflow**.
3. Fill in the inputs:
   - **`repo`** *(required)* – repository name within `waldronlab`,
     e.g. `MultiAssayExperiment`.
   - **`branch`** *(optional, default `devel`)* – target branch to open the PR
     against, e.g. `devel` or `RELEASE_3_22`.
   - **`dry_run`** *(optional, default `false`)* – when `true`, the workflow
     performs all checks and logs what would change, but does **not** push any
     branch or open a PR.

---

### 4. Security Code Review (`security-code-review.yml`)

Clones a single target repository, sends its R and native (C/C++/Fortran) source
files to the Gemini LLM for security analysis using
[`scripts/instructions.md`](scripts/instructions.md) as the system prompt, and
opens a GitHub issue in the target repository with the findings.

The review is performed by [`scripts/bulk_security_review.sh`](scripts/bulk_security_review.sh),
a Bash script that can also be run locally or in parallel across all Bioconductor
packages (see the script's header for usage instructions).

#### What the review covers

The LLM is instructed to look for:

- **Security vulnerabilities** – SQL/command injection, path traversal, unsafe
  `eval()`/`parse()`, hardcoded credentials, insecure randomness, XSS, unsafe
  file operations, and more.
- **Native code safety** – buffer overflows, use-after-free, integer overflow,
  unsafe C functions (`strcpy`, `sprintf`, `gets`, …), format string bugs, and
  unsafe pointer arithmetic in any `src/` code.
- **Code quality** – missing input validation, leaky error handling, deprecated
  functions, and insufficient access controls.
- **Dependencies** – vulnerable or unmaintained imports.

Each finding is tagged with a standardised severity (Critical/High/Medium/Low)
and issue-type label, and includes a recommended fix.

#### Files reviewed

| Location | Contents |
|----------|----------|
| `DESCRIPTION`, `NAMESPACE` | Package metadata |
| `src/` | C, C++, Fortran source and headers |
| `R/` | All R source files |

Files are included in priority order (native code before R) up to a 200 000
character limit; any remainder is noted in the issue.

#### Eligibility checks (a repo is skipped when …)

| Condition | Action |
|-----------|--------|
| Not in `waldronlab` | Error |
| Is a fork | Skip |
| Is archived | Skip |
| Target branch not found | Skip |

#### Issue management

- A GitHub issue titled **"Security code review"** is opened in the target
  repository.
- If an open issue with that title already exists it is closed (with a cross-
  reference comment) before the fresh one is created, so at most one open
  security review issue exists per repository at any time.
- The issue body includes the full LLM output plus a footer linking back to
  this workflow run.

#### Running the workflow

1. Go to **Actions → Security Code Review** in this repository.
2. Click **Run workflow**.
3. Fill in the inputs:
   - **`repo`** *(required)* – repository name within `waldronlab`,
     e.g. `MultiAssayExperiment`.
   - **`branch`** *(optional, default `devel`)* – branch to clone and review.
   - **`model`** *(optional, default `gemini-2.5-pro-preview-03-25`)* – Gemini model to use,
     e.g. `gemini-2.5-pro-preview-03-25`, `gemini-2.0-flash`.
   - **`dry_run`** *(optional, default `false`)* – when `true`, the workflow
     performs the full review and prints the output to the log, but does
     **not** open a GitHub issue.

#### Required additional secret

The `Security Code Review` workflow requires **`GEMINI_API_KEY`** in addition
to `AUDIT_PAT`.  Obtain a key from [Google AI Studio](https://aistudio.google.com/).
The model used is controlled by the `model` workflow input; any model name
supported by the Gemini `generateContent` API can be used.

---

## Required secrets

All workflows use a secret named **`AUDIT_PAT`** – a GitHub
[Personal Access Token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
(classic) with at least the **`repo`** scope, stored in the `waldronlab/repo-audits`
repository secrets (or organisation secrets).

The `Security Code Review` workflow additionally requires **`GEMINI_API_KEY`**.

The token must have write access to the target repositories in `waldronlab` so
it can create branches, commit, and open pull requests or issues.

> **Tip:** A [GitHub App](https://docs.github.com/en/apps) token with
> `contents: write`, `pull-requests: write`, and `issues: write` permissions
> installed on the `waldronlab` organisation is the preferred long-term
> alternative to a PAT.

## Repository layout

```
.github/
  workflows/
    audit-single-repo-funding.yml   # Audit 1: add missing fnd entries to DESCRIPTION
    migrate-pr-check-to-ci.yml      # Audit 2: replace pr_check.yml with ci.yml wrapper
    security-audit.yml              # Audit 3: add missing security infrastructure
    security-code-review.yml        # Audit 4: AI-powered security code review
scripts/
  audit_single_repo.R               # R script: parses/updates Authors@R
  ci.yml                            # ci.yml template copied to target repos
  dependabot.yml                    # dependabot.yml template copied to target repos
  instructions.md                   # LLM system prompt for the security code review
  migrate-pr-check-pr-body.md       # PR body template for the migration audit
  nih_institutes.json               # NIH institute code → agency name map
  SECURITY.md                       # SECURITY.md template copied to target repos
  security-audit-pr-body.md         # PR body template for the security audit
  bulk_security_review.sh           # Bash script: clones repos, calls Gemini API, builds summary
README.md
```

