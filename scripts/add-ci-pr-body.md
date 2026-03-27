This automated PR adds a `.github/workflows/ci.yml` wrapper that delegates to
the shared reusable workflow in
[waldronlab/.github](https://github.com/waldronlab/.github).

## Changes
- **Added** `.github/workflows/ci.yml` – calls `waldronlab/.github/.github/workflows/bioc-pr-cmdcheck-pkgdown.yml@<version>`

## Why
Using the centralized reusable workflow means future CI fixes and improvements
only need to be made in one place, keeping per-package workflows thin and
easy to maintain.
