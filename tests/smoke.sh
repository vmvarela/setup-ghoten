#!/usr/bin/env bash
# End-to-end smoke test, runnable outside Actions (macOS and Linux).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

VERSION="${SMOKE_GHOTEN_VERSION:-1.12.5}"

# Keep this in sync with lib/utils.sh without needing Actions-only plumbing here.
case "$(uname -s | tr '[:upper:]' '[:lower:]')" in
  linux) OS="linux" ;;
  darwin) OS="darwin" ;;
  *) echo "FAIL: unsupported OS for smoke test: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  i686|i386) ARCH="386" ;;
  *) echo "FAIL: unsupported arch for smoke test: $(uname -m)" >&2; exit 1 ;;
esac

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

CACHE="${WORK_DIR}/tool-cache"
INSTALL_DIR="${CACHE}/ghoten/${VERSION}/${ARCH}"

mkdir -p "$CACHE"
: >"${WORK_DIR}/path"; : >"${WORK_DIR}/output"; : >"${WORK_DIR}/env"
export RUNNER_TOOL_CACHE="$CACHE"
export GITHUB_PATH="${WORK_DIR}/path"
export GITHUB_OUTPUT="${WORK_DIR}/output"
export GITHUB_ENV="${WORK_DIR}/env"
unset TF_CLI_CONFIG_FILE

pass() { echo "PASS: $1"; }
abort() { echo "FAIL: $1" >&2; exit 1; }
assert_contains() { # assert_contains <file> <needle> <label>
  grep -qF -- "$2" "$1" || abort "$3"
  pass "$3"
}

# --- first run: fresh install ------------------------------------------------
if ! INPUT_GHOTEN_VERSION="$VERSION" bash lib/setup.sh >"${WORK_DIR}/setup1.log" 2>&1; then
  cat "${WORK_DIR}/setup1.log" >&2; abort "first setup run exited non-zero"
fi
cat "${WORK_DIR}/setup1.log"

assert_contains "$GITHUB_PATH" "$INSTALL_DIR" "GITHUB_PATH contains install dir"
assert_contains "$GITHUB_OUTPUT" "version=${VERSION}" "GITHUB_OUTPUT contains version=${VERSION}"
assert_contains "$GITHUB_ENV" "GHOTEN_CLI_PATH=${INSTALL_DIR}" "GITHUB_ENV contains GHOTEN_CLI_PATH"

[ -f "${INSTALL_DIR}/ghoten" ] || abort "wrapper script missing at ${INSTALL_DIR}/ghoten"
[ -f "${INSTALL_DIR}/ghoten-bin" ] || abort "real binary missing at ${INSTALL_DIR}/ghoten-bin"
pass "wrapper and real binary installed in ${INSTALL_DIR}"

# wrapper invocation: `ghoten version` reports the requested version
"$INSTALL_DIR/ghoten" version >"${WORK_DIR}/version.out" 2>"${WORK_DIR}/version.err" ||
  abort "wrapper invocation of 'ghoten version' failed"
SETUP_VERSION="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "${WORK_DIR}/version.out" | head -n1)"
[ "$SETUP_VERSION" = "$VERSION" ] || abort "ghoten version reported '${SETUP_VERSION}', expected '${VERSION}'"
pass "wrapper 'ghoten version' reports ${VERSION}"

# wrapper contract: exit 2 (detailed-exitcode with changes) is success, outputs captured
mv "${INSTALL_DIR}/ghoten-bin" "${WORK_DIR}/ghoten-bin.real"
printf '#!/bin/sh\necho "stub stdout"\necho "stub stderr" >&2\nexit 2\n' >"${INSTALL_DIR}/ghoten-bin"
chmod 755 "${INSTALL_DIR}/ghoten-bin"
: >"$GITHUB_OUTPUT"
"$INSTALL_DIR/ghoten" anything >"${WORK_DIR}/stub.out" 2>"${WORK_DIR}/stub.err" ||
  abort "wrapper reports exit code 2 as failure"
pass "wrapper invocation with child exit code 2 succeeds"
assert_contains "$GITHUB_OUTPUT" "exitcode=2" "GITHUB_OUTPUT contains exitcode=2"
assert_contains "$GITHUB_OUTPUT" "stub stdout" "GITHUB_OUTPUT contains captured stdout"
assert_contains "$GITHUB_OUTPUT" "stub stderr" "GITHUB_OUTPUT contains captured stderr"
mv "${WORK_DIR}/ghoten-bin.real" "${INSTALL_DIR}/ghoten-bin"

# --- second run: idempotent, no download --------------------------------------
if ! INPUT_GHOTEN_VERSION="$VERSION" bash lib/setup.sh >"${WORK_DIR}/setup2.log" 2>&1; then
  cat "${WORK_DIR}/setup2.log" >&2; abort "second setup run exited non-zero"
fi
grep -q "already installed" "${WORK_DIR}/setup2.log" || abort "second run did not log the skip"
! grep -q "downloading" "${WORK_DIR}/setup2.log" || abort "second run downloaded again"
pass "second run skips the download"

# --- unwrapping a warm cache (ghoten_wrapper=false) ---------------------------
: >"$GITHUB_ENV"
if ! INPUT_GHOTEN_VERSION="$VERSION" INPUT_GHOTEN_WRAPPER="false" \
     bash lib/setup.sh >"${WORK_DIR}/nowrapper.log" 2>&1; then
  cat "${WORK_DIR}/nowrapper.log" >&2; abort "ghoten_wrapper=false run exited non-zero"
fi
[ -f "${INSTALL_DIR}/ghoten" ] || abort "binary missing at ${INSTALL_DIR}/ghoten"
[ ! -f "${INSTALL_DIR}/ghoten-bin" ] || abort "ghoten-bin still present after ghoten_wrapper=false"
"${INSTALL_DIR}/ghoten" version | grep -qF "$VERSION" ||
  abort "unwrapped ghoten does not report ${VERSION}"
pass "ghoten_wrapper=false replaces the wrapper with the plain binary"

# --- wrong checksum fails ------------------------------------------------------
if INPUT_GHOTEN_VERSION="$VERSION" \
   INPUT_CHECKSUMS="0000000000000000000000000000000000000000000000000000000000000000  ghoten_${VERSION}_${OS}_${ARCH}.tar.gz" \
   RUNNER_TOOL_CACHE="${WORK_DIR}/wrong-cache" \
   bash lib/setup.sh >"${WORK_DIR}/checksum.log" 2>&1; then
  abort "mismatching checksums input should fail"
fi
grep -q "checksum mismatch" "${WORK_DIR}/checksum.log" || abort "failure was not a checksum mismatch"
pass "wrong INPUT_CHECKSUMS fails with checksum mismatch"

# --- version file precedence ---------------------------------------------------
printf 'ghoten  %s\nother-tool 9.9.9\n' "$VERSION" >"${WORK_DIR}/.tool-versions"
if ! INPUT_GHOTEN_VERSION="9.9.9" \
     INPUT_GHOTEN_VERSION_FILE="${WORK_DIR}/.tool-versions" \
     bash lib/setup.sh >"${WORK_DIR}/versionfile.log" 2>&1; then
  cat "${WORK_DIR}/versionfile.log" >&2; abort "version file run exited non-zero"
fi
grep -q "9\.9\.9" "${WORK_DIR}/versionfile.log" && abort "version input must not win over the version file"
grep -q "ghoten ${VERSION} (${OS}/${ARCH}) already installed" "${WORK_DIR}/versionfile.log" ||
  abort "asdf-style version file did not resolve to ${VERSION} in the warm cache"
pass "asdf-style version file wins over the version input"

# --- credentials and acceptance-test env (HOME sandboxed) ----------------------
: >"$GITHUB_ENV"
if ! INPUT_GHOTEN_VERSION="$VERSION" \
     HOME="${WORK_DIR}/home" \
     INPUT_CLI_CONFIG_CREDENTIALS_HOSTNAME="app.terraform.io" \
     INPUT_CLI_CONFIG_CREDENTIALS_TOKEN="dummy-token" \
     INPUT_PROVIDER_ACCEPTANCE_TESTS="true" \
     bash lib/setup.sh >"${WORK_DIR}/creds.log" 2>&1; then
  cat "${WORK_DIR}/creds.log" >&2; abort "credentials run exited non-zero"
fi
CREDS="${WORK_DIR}/home/.ghotenrc"
[ -f "$CREDS" ] || abort "credentials file missing at ${CREDS}"
grep -qF 'credentials "app.terraform.io"' "$CREDS" || abort "credentials block hostname missing"
grep -qF 'token = "dummy-token"' "$CREDS" || abort "credentials block token missing"
[ "$(find "$CREDS" -maxdepth 0 -perm 600 | wc -l | tr -d ' ')" = "1" ] ||
  abort "credentials file mode is not 600 (mode: $(stat -f '%Lp' "$CREDS" 2>/dev/null || stat -c '%a' "$CREDS" 2>/dev/null))"
pass "credentials file written with mode 600"
assert_contains "$GITHUB_ENV" "TF_ACC=1" "GITHUB_ENV contains TF_ACC=1"
assert_contains "$GITHUB_ENV" "TF_ACC_TERRAFORM_PATH=${INSTALL_DIR}/ghoten-bin" "GITHUB_ENV points TF_ACC_TERRAFORM_PATH at the real binary"

echo "smoke: all assertions passed"
