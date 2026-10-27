This automated PR points the existing CI workflow at the recommended
[Bioconductor/workflows `bioccheck.yml`](https://github.com/Bioconductor/workflows/blob/main/.github/workflows/bioccheck.yml)
reusable workflow, replacing the reference to `waldronlab/.github`.

## Changes
- **Updated** the `uses:` line to `Bioconductor/workflows/.github/workflows/bioccheck.yml@<ref>`
- **Removed** `with:` inputs not supported by the new workflow
  (`cran`, `enable_docker`, `dockerfile_path`)

## Notes
The new workflow accepts `enable_pkgdown`, `enable_cyclocomp`, `error_on` and
`bioc_version`, plus an optional `CODECOV_TOKEN` secret. Docker image builds
are no longer handled by the shared workflow; if you rely on them, keep a
separate workflow for that.
