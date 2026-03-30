This automated PR adds a `.github/workflows/ci.yml` wrapper that delegates to
the shared reusable workflow in
[waldronlab/.github](https://github.com/waldronlab/.github).

## Changes
- **Added** `.github/workflows/ci.yml` – calls `waldronlab/.github/.github/workflows/bioc-pr-cmdcheck-pkgdown.yml@<version>`

## Why
Using the centralized reusable workflow means future CI fixes and improvements
only need to be made in one place, keeping per-package workflows thin and
easy to maintain.

## Customisation
The `with:` block in the generated `ci.yml` exposes the following optional
parameters that you can edit to suit your package:

| Parameter | Default | Description |
|---|---|---|
| `enable_pkgdown` | `true` | Build and deploy a pkgdown site on RELEASE_* branch pushes |
| `enable_docker` | `true` | Build and push a Docker image on devel pushes (requires a Dockerfile) |
| `dockerfile_path` | `inst/docker/pkg/Dockerfile` | Path to the Dockerfile |
| `cran` | *(workflow default)* | CRAN-like repository URL used to install packages |
