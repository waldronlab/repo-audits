#!/usr/bin/env python3
"""
security_review.py – AI-powered security review of an R/Bioconductor package.

Collects source files from REPO_DIR, builds a prompt from INSTRUCTIONS_PATH,
sends it to an OpenAI-compatible LLM, and writes the review to OUTPUT_FILE
(or stdout when OUTPUT_FILE is not set).

Required environment variables:
  REPO_DIR           – path to the cloned repository to review
  INSTRUCTIONS_PATH  – path to the instructions/prompt file
  OPENAI_API_KEY     – API key for the LLM provider

Optional environment variables:
  OPENAI_API_BASE    – API base URL (default: https://api.openai.com/v1)
  MODEL              – model name (default: gpt-4o)
  MAX_CHARS          – max total source-code characters to include (default: 200000)
  OUTPUT_FILE        – file path to write the review (default: stdout)
  REPO_NAME          – display name used in the prompt header (default: basename of REPO_DIR)
  BRANCH             – branch name used in the prompt header (default: devel)
"""
from __future__ import annotations

import os
import pathlib
import sys

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

NATIVE_EXTENSIONS = frozenset({
    ".c", ".cpp", ".cc", ".cxx",
    ".h", ".hpp",
    ".f", ".F", ".f90", ".F90", ".f95", ".F95",
})

LANG_MAP = {
    ".c": "c", ".h": "c",
    ".cpp": "cpp", ".cc": "cpp", ".cxx": "cpp", ".hpp": "cpp",
    ".f": "fortran", ".F": "fortran",
    ".f90": "fortran", ".F90": "fortran",
    ".f95": "fortran", ".F95": "fortran",
    ".R": "r", ".r": "r",
}

# Extra characters reserved for truncation notices and inter-block separators
_BLOCK_OVERHEAD_MARGIN = 60


def _require_env(name):
    val = os.environ.get(name, "").strip()
    if not val:
        sys.exit(f"ERROR: Required environment variable '{name}' is not set.")
    return val


def _opt_env(name, default=""):
    return os.environ.get(name, default).strip() or default


# ---------------------------------------------------------------------------
# File collection
# ---------------------------------------------------------------------------

def collect_source_files(repo_path: pathlib.Path) -> list[tuple[pathlib.Path, str]]:
    """Return (absolute_path, repo-relative_path) pairs in review priority order.

    Priority:
      1. DESCRIPTION and NAMESPACE (package metadata)
      2. Native code in src/ (highest security risk)
      3. R source files in R/
    """
    files: list[tuple[pathlib.Path, str]] = []

    # 1. Metadata
    for fname in ("DESCRIPTION", "NAMESPACE"):
        p = repo_path / fname
        if p.is_file():
            files.append((p, fname))

    # 2. Native code
    src_dir = repo_path / "src"
    if src_dir.is_dir():
        for p in sorted(src_dir.rglob("*")):
            if p.is_file() and p.suffix in NATIVE_EXTENSIONS:
                files.append((p, str(p.relative_to(repo_path))))

    # 3. R source files
    r_dir = repo_path / "R"
    if r_dir.is_dir():
        r_files = [
            p for p in r_dir.rglob("*")
            if p.is_file() and p.suffix.lower() == ".r"
        ]
        for p in sorted(r_files):
            files.append((p, str(p.relative_to(repo_path))))

    return files


# ---------------------------------------------------------------------------
# Prompt assembly
# ---------------------------------------------------------------------------

def build_code_content(
    files: list[tuple[pathlib.Path, str]],
    max_chars: int,
    repo_name: str,
    branch: str,
) -> tuple[str, int, int]:
    """Build the code-content string from *files* up to *max_chars* characters.

    Returns (content, included_count, total_count).
    """
    header = f"# Repository: {repo_name}\n# Branch: {branch}\n"
    parts = [header]
    total_chars = len(header)
    included = 0

    for abs_path, rel_path in files:
        lang = LANG_MAP.get(abs_path.suffix, "text")
        try:
            text = abs_path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            text = f"[Error reading file: {exc}]"

        block_header = f"\n## File: {rel_path}\n```{lang}\n"
        block_footer = "\n```\n"
        overhead = len(block_header) + len(block_footer)
        available = max_chars - total_chars - overhead - _BLOCK_OVERHEAD_MARGIN

        if available <= 0:
            break

        if len(text) > available:
            omitted = len(text) - available
            text = text[:available] + f"\n... [{omitted} characters omitted]"

        block = block_header + text + block_footer
        parts.append(block)
        total_chars += len(block)
        included += 1

    omitted_count = len(files) - included
    if omitted_count > 0:
        parts.append(
            f"\n_Note: {omitted_count} file(s) were omitted because the "
            "size limit was reached._\n"
        )

    if included == 0:
        parts.append("\n_No R or native source files were found in this repository._\n")

    return "".join(parts), included, len(files)


# ---------------------------------------------------------------------------
# LLM call
# ---------------------------------------------------------------------------

def call_llm(instructions: str, code_content: str, model: str, api_key: str, api_base: str) -> str:
    try:
        from openai import OpenAI  # type: ignore[import-untyped]
    except ImportError:
        sys.exit("ERROR: The 'openai' package is not installed. Run: pip install openai>=1.0.0")

    client = OpenAI(api_key=api_key, base_url=api_base)

    try:
        response = client.chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": instructions},
                {"role": "user", "content": code_content},
            ],
            temperature=0.1,
        )
    except Exception as exc:
        sys.exit(f"ERROR: LLM API call failed: {exc}")

    return response.choices[0].message.content or ""


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    repo_dir        = _require_env("REPO_DIR")
    instructions_path = _require_env("INSTRUCTIONS_PATH")
    api_key         = _require_env("OPENAI_API_KEY")

    model     = _opt_env("MODEL",           "gpt-4o")
    api_base  = _opt_env("OPENAI_API_BASE", "https://api.openai.com/v1")
    max_chars = int(_opt_env("MAX_CHARS",   "200000"))
    output_file = _opt_env("OUTPUT_FILE",   "")
    branch    = _opt_env("BRANCH",          "devel")

    repo_path = pathlib.Path(repo_dir)
    repo_name = _opt_env("REPO_NAME", repo_path.name)

    instructions = pathlib.Path(instructions_path).read_text(encoding="utf-8")

    files = collect_source_files(repo_path)
    code_content, included, total = build_code_content(files, max_chars, repo_name, branch)

    print(
        f"==> Collected {total} source file(s); including {included} in the review prompt "
        f"({len(code_content)} characters).",
        file=sys.stderr,
    )
    print(f"==> Calling model '{model}' at '{api_base}' …", file=sys.stderr)

    review = call_llm(instructions, code_content, model, api_key, api_base)

    if output_file:
        pathlib.Path(output_file).write_text(review, encoding="utf-8")
        print(f"==> Review written to '{output_file}'.", file=sys.stderr)
    else:
        print(review)


if __name__ == "__main__":
    main()
