## Security Audit

This automated PR adds missing security infrastructure to this repository.

### What was added

Files listed below were absent and have been added; files already present were
left untouched.

<!-- added-files-placeholder -->

### GitHub security features enabled

The following repository-level security features have been switched on via the
GitHub API:

- **Dependabot vulnerability alerts** – GitHub will notify maintainers when
  a dependency has a known security vulnerability.
- **Automated security fixes** – Dependabot will open pull requests to resolve
  security vulnerabilities in dependencies automatically.

### Reviewing the changes

- **`SECURITY.md`** – Security-disclosure policy. Update the contact details
  and timelines to match your team's commitments before merging.
- **`.github/dependabot.yml`** – Keeps GitHub Actions pinned to up-to-date
  versions. Extend the file to cover other ecosystems (e.g. `pip`, `npm`) if
  the package ships non-R dependencies.

Please review the additions and merge when ready.
