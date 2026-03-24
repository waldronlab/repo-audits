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
# Process each grant – collect entries that need to be added
# ---------------------------------------------------------------------------
entries_to_add <- list()

for (grant in grant_numbers) {
  code        <- get_institute_code(grant)
  agency_name <- get_agency_name(code)

  if (is.null(agency_name)) next

  if (grant_already_present(current_authors, grant)) {
    message("INFO: Grant ", grant, " already present in Authors@R – no action needed.")
    next
  }

  message("INFO: Adding fnd entry for grant ", grant, " (", agency_name, ")")
  entries_to_add <- c(entries_to_add, list(list(grant = grant, agency = agency_name)))
}

# ---------------------------------------------------------------------------
# Write output only when something changed
# ---------------------------------------------------------------------------
if (length(entries_to_add) == 0L) {
  message("INFO: No changes needed – all grant fnd entries already present.")
  quit(save = "no", status = 0)
}

# ---------------------------------------------------------------------------
# Helpers for surgical text patching (avoids desc reformatting Authors@R)
# ---------------------------------------------------------------------------

# find_outer_close_paren: walk `s` character-by-character tracking paren
# depth (respecting double-quoted strings).  Returns the index of the first
# ')' that brings the top-level depth back to 0.
find_outer_close_paren <- function(s) {
  chars      <- strsplit(s, "")[[1L]]
  depth      <- 0L
  in_str     <- FALSE
  esc_next   <- FALSE
  for (i in seq_along(chars)) {
    ch <- chars[i]
    if (esc_next)   { esc_next <- FALSE; next }
    if (ch == "\\") { esc_next <- TRUE;  next }
    if (ch == '"')  { in_str   <- !in_str; next }
    if (!in_str) {
      if (ch == "(") depth <- depth + 1L
      if (ch == ")") {
        depth <- depth - 1L
        if (depth == 0L) return(i)
      }
    }
  }
  NA_integer_
}

# detect_person_indent: infer leading whitespace of person() calls from the
# raw Authors@R value string (falls back to four spaces).
detect_person_indent <- function(ar_value) {
  lines <- strsplit(ar_value, "\n", fixed = TRUE)[[1L]]
  plns  <- grep("^\\s+person\\(", lines, value = TRUE)
  if (length(plns) == 0L) return("    ")
  m <- regexpr("^(\\s+)", plns[[1L]], perl = TRUE)
  if (m[1L] < 0L || attr(m, "match.length") <= 0L) return("    ")
  substring(plns[[1L]], m[1L], m[1L] + attr(m, "match.length") - 1L)
}

# patch_authors_r_text: given the full raw DESCRIPTION text and a list of
# entries (each with $grant and $agency), insert new fnd person() entries
# just before the outer closing ')' of the Authors@R field – leaving all
# existing formatting untouched.
patch_authors_r_text <- function(desc_text, entries) {
  all_lines <- strsplit(desc_text, "\n", fixed = TRUE)[[1L]]

  # Locate the Authors@R field start line
  ar_idx <- grep("^Authors@R\\s*:", all_lines)
  if (length(ar_idx) != 1L)
    stop("Could not locate unique Authors@R field in DESCRIPTION")

  # Find the last continuation line of the field (continuation lines start
  # with whitespace; a non-blank, non-indented line starts the next field)
  end_idx <- ar_idx
  if (ar_idx < length(all_lines)) {
    for (i in seq(ar_idx + 1L, length(all_lines))) {
      ln <- all_lines[[i]]
      if (nchar(ln) > 0L && !grepl("^\\s", ln)) break
      end_idx <- i
    }
  }

  field_lines <- all_lines[ar_idx:end_idx]
  field_text  <- paste(field_lines, collapse = "\n")

  # Isolate the value (everything after the first ':')
  colon_pos <- regexpr(":", field_text)[1L]
  ar_value  <- substring(field_text, colon_pos + 1L)

  # Detect indentation of existing person() calls
  person_indent <- detect_person_indent(ar_value)
  # Align 'comment =' under the first argument of person()
  # (7 = nchar("person("), which aligns continuation lines with the first arg)
  comment_align <- paste(rep(" ", nchar(person_indent) + 7L), collapse = "")

  # Find the outer closing ')' of the whole Authors@R expression
  outer_close <- find_outer_close_paren(ar_value)
  if (is.na(outer_close))
    stop("Could not find outer closing ')' in Authors@R value")

  before_outer <- substring(ar_value, 1L, outer_close - 1L)
  after_outer  <- substring(ar_value, outer_close + 1L)   # text after ')'

  # Determine the indentation to use when re-emitting the outer ')'.
  # If the original outer ')' was already on its own line (before_outer ends
  # with "\n<spaces>") reuse that indent; otherwise default to two spaces.
  close_m <- regexpr("\\n([ \t]*)$", before_outer, perl = TRUE)
  if (close_m != -1L) {
    close_prefix <- sub("^\n", "", regmatches(
      before_outer,
      gregexpr("\\n([ \t]*)$", before_outer, perl = TRUE)
    )[[1L]])
  } else {
    close_prefix <- "  "
  }

  # Format the new fnd person() entries.
  # Escape backslashes and double-quotes in values before embedding them
  # in sprintf so the generated R string literals are always well-formed.
  esc <- function(x) {
    x <- gsub("\\", "\\\\", x, fixed = TRUE)  # \ -> \\
    x <- gsub('"',  '\\"',  x, fixed = TRUE)  # " -> \"
    x
  }
  new_person_texts <- vapply(entries, function(e) {
    sprintf('%sperson("%s", role = "fnd",\n%scomment = c(GrantNo. = "%s"))',
            person_indent, esc(e$agency), comment_align, esc(e$grant))
  }, character(1L))

  # Strip any trailing whitespace from before_outer (normalises both the
  # "inline ))" and "own-line )" cases) then append the new entries
  before_trimmed <- sub("\\s+$", "", before_outer)

  new_ar_value <- paste0(
    before_trimmed, ",\n",
    paste(new_person_texts, collapse = ",\n"),
    "\n", close_prefix, ")"
  )

  # Preserve anything that appeared after the outer ')' (rare, but safe)
  if (nchar(trimws(after_outer)) > 0L)
    new_ar_value <- paste0(new_ar_value, after_outer)

  # Reconstruct the full field text and split back into lines
  # (ar_value already includes the space/newline that follows the colon,
  # so we do NOT add an extra space here)
  new_field_text  <- paste0(substring(field_text, 1L, colon_pos), new_ar_value)
  new_field_lines <- strsplit(new_field_text, "\n", fixed = TRUE)[[1L]]

  new_all_lines <- c(
    if (ar_idx  > 1L)                all_lines[seq_len(ar_idx - 1L)]             else character(0L),
    new_field_lines,
    if (end_idx < length(all_lines)) all_lines[seq(end_idx + 1L, length(all_lines))] else character(0L)
  )

  paste(new_all_lines, collapse = "\n")
}

# ---------------------------------------------------------------------------
# Read the raw DESCRIPTION, patch it surgically, and write the output.
# readLines() strips the per-line newlines; paste(collapse="\n") rebuilds the
# text without a trailing newline.  writeLines() then appends "\n" after every
# line (including the last), which matches the standard text-file convention.
# ---------------------------------------------------------------------------
raw_text     <- paste(readLines(desc_path, warn = FALSE), collapse = "\n")
patched_text <- tryCatch(
  patch_authors_r_text(raw_text, entries_to_add),
  error = function(e) stop("Failed to patch Authors@R: ", conditionMessage(e))
)
writeLines(strsplit(patched_text, "\n", fixed = TRUE)[[1L]], con = output_path)
message("INFO: Updated DESCRIPTION written to '", output_path, "'.")
