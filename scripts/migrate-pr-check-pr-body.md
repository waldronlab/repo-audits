This automated PR replaces the inline `.github/workflows/pr_check.yml` with a
thin `.github/workflows/ci.yaml` wrapper that delegates to the shared reusable
workflow in [waldronlab/.github](https://github.com/waldronlab/.github).

## Changes
- **Added** `.github/workflows/ci.yaml` – calls `waldronlab/.github/.github/workflows/bioc-pr-cmdcheck-pkgdown.yml@devel`
- **Removed** `.github/workflows/pr_check.yml`

## Why
Centralising CI logic in a single reusable workflow makes future maintenance
easier: fixes and improvements only need to be made in one place.
