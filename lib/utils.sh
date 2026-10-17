#!/usr/bin/env bash
# Shared helpers for the setup-ghoten action. Sourced, never executed: no side effects.

log() {
  echo "[setup-ghoten] $*"
}

warn() {
  echo "::warning::[setup-ghoten] $*"
}

fail() {
  echo "::error::[setup-ghoten] $*" >&2
  exit 1
}

debug() {
  if [ "${RUNNER_DEBUG:-}" = "1" ] || [ "${ACTIONS_STEP_DEBUG:-}" = "true" ]; then
    log "DEBUG: $*"
  fi
}

mask_secret() {
  echo "::add-mask::$1"
}

detect_os() {
  local kernel lower
  kernel="$(uname -s)"
  # tr, not ${kernel,,}: macOS runners come with bash 3.2.
  lower="$(printf '%s' "$kernel" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    linux|darwin|freebsd|netbsd|openbsd|solaris) echo "$lower" ;;
    mingw*|msys*|cygwin*) echo "windows" ;;
    *) fail "unsupported operating system: '$kernel'" ;;
  esac
}

detect_arch() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) echo "amd64" ;;
    i686|i386) echo "386" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv6l|arm) echo "arm" ;;
    *) fail "unsupported architecture: '$machine'" ;;
  esac
}

sha256_file() {
  [ $# -eq 1 ] || fail "sha256_file expects exactly one argument"
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    fail "no SHA-256 tool available (need sha256sum or shasum)"
  fi
}

fetch_to_file() {
  [ $# -eq 2 ] || fail "fetch_to_file expects <url> <dest>"
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url"
  else
    fail "no download tool available (need curl or wget)"
  fi
}

# fetch_to_stdout <url> [extra curl args...]
# Extra args are only supported for curl (used for the auth header).
fetch_to_stdout() {
  [ $# -ge 1 ] || fail "fetch_to_stdout expects <url> [extra curl args...]"
  local url="$1"
  shift
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$@" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$url"
  else
    fail "no download tool available (need curl or wget)"
  fi
}

# trim: strip surrounding whitespace (including CR) and surrounding quotes.
trim() {
  local var="$1"
  var="${var#"${var%%[![:space:]]*}"}"
  var="${var%"${var##*[![:space:]]}"}"
  echo "$var"
}
