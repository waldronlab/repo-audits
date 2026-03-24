#!/usr/bin/env Rscript
# audit_single_repo.R
#
# Reads a DESCRIPTION file, checks for missing fnd (funder) entries in
# Authors@R, and writes an updated DESCRIPTION if any are missing.
#
# Environment variables (all required):
#   DESCRIPTION_PATH   - path to the DESCRIPTION file to audit
#   GRANTS             - comma-separated list of grant numbers (e.g. "U24HG010263,R01HG012345")
#   NIH_INSTITUTES_JSON - path to the JSON file mapping institute codes to names
#   OUTPUT_PATH        - path where the updated DESCRIPTION should be written
#                        (only created when changes are needed)
#
# Exit codes:
#   0 - success (OUTPUT_PATH written if changes were made, absent if none needed)
#   1 - fatal error (e.g. missing package, unreadable file)

if (!requireNamespace("desc", quietly = TRUE))
  stop("Package 'desc' is required. Install with: install.packages('desc')")
if (!requireNamespace("jsonlite", quietly = TRUE))
  stop("Package 'jsonlite' is required. Install with: install.packages('jsonlite')")

desc_path     <- Sys.getenv("DESCRIPTION_PATH")
grants_str    <- Sys.getenv("GRANTS")
inst_json     <- Sys.getenv("NIH_INSTITUTES_JSON")
output_path   <- Sys.getenv("OUTPUT_PATH")

for (v in c("DESCRIPTION_PATH", "GRANTS", "NIH_INSTITUTES_JSON", "OUTPUT_PATH")) {
  if (nchar(Sys.getenv(v)) == 0)
    stop("Required environment variable not set: ", v)
}

# ---------------------------------------------------------------------------
# Load NIH institute code -> agency name mapping
# ---------------------------------------------------------------------------
institutes <- jsonlite::read_json(inst_json)

# ---------------------------------------------------------------------------
# Validate and normalize grant numbers
# ---------------------------------------------------------------------------
grant_numbers <- trimws(strsplit(grants_str, ",")[[1]])
grant_numbers <- toupper(grant_numbers[nchar(grant_numbers) > 0])

valid_pattern <- "^(U24|R01)[A-Z]{2}[0-9]{6,}$"
invalid <- grant_numbers[!grepl(valid_pattern, grant_numbers)]
if (length(invalid) > 0) {
  message("INFO: Ignoring unrecognized grant number(s): ", paste(invalid, collapse = ", "))
}
grant_numbers <- grant_numbers[grepl(valid_pattern, grant_numbers)]

if (length(grant_numbers) == 0) {
  message("INFO: No valid grant numbers to process after filtering.")
  quit(save = "no", status = 0)
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
get_institute_code <- function(grant) {
  # grant looks like "U24HG010263"; institute code is characters 4-5 (1-indexed)
  substr(grant, 4, 5)
}

get_agency_name <- function(code) {
  name <- institutes[[toupper(code)]]
  if (is.null(name)) {
    message("INFO: Unknown NIH institute code '", code, "' – skipping this grant.")
    return(NULL)
  }
  name
}

grant_already_present <- function(authors, grant_number) {
  for (i in seq_along(authors)) {
    p <- authors[i]
    roles <- p$role[[1]]
    if (!is.null(roles) && "fnd" %in% roles) {
      cmts <- p$comment[[1]]
      if (!is.null(cmts) && !is.na(cmts["GrantNo."])) {
        if (toupper(unname(cmts["GrantNo."])) == toupper(grant_number)) {
          return(TRUE)
        }
      }
    }
  }
  FALSE
}

# ---------------------------------------------------------------------------
# Read DESCRIPTION
# ---------------------------------------------------------------------------
d <- tryCatch(
  desc::desc(file = desc_path),
  error = function(e) stop("Could not read DESCRIPTION at '", desc_path, "': ", conditionMessage(e))
)

# Check Authors@R field exists
if (!d$has_fields("Authors@R")) {
  message("INFO: No 'Authors@R' field found in DESCRIPTION – skipping repo.")
  quit(save = "no", status = 0)
}

current_authors <- d$get_authors()

# ---------------------------------------------------------------------------
# Process each grant
# ---------------------------------------------------------------------------
changes_made <- FALSE

for (grant in grant_numbers) {
  code        <- get_institute_code(grant)
  agency_name <- get_agency_name(code)

  if (is.null(agency_name)) next

  if (grant_already_present(current_authors, grant)) {
    message("INFO: Grant ", grant, " already present in Authors@R – no action needed.")
    next
  }

  message("INFO: Adding fnd entry for grant ", grant, " (", agency_name, ")")

  new_person <- utils::person(
    given   = agency_name,
    role    = "fnd",
    comment = c(GrantNo. = grant)
  )

  current_authors <- c(current_authors, new_person)
  changes_made    <- TRUE
}

# ---------------------------------------------------------------------------
# Write output only when something changed
# ---------------------------------------------------------------------------
if (!changes_made) {
  message("INFO: No changes needed – all grant fnd entries already present.")
  quit(save = "no", status = 0)
}

d$set_authors(current_authors)
d$write(file = output_path)
message("INFO: Updated DESCRIPTION written to '", output_path, "'.")
