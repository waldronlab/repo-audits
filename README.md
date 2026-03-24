# repo-audits

Utility repository for auditing [waldronlab](https://github.com/waldronlab)
R / Bioconductor packages and ensuring funding information is present in their
`DESCRIPTION` files.

## What it does

Two complementary workflows are available:

* **Audit All Repos** (`audit-all-repos-funding.yml`) – discovers *every*
  eligible `waldronlab` R repository automatically using
  [BiocReporting](https://github.com/Bioconductor/BiocReporting) and audits
  each one in parallel.  Runs on a weekly schedule (Monday 08:00 UTC) and can
  also be triggered manually with an optional dry-run flag.

* **Audit Single Repo** (`audit-single-repo-funding.yml`) – checks one
  repository specified at dispatch time; useful for targeted, on-demand audits.

Both workflows open a pull request against the `devel` branch of a target
repository when grant-funder entries are missing from `Authors@R` in
`DESCRIPTION`.

### Eligibility checks (a repo is skipped when …)

| Condition | Action |
|-----------|--------|
| Not in `waldronlab` | Error |
| Is a fork | Skip |
| Is archived | Skip |
| Has no `devel` branch | Skip |
| No `DESCRIPTION` at repo root on `devel` | Skip (not an R package) |
| `DESCRIPTION` has no `Authors@R` field | Skip (manual review needed) |
| No recognised grant topics | Skip |

### Grant number topics

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

### What gets added to `DESCRIPTION`

For each unrecognised grant a `person()` entry with role `"fnd"` is **appended**
to the end of the `Authors@R` vector:

```r
person("NHGRI", role = "fnd",
    comment = c(GrantNo. = "U24HG010263"))
```

Existing `fnd` entries whose `GrantNo.` already matches the topic are left
untouched.  Entries with a *different* `GrantNo.` are not overwritten; the new
entry is simply appended alongside them.

## Running the workflows

### Audit All Repos (automated discovery)

The `audit-all-repos-funding.yml` workflow runs automatically every Monday.
To trigger it manually:

1. Go to **Actions → Audit All Repos Funding** in this repository.
2. Click **Run workflow**.
3. Optionally check **`dry_run`** to preview changes without opening PRs.

The workflow uses the following functions from
[BiocReporting](https://github.com/Bioconductor/BiocReporting) to discover
eligible repositories:

| BiocReporting function | Purpose |
|---|---|
| `account_repositories(org = "waldronlab")` | List all repositories in the organisation |
| `filter_r_repos(repo_list)` | Keep only repositories that contain R code |

It then applies a regex pattern (`^(u24|r01)[a-z]{2}[0-9]{6,}$`) to each
repository's topics, following the same approach as
`BiocReporting::filter_topic_repos()` but using pattern matching so that
grant numbers do not need to be enumerated in advance.

### Audit Single Repo (on-demand)

1. Go to **Actions → Audit Single Repo Funding** in this repository.
2. Click **Run workflow**.
3. Fill in the inputs:
   - **`repo`** *(required)* – repository name within `waldronlab`,
     e.g. `MultiAssayExperiment`.
   - **`dry_run`** *(optional, default `false`)* – when `true`, the workflow
     performs all checks and logs what would change, but does **not** push any
     branch or open a PR.

### Required secret

The workflow uses a secret named **`AUDIT_PAT`** – a GitHub
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
    audit-all-repos-funding.yml    # Discovers all eligible repos via BiocReporting and audits each
    audit-single-repo-funding.yml  # On-demand audit for a single named repository
scripts/
  find_eligible_repos.R            # R script: uses BiocReporting to enumerate eligible repos
  audit_single_repo.R              # R script: parses/updates Authors@R in DESCRIPTION
  nih_institutes.json              # NIH institute code → agency name map
README.md
```

## Adding or updating NIH institute mappings

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

