#!/usr/bin/env bash
# bulk_security_review.sh
#
# Fast security-focused review of all Bioconductor R packages using LLM analysis.
# This skips time-consuming R CMD check and BiocCheck steps, focusing on
# direct source code security analysis via LLM.
#
# Requirements:
# - GEMINI_API_KEY environment variable must be set
# - git, curl, and jq installed
#
# Usage:
#   export GEMINI_API_KEY="your-api-key"
#   ./bulk_security_review.sh [start_index] [end_index]
#
# Parallel usage (sharded workers):
#   WORKER_ID=1 REPOS_DIR=output/repos_w1 SKIP_WRAPUP=1 ./bulk_security_review.sh 1 50
#   WORKER_ID=2 REPOS_DIR=output/repos_w2 SKIP_WRAPUP=1 ./bulk_security_review.sh 51 100
#   FINALIZE_ONLY=1 ./bulk_security_review.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# Configuration
# Supports either:
# - one package per line (bioc_pkgs.txt), cloned from git.bioconductor.org
# - tab-separated "PackageName     URL" lines for custom sources
PACKAGE_LIST="${PACKAGE_LIST:-$PROJECT_ROOT/bioc_pkgs.txt}"
BIOC_GIT_BASE_URL="${BIOC_GIT_BASE_URL:-https://git.bioconductor.org/packages}"
BIOC_GIT_BRANCH="${BIOC_GIT_BRANCH:-devel}"
AUDIT_DIR="${AUDIT_DIR:-${REVIEWS_DIR:-$PROJECT_ROOT/output/audit}}"
REPOS_DIR="${REPOS_DIR:-$PROJECT_ROOT/output/repos}"
CLONES_DIR="$REPOS_DIR"
REVIEWS_OUTPUT_DIR="$AUDIT_DIR/reviews"
SECURITY_REPORT="$AUDIT_DIR/security_summary.md"
SEVERITY_MATRIX_CSV="$AUDIT_DIR/security_severity_matrix.csv"
WORKER_ID="${WORKER_ID:-}"
WORKER_SUFFIX=""
if [[ -n "$WORKER_ID" ]]; then
  WORKER_SUFFIX="_${WORKER_ID}"
fi
PROGRESS_LOG_DEFAULT="$AUDIT_DIR/progress${WORKER_SUFFIX}.log"
PROGRESS_LOG="${PROGRESS_LOG:-$PROGRESS_LOG_DEFAULT}"
SKIP_WRAPUP="${SKIP_WRAPUP:-0}"
FINALIZE_ONLY="${FINALIZE_ONLY:-0}"
SECURITY_INSTRUCTIONS_FILE="${SECURITY_INSTRUCTIONS_FILE:-$PROJECT_ROOT/instructions.md}"

# LLM Configuration
GEMINI_MODEL="${GEMINI_MODEL:-gemini-2.5-pro-preview-03-25}"
GEMINI_API_KEY="${GEMINI_API_KEY:-}"

# Parse arguments
START_IDX="${1:-1}"
END_IDX="${2:-999999}"

if [[ ! -f "$PACKAGE_LIST" ]]; then
  echo "Error: Package list not found at $PACKAGE_LIST" >&2
  exit 1
fi

if [[ ! -f "$SECURITY_INSTRUCTIONS_FILE" ]]; then
  echo "Error: Security instructions not found at $SECURITY_INSTRUCTIONS_FILE" >&2
  exit 1
fi

# Count valid (non-empty, non-comment) package lines.
TOTAL_PACKAGES=0
while IFS= read -r line; do
  trimmed="${line#${line%%[![:space:]]*}}"
  if [[ -z "$trimmed" ]] || [[ "$trimmed" == \#* ]]; then
    continue
  fi
  TOTAL_PACKAGES=$((TOTAL_PACKAGES + 1))
done < "$PACKAGE_LIST"

if [[ $TOTAL_PACKAGES -eq 0 ]]; then
  echo "Error: No packages found in $PACKAGE_LIST" >&2
  exit 1
fi

# Create directory structure
mkdir -p "$CLONES_DIR" "$REVIEWS_OUTPUT_DIR"

# Initialize progress log
echo "=== Bulk Security Review Progress ===" > "$PROGRESS_LOG"
echo "Started: $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> "$PROGRESS_LOG"
if [[ -n "$WORKER_ID" ]]; then
  echo "Worker ID: $WORKER_ID" >> "$PROGRESS_LOG"
fi
echo "Finalize-only mode: $FINALIZE_ONLY" >> "$PROGRESS_LOG"
echo "Skip wrap-up: $SKIP_WRAPUP" >> "$PROGRESS_LOG"
echo "" >> "$PROGRESS_LOG"

# Counter for progress tracking
CURRENT=0
PROCESSED=0
SUCCESSFUL=0
FAILED=0
SKIPPED=0

# Read package list and process unless running finalize-only mode.
if [[ "$FINALIZE_ONLY" != "1" ]]; then
while IFS= read -r line; do
  trimmed="${line#${line%%[![:space:]]*}}"
  if [[ -z "$trimmed" ]] || [[ "$trimmed" == \#* ]]; then
    continue
  fi

  # Accept either:
  # 1) PackageName
  # 2) PackageName     https://custom-url
  IFS=$'\t' read -r PACKAGE_NAME PACKAGE_URL <<< "$trimmed"
  PACKAGE_NAME="${PACKAGE_NAME%%[[:space:]]*}"
  if [[ -z "${PACKAGE_URL:-}" ]]; then
    PACKAGE_URL="$BIOC_GIT_BASE_URL/$PACKAGE_NAME"
  fi

  CURRENT=$((CURRENT + 1))

  # Skip if before start index
  if [[ $CURRENT -lt $START_IDX ]]; then
    continue
  fi

  # Stop if after end index
  if [[ $CURRENT -gt $END_IDX ]]; then
    break
  fi

  PROCESSED=$((PROCESSED + 1))

  echo ""
  echo "========================================================================="
  echo "[$CURRENT] Processing: $PACKAGE_NAME"
  echo "========================================================================="
  echo "[$CURRENT] $PACKAGE_NAME - Started $(date -u +"%H:%M:%S")" >> "$PROGRESS_LOG"

  PACKAGE_CLONE_DIR="$CLONES_DIR/$PACKAGE_NAME"
  PACKAGE_REVIEW_FILE="$REVIEWS_OUTPUT_DIR/${PACKAGE_NAME}_security_review.md"

  # Skip packages that already have a saved review.
  if [[ -f "$PACKAGE_REVIEW_FILE" ]]; then
    echo "    ✓ Existing review found, skipping audit"
    SKIPPED=$((SKIPPED + 1))
    echo "[$CURRENT] $PACKAGE_NAME - SKIPPED (review exists)" >> "$PROGRESS_LOG"
    continue
  fi

  # Only require API key when a new audit is needed.
  if [[ -z "$GEMINI_API_KEY" ]]; then
    echo "    ERROR: GEMINI_API_KEY is required to audit new packages"
    FAILED=$((FAILED + 1))
    echo "[$CURRENT] $PACKAGE_NAME - FAILED (missing GEMINI_API_KEY)" >> "$PROGRESS_LOG"
    continue
  fi

  # Step 1: Clone the package
  echo "==> Preparing clone for $PACKAGE_NAME (branch: $BIOC_GIT_BRANCH)..."
  if [[ -d "$PACKAGE_CLONE_DIR" ]]; then
    echo "    Already cloned, updating branch $BIOC_GIT_BRANCH"
    if git -C "$PACKAGE_CLONE_DIR" fetch --depth 1 origin "$BIOC_GIT_BRANCH" > /dev/null 2>&1 && \
       git -C "$PACKAGE_CLONE_DIR" checkout -q "$BIOC_GIT_BRANCH" > /dev/null 2>&1 && \
       git -C "$PACKAGE_CLONE_DIR" pull --ff-only --depth 1 origin "$BIOC_GIT_BRANCH" > /dev/null 2>&1; then
      echo "    Updated successfully"
    else
      echo "    ERROR: Failed to update branch $BIOC_GIT_BRANCH for $PACKAGE_NAME" | tee -a "$PROGRESS_LOG"
      FAILED=$((FAILED + 1))
      continue
    fi
  else
    if git clone --depth 1 --single-branch --branch "$BIOC_GIT_BRANCH" "$PACKAGE_URL" "$PACKAGE_CLONE_DIR" > /dev/null 2>&1; then
      echo "    Cloned successfully"
    else
      echo "    ERROR: Failed to clone $PACKAGE_NAME (branch: $BIOC_GIT_BRANCH)" | tee -a "$PROGRESS_LOG"
      FAILED=$((FAILED + 1))
      continue
    fi
  fi

  # Record the exact source revision used for this review.
  PACKAGE_BRANCH=$(git -C "$PACKAGE_CLONE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  PACKAGE_COMMIT=$(git -C "$PACKAGE_CLONE_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
  echo "[$CURRENT] $PACKAGE_NAME - Source: branch=$PACKAGE_BRANCH commit=$PACKAGE_COMMIT" >> "$PROGRESS_LOG"

  # Step 2: Collect source code for analysis
  echo "==> Collecting source code..."
  SOURCE_CONTEXT=$(mktemp)

  # Collect key files
  {
    echo "# Security Review Context for $PACKAGE_NAME"
    echo ""
    echo "Repository: $PACKAGE_URL"
    echo ""

    # DESCRIPTION file
    if [[ -f "$PACKAGE_CLONE_DIR/DESCRIPTION" ]]; then
      echo "## DESCRIPTION"
      echo '```'
      head -100 "$PACKAGE_CLONE_DIR/DESCRIPTION"
      echo '```'
      echo ""
    fi

    # NAMESPACE file
    if [[ -f "$PACKAGE_CLONE_DIR/NAMESPACE" ]]; then
      echo "## NAMESPACE"
      echo '```'
      head -50 "$PACKAGE_CLONE_DIR/NAMESPACE"
      echo '```'
      echo ""
    fi

    # R source files (first 50k chars from each)
    echo "## R Source Code"
    if [[ -d "$PACKAGE_CLONE_DIR/R" ]]; then
      for rfile in "$PACKAGE_CLONE_DIR/R"/*.R "$PACKAGE_CLONE_DIR/R"/*.r; do
        if [[ -f "$rfile" ]]; then
          echo "### $(basename "$rfile")"
          echo '```r'
          head -c 50000 "$rfile" 2>/dev/null || cat "$rfile"
          echo ""
          echo '```'
          echo ""
        fi
      done
    fi

    # C, C++, and Fortran source files in src/ (memory-safety issues, etc.)
    if [[ -d "$PACKAGE_CLONE_DIR/src" ]]; then
      echo "## Native Source Code (src/)"
      SRC_COUNT=0
      while IFS= read -r -d '' srcfile; do
        if [[ $SRC_COUNT -lt 10 ]]; then
          LANG="c"
          case "${srcfile##*.}" in
            cpp|cc|cxx) LANG="cpp" ;;
            f|f90|f95|F|F90) LANG="fortran" ;;
          esac
          echo "### $(basename "$srcfile")"
          echo "\`\`\`$LANG"
          head -c 30000 "$srcfile"
          echo ""
          echo "\`\`\`"
          echo ""
          SRC_COUNT=$((SRC_COUNT + 1))
        fi
      done < <(find "$PACKAGE_CLONE_DIR/src" -maxdepth 2 \
        \( -name "*.c" -o -name "*.cpp" -o -name "*.cc" -o -name "*.cxx" \
           -o -name "*.f" -o -name "*.f90" -o -name "*.f95" \
           -o -name "*.F" -o -name "*.F90" \) -print0 2>/dev/null)
    fi

    # README if available (might contain security info)
    if [[ -f "$PACKAGE_CLONE_DIR/README.md" ]]; then
      echo "## README"
      echo '```markdown'
      head -c 10000 "$PACKAGE_CLONE_DIR/README.md"
      echo '```'
    fi

  } > "$SOURCE_CONTEXT"

  # Step 3: Send to LLM for security analysis
  echo "==> Analyzing with Gemini LLM..."

  SECURITY_PROMPT=$(cat "$SECURITY_INSTRUCTIONS_FILE")

  # Make API call to Gemini
  API_URL="https://generativelanguage.googleapis.com/v1beta/models/$GEMINI_MODEL:generateContent?key=$GEMINI_API_KEY"

  # Prepare JSON payload
  PAYLOAD=$(jq -n \
    --arg prompt "$SECURITY_PROMPT" \
    --arg context "$(cat "$SOURCE_CONTEXT")" \
    '{
      contents: [{
        parts: [{
          text: ($prompt + "\n\n" + $context)
        }]
      }],
      generationConfig: {
        temperature: 0.1,
        maxOutputTokens: 65536
      }
    }')
  # Note: maxOutputTokens 65536 is the maximum supported by Gemini 2.5 Pro.
  # For smaller models (e.g. gemini-2.0-flash, limit 8192), lower this value.
  RESPONSE_FILE=$(mktemp)
  CURL_STDERR_FILE=$(mktemp)
  if HTTP_STATUS=$(curl -sS -o "$RESPONSE_FILE" -w "%{http_code}" -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>"$CURL_STDERR_FILE"); then
    CURL_EXIT=0
  else
    CURL_EXIT=$?
    HTTP_STATUS="000"
  fi

  RESPONSE=$(cat "$RESPONSE_FILE" 2>/dev/null || true)
  RESPONSE_SNIPPET=$(printf "%s" "$RESPONSE" | tr '\n' ' ' | tr '\r' ' ' | cut -c1-300)

  if [[ $CURL_EXIT -ne 0 ]]; then
    echo "    ERROR: API request failed (curl exit $CURL_EXIT)"
    FAILED=$((FAILED + 1))
    echo "[$CURRENT] $PACKAGE_NAME - FAILED (curl_exit=$CURL_EXIT http_status=$HTTP_STATUS response_snippet=$RESPONSE_SNIPPET)" >> "$PROGRESS_LOG"
    rm -f "$SOURCE_CONTEXT" "$RESPONSE_FILE" "$CURL_STDERR_FILE"
    continue
  fi

  # Check if response contains an API error
  API_ERROR=$(echo "$RESPONSE" | jq -r '.error.message // ""')
  if [[ -n "$API_ERROR" ]]; then
    echo "    ERROR: API returned error: $API_ERROR"
    FAILED=$((FAILED + 1))
    echo "[$CURRENT] $PACKAGE_NAME - FAILED (curl_exit=$CURL_EXIT http_status=$HTTP_STATUS api_error=$API_ERROR response_snippet=$RESPONSE_SNIPPET)" >> "$PROGRESS_LOG"
    rm -f "$SOURCE_CONTEXT" "$RESPONSE_FILE" "$CURL_STDERR_FILE"
    continue
  fi

  # Extract the generated text from response
  REVIEW_TEXT=$(echo "$RESPONSE" | jq -r '.candidates[0].content.parts[0].text // ""')
  if [[ -z "$REVIEW_TEXT" ]]; then
    echo "    ERROR: Empty LLM response"
    FAILED=$((FAILED + 1))
    echo "[$CURRENT] $PACKAGE_NAME - FAILED (curl_exit=$CURL_EXIT http_status=$HTTP_STATUS response_snippet=$RESPONSE_SNIPPET)" >> "$PROGRESS_LOG"
    rm -f "$SOURCE_CONTEXT" "$RESPONSE_FILE" "$CURL_STDERR_FILE"
    continue
  fi

  # Save review
  {
    echo "# Security Review: $PACKAGE_NAME"
    echo ""
    echo "**Repository:** $PACKAGE_URL"
    echo "**Review Date:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo "**Model:** $GEMINI_MODEL"
    echo ""
    echo "---"
    echo ""
    echo "$REVIEW_TEXT"
  } > "$PACKAGE_REVIEW_FILE"

  # Check if any security issues were found
  if echo "$REVIEW_TEXT" | grep -qi "severity\|vulnerability\|injection\|critical\|high\|medium"; then
    echo "    ⚠️  Security issues detected"
  else
    echo "    ✓ No significant security issues detected"
  fi

  SUCCESSFUL=$((SUCCESSFUL + 1))
  echo "[$CURRENT] $PACKAGE_NAME - SUCCESS" >> "$PROGRESS_LOG"
  rm -f "$RESPONSE_FILE" "$CURL_STDERR_FILE"

  # Clean up temp file
  rm -f "$SOURCE_CONTEXT"

  # Brief pause to avoid rate limiting
  sleep 2

done < "$PACKAGE_LIST"
fi

if [[ "$SKIP_WRAPUP" == "1" && "$FINALIZE_ONLY" != "1" ]]; then
  echo "SKIP_WRAPUP=1, skipping summary/CSV generation for this worker." | tee -a "$PROGRESS_LOG"
  echo "Completed: $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> "$PROGRESS_LOG"
  exit 0
fi

# Build severity-sorted summary from all existing review files.
echo "==> Building severity-sorted summary from review files..."
TMP_DIR=$(mktemp -d)
trap "rm -rf '$TMP_DIR'" EXIT

CRITICAL_FILE="$TMP_DIR/critical.md"
HIGH_FILE="$TMP_DIR/high.md"
MEDIUM_FILE="$TMP_DIR/medium.md"
LOW_FILE="$TMP_DIR/low.md"
CLEAN_FILE="$TMP_DIR/clean.md"
CSV_TMP="$TMP_DIR/severity_matrix.csv"

touch "$CRITICAL_FILE" "$HIGH_FILE" "$MEDIUM_FILE" "$LOW_FILE" "$CLEAN_FILE"
echo "Package,Critical,High,Medium,Low,Clean,SQL_INJECTION,COMMAND_INJECTION,PATH_TRAVERSAL,UNSAFE_DESERIALIZATION,HARDCODED_CREDENTIAL,INSECURE_RANDOMNESS,UNSAFE_EVAL_PARSE,XSS,UNSAFE_FILE_OPERATION,AUTHZ_AUTHN,MEMORY_SAFETY,FORMAT_STRING,INTEGER_OVERFLOW,DEPENDENCY_RISK,INPUT_VALIDATION,ERROR_HANDLING,DEPRECATED_INSECURE_FUNCTION,ACCESS_CONTROL,OTHER" > "$CSV_TMP"

for review_file in "$REVIEWS_OUTPUT_DIR"/*_security_review.md; do
  [[ -f "$review_file" ]] || continue

  package_name=$(basename "$review_file" _security_review.md)

  # Count individual findings at each severity level using per-issue Severity: lines.
  critical=$(grep -ciE "^[[:space:]]*Severity:[[:space:]]*Critical" "$review_file" || true)
  high=$(grep -ciE "^[[:space:]]*Severity:[[:space:]]*High" "$review_file" || true)
  medium=$(grep -ciE "^[[:space:]]*Severity:[[:space:]]*Medium" "$review_file" || true)
  low=$(grep -ciE "^[[:space:]]*Severity:[[:space:]]*Low" "$review_file" || true)

  clean=0
  if grep -qiE "^[[:space:]]*Identified Severities:.*Clean" "$review_file"; then
    clean=1
  fi

  # Roll up to a single severity for summary section placement.
  severity="Clean"
  if [[ $critical -gt 0 ]]; then
    severity="Critical"
  elif [[ $high -gt 0 ]]; then
    severity="High"
  elif [[ $medium -gt 0 ]]; then
    severity="Medium"
  elif [[ $low -gt 0 ]]; then
    severity="Low"
  fi

  # Extract only the Summary section body and remove deeper subsections.
  # Fallback: if no explicit Summary header exists, use intro text before first ### heading.
  summary_text=$(awk '
    /^### Summary[[:space:]]*$/ { in_summary=1; next }
    /^### / && in_summary { exit }
    in_summary { print }
  ' "$review_file" | sed '/^[[:space:]]*###/d')

  if [[ -z "$summary_text" ]]; then
    summary_text=$(awk '
      /^---[[:space:]]*$/ { after_meta=1; next }
      after_meta && /^### / { exit }
      after_meta { print }
    ' "$review_file" | sed '/^[[:space:]]*###/d' | sed '/^[[:space:]]*$/N;/^\n$/D')
  fi

  if [[ -z "$summary_text" ]]; then
    summary_text="Summary section not found in this review."
  fi

  {
    echo "## $package_name"
    echo ""
    echo "**[View full review]($REVIEWS_OUTPUT_DIR/${package_name}_security_review.md)**"
    echo ""
    echo "$summary_text"
    echo ""
  } >> "$TMP_DIR/$(echo "$severity" | tr '[:upper:]' '[:lower:]').md"

  # Count occurrences of each standardized issue label.
  sql_injection=$(grep -cE "Issue Type Label:[[:space:]]*SQL_INJECTION" "$review_file" || true)
  command_injection=$(grep -cE "Issue Type Label:[[:space:]]*COMMAND_INJECTION" "$review_file" || true)
  path_traversal=$(grep -cE "Issue Type Label:[[:space:]]*PATH_TRAVERSAL" "$review_file" || true)
  unsafe_deserialization=$(grep -cE "Issue Type Label:[[:space:]]*UNSAFE_DESERIALIZATION" "$review_file" || true)
  hardcoded_credential=$(grep -cE "Issue Type Label:[[:space:]]*HARDCODED_CREDENTIAL" "$review_file" || true)
  insecure_randomness=$(grep -cE "Issue Type Label:[[:space:]]*INSECURE_RANDOMNESS" "$review_file" || true)
  unsafe_eval_parse=$(grep -cE "Issue Type Label:[[:space:]]*UNSAFE_EVAL_PARSE" "$review_file" || true)
  xss=$(grep -cE "Issue Type Label:[[:space:]]*XSS" "$review_file" || true)
  unsafe_file_operation=$(grep -cE "Issue Type Label:[[:space:]]*UNSAFE_FILE_OPERATION" "$review_file" || true)
  authz_authn=$(grep -cE "Issue Type Label:[[:space:]]*AUTHZ_AUTHN" "$review_file" || true)
  memory_safety=$(grep -cE "Issue Type Label:[[:space:]]*MEMORY_SAFETY" "$review_file" || true)
  format_string=$(grep -cE "Issue Type Label:[[:space:]]*FORMAT_STRING" "$review_file" || true)
  integer_overflow=$(grep -cE "Issue Type Label:[[:space:]]*INTEGER_OVERFLOW" "$review_file" || true)
  dependency_risk=$(grep -cE "Issue Type Label:[[:space:]]*DEPENDENCY_RISK" "$review_file" || true)
  input_validation=$(grep -cE "Issue Type Label:[[:space:]]*INPUT_VALIDATION" "$review_file" || true)
  error_handling=$(grep -cE "Issue Type Label:[[:space:]]*ERROR_HANDLING" "$review_file" || true)
  deprecated_insecure_function=$(grep -cE "Issue Type Label:[[:space:]]*DEPRECATED_INSECURE_FUNCTION" "$review_file" || true)
  access_control=$(grep -cE "Issue Type Label:[[:space:]]*ACCESS_CONTROL" "$review_file" || true)
  other=$(grep -cE "Issue Type Label:[[:space:]]*OTHER" "$review_file" || true)

  echo "$package_name,$critical,$high,$medium,$low,$clean,$sql_injection,$command_injection,$path_traversal,$unsafe_deserialization,$hardcoded_credential,$insecure_randomness,$unsafe_eval_parse,$xss,$unsafe_file_operation,$authz_authn,$memory_safety,$format_string,$integer_overflow,$dependency_risk,$input_validation,$error_handling,$deprecated_insecure_function,$access_control,$other" >> "$CSV_TMP"
done

cp "$CSV_TMP" "$SEVERITY_MATRIX_CSV"

{
  echo "# Bioconductor Security Review Summary"
  echo ""
  echo "**Generated:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
  echo "**Model:** $GEMINI_MODEL"
  echo "**Packages reviewed:** $(find "$REVIEWS_OUTPUT_DIR" -name '*_security_review.md' | wc -l | tr -d ' ')"
  echo ""
  echo "---"
  echo ""

  if [[ -s "$CRITICAL_FILE" ]]; then
    echo "## 🔴 Critical"
    echo ""
    cat "$CRITICAL_FILE"
    echo ""
  fi

  if [[ -s "$HIGH_FILE" ]]; then
    echo "## 🟠 High"
    echo ""
    cat "$HIGH_FILE"
    echo ""
  fi

  if [[ -s "$MEDIUM_FILE" ]]; then
    echo "## 🟡 Medium"
    echo ""
    cat "$MEDIUM_FILE"
    echo ""
  fi

  if [[ -s "$LOW_FILE" ]]; then
    echo "## 🟢 Low"
    echo ""
    cat "$LOW_FILE"
    echo ""
  fi

  if [[ -s "$CLEAN_FILE" ]]; then
    echo "## ✅ Clean"
    echo ""
    cat "$CLEAN_FILE"
    echo ""
  fi
} > "$SECURITY_REPORT"

echo "==> Security summary written to $SECURITY_REPORT"
echo "==> Severity matrix CSV written to $SEVERITY_MATRIX_CSV"
echo "Completed: $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> "$PROGRESS_LOG"
