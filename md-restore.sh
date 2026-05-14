#!/usr/bin/env bash
# mdwrap
# Restore or run the original source file embedded inside a Markdown wrapper.
#
# Expected wrapper markers:
#   source_file: "/absolute/path/to/original.ext"
#   <!-- ORIGINAL_FILE_BASE64_BEGIN -->
#   base64...
#   <!-- ORIGINAL_FILE_BASE64_END -->
#
# Usage:
#   mdwrap restore "/path/to/wrapper.md"
#   mdwrap restore --force "/path/to/wrapper.md"
#   mdwrap run "/path/to/wrapper.md"
#   mdwrap info "/path/to/wrapper.md"

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  mdwrap restore [--force] WRAPPER.md   Restore embedded original if missing
  mdwrap run WRAPPER.md                 Restore if missing, then run source appropriately
  mdwrap info WRAPPER.md                Show detected metadata
  mdwrap extract-base64 WRAPPER.md      Print embedded Base64 payload

Notes:
  - restore will not overwrite an existing original unless --force is used.
  - run dispatches by extension:
      .applescript/.scpt -> osascript
      .sh/.bash          -> bash
      .zsh               -> zsh
      .py                -> python3
      .js/.mjs           -> node
      .rb                -> ruby
      .pl                -> perl
      .command           -> bash
USAGE
}

die() {
  printf '❌ %s\n' "$*" >&2
  exit 1
}

ok() {
  printf '✅ %s\n' "$*" >&2
}

decode_base64() {
  if base64 --help 2>/dev/null | grep -q -- '-d'; then
    base64 -d
  else
    base64 -D
  fi
}

url_decode_file_url() {
  # Converts file:/// URLs to POSIX paths when python3 is available.
  # Falls back to stripping file:// if Python is unavailable.
  local url="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$url" <<'PY'
import sys
from urllib.parse import urlparse, unquote
u = sys.argv[1]
p = urlparse(u)
if p.scheme == "file":
    print(unquote(p.path))
else:
    print(unquote(u))
PY
  else
    printf '%s\n' "${url#file://}"
  fi
}

get_yaml_value() {
  # Naive but practical YAML frontmatter scalar extractor.
  # Supports:
  #   key: "/path with spaces"
  #   key: '/path with spaces'
  #   key: /path with spaces
  local key="$1"
  local file="$2"
  awk -v key="$key" '
    BEGIN { in_yaml=0 }
    NR==1 && $0=="---" { in_yaml=1; next }
    in_yaml && $0=="---" { exit }
    in_yaml && index($0, key ":") == 1 {
      sub("^[^:]+:[[:space:]]*", "", $0)
      print
      exit
    }
  ' "$file" | sed -E 's/^"//; s/"$//; s/^'\''//; s/'\''$//'
}

wrapper_path_from_arg() {
  local arg="${1:-}"
  [[ -n "$arg" ]] || die "No Markdown wrapper path supplied."

  case "$arg" in
    file://*) url_decode_file_url "$arg" ;;
    *) printf '%s\n' "$arg" ;;
  esac
}

source_path_from_wrapper() {
  local wrapper="$1"
  local src
  src="$(get_yaml_value source_file "$wrapper")"
  [[ -n "$src" ]] || die "Could not find source_file in YAML frontmatter: $wrapper"
  printf '%s\n' "$src"
}

extract_base64() {
  local wrapper="$1"
  awk '
    /<!-- ORIGINAL_FILE_BASE64_BEGIN -->/ { capture=1; next }
    /<!-- ORIGINAL_FILE_BASE64_END -->/ { capture=0; exit }
    capture { print }
  ' "$wrapper"
}

format_info() {
  local wrapper="$1"
  local src
  src="$(source_path_from_wrapper "$wrapper")"

  printf 'Wrapper: %s\n' "$wrapper"
  printf 'Source:  %s\n' "$src"
  if [[ -f "$src" ]]; then
    printf 'Status:  source exists\n'
  else
    printf 'Status:  source missing\n'
  fi

  local payload_size
  payload_size="$(extract_base64 "$wrapper" | wc -c | tr -d ' ')"
  printf 'Payload: %s base64 bytes\n' "$payload_size"
}

restore_original() {
  local force="0"

  if [[ "${1:-}" == "--force" ]]; then
    force="1"
    shift
  fi

  local wrapper
  wrapper="$(wrapper_path_from_arg "${1:-}")"
  [[ -f "$wrapper" ]] || die "Wrapper does not exist: $wrapper"

  local src
  src="$(source_path_from_wrapper "$wrapper")"

  if [[ -e "$src" && "$force" != "1" ]]; then
    ok "Original already exists; not overwriting: $src"
    return 0
  fi

  local b64
  b64="$(extract_base64 "$wrapper")"
  [[ -n "$b64" ]] || die "No embedded ORIGINAL_FILE_BASE64 payload found in: $wrapper"

  mkdir -p "$(dirname "$src")"

  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/mdwrap-restore.XXXXXX")"
  printf '%s\n' "$b64" | decode_base64 > "$tmp"

  mv "$tmp" "$src"

  case "${src##*.}" in
    sh|bash|zsh|py|rb|pl|command)
      chmod +x "$src" 2>/dev/null || true
      ;;
  esac

  ok "Restored original: $src"
}

run_source() {
  local wrapper
  wrapper="$(wrapper_path_from_arg "${1:-}")"
  [[ -f "$wrapper" ]] || die "Wrapper does not exist: $wrapper"

  local src
  src="$(source_path_from_wrapper "$wrapper")"

  if [[ ! -f "$src" ]]; then
    restore_original "$wrapper"
  fi

  [[ -f "$src" ]] || die "Source still missing after restore attempt: $src"

  local ext
  ext="$(printf '%s' "${src##*.}" | tr '[:upper:]' '[:lower:]')"

  case "$ext" in
    applescript|scpt)
      exec osascript "$src"
      ;;
    sh|bash)
      exec bash "$src"
      ;;
    zsh)
      exec zsh "$src"
      ;;
    py|python)
      command -v python3 >/dev/null 2>&1 || die "python3 not found"
      exec python3 "$src"
      ;;
    js|mjs)
      command -v node >/dev/null 2>&1 || die "node not found"
      exec node "$src"
      ;;
    rb)
      exec ruby "$src"
      ;;
    pl)
      exec perl "$src"
      ;;
    command)
      exec bash "$src"
      ;;
    *)
      if [[ -x "$src" ]]; then
        exec "$src"
      fi
      die "No run rule for .$ext. Open it with an editor/app instead: $src"
      ;;
  esac
}

main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    restore)
      restore_original "$@"
      ;;
    run)
      run_source "$@"
      ;;
    info)
      local wrapper
      wrapper="$(wrapper_path_from_arg "${1:-}")"
      [[ -f "$wrapper" ]] || die "Wrapper does not exist: $wrapper"
      format_info "$wrapper"
      ;;
    extract-base64)
      local wrapper
      wrapper="$(wrapper_path_from_arg "${1:-}")"
      [[ -f "$wrapper" ]] || die "Wrapper does not exist: $wrapper"
      extract_base64 "$wrapper"
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      die "Unknown command: $cmd"
      ;;
  esac
}

main "$@"
