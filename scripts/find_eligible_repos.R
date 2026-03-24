#!/usr/bin/env Rscript
# find_eligible_repos.R
#
# Uses functions from the BiocReporting package to discover waldronlab R
# repositories that carry NIH grant topics and are therefore eligible for the
# funding audit.
#
# Functions reused from BiocReporting:
#   account_repositories() – lists every repo in an org/user account
#   filter_r_repos()       – keeps only repos where R is a used language
#
# For grant-topic filtering we apply a regex pattern to the topics returned by
# the GitHub API, following the same approach used in
# BiocReporting::filter_topic_repos() but matching a pattern rather than
# exact strings (because the set of valid grant topics is open-ended).
#
# Environment variables:
#   GH_TOKEN / GITHUB_PAT  – GitHub PAT with read access to the org
#   ORG (optional)         – organisation name, defaults to "waldronlab"
#
# Output:
#   A JSON array written to stdout, each element is an object with two fields:
#     { "repo": "<repo-name>", "grants": "<GRANT1,GRANT2,...>" }
#   This is consumed directly as the include matrix in the calling GitHub
#   Actions workflow.
#
# Exit codes:
#   0 – success (JSON written to stdout; may be an empty array)
#   1 – fatal error

for (pkg in c("gh", "jsonlite")) {
    if (!requireNamespace(pkg, quietly = TRUE))
        stop(
            "Package '", pkg, "' is required. ",
            "Install with: install.packages('", pkg, "')"
        )
}
if (!requireNamespace("BiocReporting", quietly = TRUE))
    stop(
        "Package 'BiocReporting' is required. ",
        "Install with: remotes::install_github('Bioconductor/BiocReporting')"
    )

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
org           <- Sys.getenv("ORG", unset = "waldronlab")
grant_pattern <- "^(u24|r01)[a-z]{2}[0-9]{6,}$"

# ---------------------------------------------------------------------------
# Step 1 – get all repositories for the organisation
#   Uses BiocReporting::account_repositories()
# ---------------------------------------------------------------------------
message("==> Finding all repositories for ", org, " ...")
all_repos <- BiocReporting::account_repositories(org = org)
message("    Found ", length(all_repos), " total repositories.")

# Remove forks and archived repos before further filtering
active_repos <- Filter(
    function(repo) !isTRUE(repo$fork) && !isTRUE(repo$archived),
    all_repos
)
message("    ", length(active_repos), " non-fork, non-archived repositories.")

# ---------------------------------------------------------------------------
# Step 2 – keep only R repositories
#   Uses BiocReporting::filter_r_repos()
# ---------------------------------------------------------------------------
r_repos <- BiocReporting::filter_r_repos(active_repos)
message("    ", length(r_repos), " R repositories found.")

# ---------------------------------------------------------------------------
# Step 3 – filter by grant topics
#   Inspired by BiocReporting::filter_topic_repos() but uses a regex pattern
#   instead of exact matching, because the set of valid grant topics is
#   open-ended and not known in advance.
# ---------------------------------------------------------------------------
message("==> Filtering repositories by grant topics ...")
eligible <- list()

for (repo in r_repos) {
    repo_topics <- tryCatch(
        gh::gh(
            "GET /repos/{owner}/{repo}/topics",
            owner = repo$owner$login,
            repo  = repo$name
        )[["names"]],
        error = function(e) character(0L)
    )

    grant_topics <- grep(
        grant_pattern, repo_topics,
        value = TRUE, ignore.case = TRUE
    )

    if (length(grant_topics) > 0L) {
        grants <- paste(toupper(grant_topics), collapse = ",")
        eligible <- c(eligible, list(list(repo = repo$name, grants = grants)))
        message("  -> ", repo$name, "  (grants: ", grants, ")")
    }
}

message("==> ", length(eligible), " repositories eligible for audit.")

# ---------------------------------------------------------------------------
# Output – JSON array consumed by the GitHub Actions matrix strategy
# ---------------------------------------------------------------------------
cat(jsonlite::toJSON(eligible, auto_unbox = TRUE))
