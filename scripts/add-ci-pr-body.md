This automated PR adds a `.github/workflows/ci.yml` wrapper that delegates to
the recommended reusable workflow in
[Bioconductor/workflows](https://github.com/Bioconductor/workflows/blob/main/.github/workflows/bioccheck.yml).

## Changes
- **Added** `.github/workflows/ci.yml` – calls `Bioconductor/workflows/.github/workflows/bioccheck.yml@<ref>`

## Why
Using the centralized reusable workflow means future CI fixes and improvements
only need to be made in one place, keeping per-package workflows thin and
easy to maintain.

## Customisation
The `with:` block in the generated `ci.yml` exposes the following optional
parameters that you can edit to suit your package:

| Parameter | Default | Description |
|---|---|---|
| `enable_pkgdown` | `true` | Build and deploy a pkgdown site |
| `enable_cyclocomp` | `false` | Run cyclomatic complexity analysis |
| `error_on` | `warning` | rcmdcheck error policy (never, note, warning, error) |
