This automated PR replaces the inline `.github/workflows/pr_check.yml` with a
thin `.github/workflows/ci.yml` wrapper that delegates to the shared reusable
workflow in [waldronlab/.github](https://github.com/waldronlab/.github).

## Changes
- **Added** `.github/workflows/ci.yml` – calls `waldronlab/.github/.github/workflows/bioc-pr-cmdcheck-pkgdown.yml@devel`
- **Removed** `.github/workflows/pr_check.yml`

## Why
Centralizing CI logic in a single reusable workflow makes future maintenance
easier: fixes and improvements only need to be made in one place.
