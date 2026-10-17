#!/usr/bin/env bash
# setup-ghoten action entry point. Installs the Ghoten CLI and wires PATH/env/outputs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/utils.sh
source "${SCRIPT_DIR}/utils.sh"

# ---------------------------------------------------------------------------
# 1. Inputs (with defaults so the script also runs outside Actions)
# ---------------------------------------------------------------------------

INPUT_GHOTEN_VERSION="${INPUT_GHOTEN_VERSION:-latest}"
INPUT_GHOTEN_VERSION_FILE="${INPUT_GHOTEN_VERSION_FILE:-.ghoten-version}"
INPUT_GHOTEN_WRAPPER="${INPUT_GHOTEN_WRAPPER:-true}"
INPUT_CHECKSUMS="${INPUT_CHECKSUMS:-}"
INPUT_GHOTEN_GITHUB_TOKEN="${INPUT_GHOTEN_GITHUB_TOKEN:-}"
INPUT_CLI_CONFIG_CREDENTIALS_HOSTNAME="${INPUT_CLI_CONFIG_CREDENTIALS_HOSTNAME:-app.terraform.io}"
INPUT_CLI_CONFIG_CREDENTIALS_TOKEN="${INPUT_CLI_CONFIG_CREDENTIALS_TOKEN:-}"
INPUT_PROVIDER_ACCEPTANCE_TESTS="${INPUT_PROVIDER_ACCEPTANCE_TESTS:-false}"

if [ -n "${INPUT_GHOTEN_GITHUB_TOKEN:-}" ]; then
  mask_secret "$INPUT_GHOTEN_GITHUB_TOKEN"
fi
if [ -n "${INPUT_CLI_CONFIG_CREDENTIALS_TOKEN:-}" ]; then
  mask_secret "$INPUT_CLI_CONFIG_CREDENTIALS_TOKEN"
fi

# Guarded workflow-file writes: work outside Actions too.
write_output() { # write_output <file-var-name> <key> <value> [heredoc-delimiter]
  local file_var="$1" key="$2" value="$3" delim="${4:-}"
  local file="${!file_var:-}"
  if [ -z "$file" ]; then
    debug "skipping ${key}= write: \$$file_var is not set"
    return 0
  fi
  if [ -n "$delim" ]; then
    {
      echo "${key}<<${delim}"
      echo "$value"
      echo "${delim}"
    } >>"$file"
  else
    echo "${key}=${value}" >>"$file"
  fi
}

append_env() { # append_env <key> <value>
  local file="${GITHUB_ENV:-}"
  if [ -z "$file" ]; then
    debug "skipping $1 export: \$GITHUB_ENV is not set"
    return 0
  fi
  echo "$1=$2" >>"$file"
}

append_path() { # append_path <dir>
  local file="${GITHUB_PATH:-}"
  if [ -z "$file" ]; then
    debug "skipping PATH append: \$GITHUB_PATH is not set"
    return 0
  fi
  echo "$1" >>"$file"
}

# ---------------------------------------------------------------------------
# 2. Version resolution
# ---------------------------------------------------------------------------

resolve_version() {
  local version=""
  local file="$INPUT_GHOTEN_VERSION_FILE"

  if [ -n "$file" ]; then
    if [ -r "$file" ]; then
      local content line
      content="$(trim "$(cat "$file")")"
      # asdf-style .tool-versions may hold several tools; take the ghoten entry.
      line="$(grep -oE '^[[:space:]]*ghoten[[:space:]]+[^[:space:]#]+' "$file" 2>/dev/null | awk 'NR==1{print $2}')" || true
      if [ -n "$line" ]; then
        content="$line"
      fi
      if [ -n "$content" ]; then
        version="$content"
        debug "version '$version' resolved from version file '$file'"
      else
        warn "version file '$file' is empty; falling back to ghoten_version input"
      fi
    else
      debug "version file '$file' not readable; using ghoten_version input"
    fi
  fi

  if [ -z "$version" ]; then
    version="$INPUT_GHOTEN_VERSION"
  fi

  if [ "$version" = "latest" ]; then
    local api_url="https://api.github.com/repos/vmvarela/ghoten/releases/latest"
    local json tag
    if [ -n "$INPUT_GHOTEN_GITHUB_TOKEN" ]; then
      json="$(fetch_to_stdout "$api_url" -H "Authorization: Bearer $INPUT_GHOTEN_GITHUB_TOKEN")" ||
        fail "failed to query latest ghoten release from GitHub API"
    else
      json="$(fetch_to_stdout "$api_url")" ||
        fail "failed to query latest ghoten release from GitHub API"
    fi
    tag="$(echo "$json" | jq -r '.tag_name // empty')" ||
      fail "failed to parse latest release tag (is jq installed?)"
    [ -n "$tag" ] || fail "could not resolve latest ghoten release (empty tag_name)"
    version="${tag#v}"
    log "resolved latest version: $version"
  else
    version="${version#v}"
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
      fail "invalid ghoten version '$version': only 'latest' or an exact version (X.Y.Z) is supported; semver ranges are deliberately unsupported"
    fi
  fi

  echo "$version"
}

VERSION="$(resolve_version)"

# ---------------------------------------------------------------------------
# 3-4. Platform and install location
# ---------------------------------------------------------------------------

OS="$(detect_os)"
ARCH="$(detect_arch)"

EXE=""
[ "$OS" = "windows" ] && EXE=".exe"

INSTALL_ROOT="${RUNNER_TOOL_CACHE:-${HOME}/.ghoten-tool-cache}"
INSTALL_DIR="${INSTALL_ROOT}/ghoten/${VERSION}/${ARCH}"
mkdir -p "$INSTALL_DIR"

RELEASE_BASE="https://github.com/vmvarela/ghoten/releases/download/v${VERSION}"
# Candidate extensions: recent releases ship Windows only as .zip, older ones
# ship both .zip and .tar.gz for everything — try both, newest convention first.
case "$OS" in
  windows) ARCHIVE_EXTENSIONS="zip tar.gz" ;;
  *) ARCHIVE_EXTENSIONS="tar.gz zip" ;;
esac
BINARY_NAME="ghoten${EXE}"

# ---------------------------------------------------------------------------
# 5-6. Download, verify, extract (skipped when already installed)
# ---------------------------------------------------------------------------

install_binary() {
  if [ -f "${INSTALL_DIR}/ghoten-bin${EXE}" ] || [ -f "${INSTALL_DIR}/${BINARY_NAME}" ]; then
    log "ghoten ${VERSION} (${OS}/${ARCH}) already installed at ${INSTALL_DIR}; skipping download"
    return 0
  fi

  # Global on purpose: the EXIT trap below references it after the function returns.
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  # Try each published extension for this OS; remember every tried URL so the
  # failure message can list them (honest message for platforms not published).
  local archive_path=""; ARCHIVE_NAME="";
  local tried_urls=() url ext archive_done
  for ext in $ARCHIVE_EXTENSIONS; do
    archive_done="ghoten_${VERSION}_${OS}_${ARCH}.${ext}"
    url="${RELEASE_BASE}/${archive_done}"
    local candidate="${tmpdir}/${archive_done}"
    log "downloading ${url}"
    if ! fetch_to_file "$url" "$candidate" 2>"${tmpdir}/curl.err"; then
      debug "download failed for ${url}: $(cat "${tmpdir}/curl.err")"
      tried_urls+=("$url")
      continue
    fi
    archive_path="$candidate"
    ARCHIVE_NAME="$archive_done"
    break
  done
  if [ -z "$archive_path" ]; then
    fail "Ghoten ${VERSION} is not available for ${OS}/${ARCH}: tried ${tried_urls[*]}"
  fi

  local archive="${archive_path}"
  local checksum_file expected received
  received="$(sha256_file "$archive")"

  if [ -n "$INPUT_CHECKSUMS" ]; then
    # User-supplied checksums replace the release checksum file entirely.
    expected=""
    while IFS= read -r line; do
      line="${line#*\*}" # tolerate "<hash> *<file>" (binary-mode) entries
      line="$(trim "$line")"
      if [[ "$line" =~ ^[0-9a-fA-F]{64}[[:space:]]+${ARCHIVE_NAME}[[:space:]]*$ ]]; then
        expected="${line%%[[:space:]]*}"
        break
      fi
    done <<EOF
$INPUT_CHECKSUMS
EOF
    if [ -z "$expected" ]; then
      fail "checksums input does not contain an entry for ${ARCHIVE_NAME}"
    fi
  else
    # Strict: a missing/unfetchable checksum file fails the step (deliberate
    # difference from setup-opentofu, which only warns).
    checksum_file=""
    local base_url="https://github.com/vmvarela/ghoten/releases/download/v${VERSION}"
    if fetch_to_file "${base_url}/ghoten_${VERSION}_SHA256SUMS" "${tmpdir}/checksums" 2>/dev/null; then
      checksum_file="${tmpdir}/checksums"
    elif fetch_to_file "${base_url}/sha256sums.txt" "${tmpdir}/checksums" 2>/dev/null; then
      checksum_file="${tmpdir}/checksums"
    else
      fail "could not fetch checksum file (ghoten_${VERSION}_SHA256SUMS or sha256sums.txt) for ghoten ${VERSION}"
    fi
    expected="$(grep -E "^[0-9a-fA-F]{64}[[:space:]]+\*?${ARCHIVE_NAME}\$" "$checksum_file" | awk '{print $1}' | head -n1)"
    if [ -z "$expected" ]; then
      fail "checksum file does not list ${ARCHIVE_NAME} for ghoten ${VERSION}"
    fi
  fi

  if [ "$received" != "$expected" ]; then
    fail "checksum mismatch for ${ARCHIVE_NAME}: received ${received}, expected ${expected}"
  fi
  log "checksum verified: ${received}"

  extract_archive "$archive" "$INSTALL_DIR"
  [ -f "${INSTALL_DIR}/${BINARY_NAME}" ] ||
    fail "archive extracted but ${BINARY_NAME} is missing from ${INSTALL_DIR}"
  chmod 755 "${INSTALL_DIR}/${BINARY_NAME}"
}

install_binary

# ---------------------------------------------------------------------------
# 7. Wrapper
# ---------------------------------------------------------------------------

# shortcut: output is replayed after the command finishes, loses live streaming;
# upgrade to a streaming tee when the captured-output race is solved.
install_wrapper() {
  local real="ghoten-bin${EXE}" wrapper="${BINARY_NAME}"

  if [ "$INPUT_GHOTEN_WRAPPER" != "true" ]; then
    # A warm cache may hold the wrapped pair from an earlier run: "${BINARY_NAME}"
    # is then the wrapper script, so drop it before restoring the real binary.
    if [ -f "${INSTALL_DIR}/${real}" ]; then
      rm -f "${INSTALL_DIR}/${BINARY_NAME}"
      mv "${INSTALL_DIR}/${real}" "${INSTALL_DIR}/${BINARY_NAME}"
    fi
    append_env "GHOTEN_CLI_PATH" "$INSTALL_DIR"
    return 0
  fi

  if [ ! -f "${INSTALL_DIR}/ghoten-bin${EXE}" ]; then
    mv "${INSTALL_DIR}/${BINARY_NAME}" "${INSTALL_DIR}/${real}"
  fi

  cat >"${INSTALL_DIR}/${wrapper}" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${dir}/ghoten-bin__BIN_EXE__"
tmp_out="$(mktemp)" tmp_err="$(mktemp)"
trap 'rm -f "$tmp_out" "$tmp_err"' EXIT
status=0
"$bin" "$@" >"$tmp_out" 2>"$tmp_err" || status=$?
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "stdout<<GHOTEN_WRAPPER_STDOUT"
    cat "$tmp_out"
    echo "GHOTEN_WRAPPER_STDOUT"
    echo "stderr<<GHOTEN_WRAPPER_STDERR"
    cat "$tmp_err"
    echo "GHOTEN_WRAPPER_STDERR"
    echo "exitcode=${status}"
  } >>"$GITHUB_OUTPUT"
fi
cat "$tmp_out"
cat "$tmp_err" >&2
# exit 2 means "-detailed-exitcode" with pending changes: treat as success
if [ "$status" -eq 0 ] || [ "$status" -eq 2 ]; then
  exit 0
fi
exit "$status"
EOF
  # __BIN_EXE__ avoids a runtime env dependency; EXE is "" or ".exe" (no slashes).
  sed -i.bak "s/__BIN_EXE__/${EXE}/g" "${INSTALL_DIR}/${wrapper}" && rm -f "${INSTALL_DIR}/${wrapper}.bak"
  chmod 755 "${INSTALL_DIR}/${wrapper}"
  append_env "GHOTEN_CLI_PATH" "$INSTALL_DIR"
}

install_wrapper

# ---------------------------------------------------------------------------
# 8. PATH
# ---------------------------------------------------------------------------

append_path "$INSTALL_DIR"

# ---------------------------------------------------------------------------
# 9. CLI credentials
# ---------------------------------------------------------------------------

configure_credentials() {
  [ -n "$INPUT_CLI_CONFIG_CREDENTIALS_TOKEN" ] || return 0

  local config_file
  if [ -n "${TF_CLI_CONFIG_FILE:-}" ]; then
    config_file="$TF_CLI_CONFIG_FILE"
  elif [ "$OS" = "windows" ]; then
    config_file="${APPDATA:-${HOME}/AppData/Roaming}/ghoten.rc"
  else
    config_file="${HOME}/.ghotenrc"
  fi

  mkdir -p "$(dirname "$config_file")"
  cat >"$config_file" <<EOF
credentials "${INPUT_CLI_CONFIG_CREDENTIALS_HOSTNAME}" {
  token = "${INPUT_CLI_CONFIG_CREDENTIALS_TOKEN}"
}
EOF
  chmod 600 "$config_file"
  log "wrote ghoten CLI credentials to ${config_file}"
}

configure_credentials

# ---------------------------------------------------------------------------
# 10. Provider acceptance tests
# ---------------------------------------------------------------------------

configure_acceptance_tests() {
  [ "$INPUT_PROVIDER_ACCEPTANCE_TESTS" = "true" ] || return 0

  local cli_path
  if [ "$INPUT_GHOTEN_WRAPPER" = "true" ]; then
    cli_path="${INSTALL_DIR}/ghoten-bin${EXE}"
  else
    cli_path="${INSTALL_DIR}/${BINARY_NAME}"
  fi

  append_env "TF_ACC" "1"
  append_env "TF_ACC_PROVIDER_NAMESPACE" "hashicorp"
  append_env "TF_ACC_PROVIDER_HOST" "https://registry.opentofu.org"
  append_env "TF_ACC_TERRAFORM_PATH" "$cli_path"
}

configure_acceptance_tests

# ---------------------------------------------------------------------------
# 11. Outputs and summary
# ---------------------------------------------------------------------------

write_output "GITHUB_OUTPUT" "version" "$VERSION"

log "installed ghoten ${VERSION} (${OS}/${ARCH})"

# Run the REAL binary so the wrapper does not pollute step outputs.
if [ "$INPUT_GHOTEN_WRAPPER" = "true" ]; then
  "${INSTALL_DIR}/ghoten-bin${EXE}" version || true
else
  "${INSTALL_DIR}/${BINARY_NAME}" version || true
fi

log "summary: ghoten=${VERSION} os=${OS} arch=${ARCH} dir=${INSTALL_DIR} wrapper=${INPUT_GHOTEN_WRAPPER}"
