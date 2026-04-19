#!/usr/bin/env bash
set -euo pipefail

# Resolve script and workspace paths.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_BASE="${ROOT_DIR}/.tmp"
LOG_FILE="${ROOT_DIR}/log.txt"
OUTPUT_DMG="${ROOT_DIR}/Codex-Intel.dmg"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
WORK_DIR="${TMP_BASE}/codex_intel_build_${RUN_ID}"
MOUNT_POINT="${WORK_DIR}/mount"
EXPECTED_SOURCE_BUNDLE_ID="${EXPECTED_SOURCE_BUNDLE_ID:-com.openai.codex}"
EXPECTED_SIGNER_NAME="${EXPECTED_SIGNER_NAME:-OpenAI}"

# Runtime flags/state used by cleanup and mount logic.
ATTACHED_BY_SCRIPT=0
SOURCE_APP=""

timestamp() {
  date "+%Y-%m-%d %H:%M:%S"
}

log() {
  printf "[%s] %s\n" "$(timestamp)" "$*"
}

progress() {
  local percent="$1"
  shift
  log "[${percent}%%] $*"
}

die() {
  log "ERROR: $*"
  exit 1
}

extract_asar_file() {
  local asar_path="$1"
  local source_path="$2"
  local destination_path="$3"

  rm -f "${destination_path}"
  rm -f package.json
  npx --yes @electron/asar extract-file "${asar_path}" "${source_path}" >/dev/null 2>&1 || return 1
  mv package.json "${destination_path}"
}

normalize_codex_version_candidate() {
  local candidate="$1"
  local version=""

  version="$(printf '%s' "${candidate}" | grep -Eo '([0-9]+\.){2}[0-9]+([-.][0-9A-Za-z]+)*' | head -n 1 || true)"
  version="$(printf '%s' "${version}" | sed -E 's/-darwin-(arm64|x64)$//')"
  printf '%s' "${version}"
}

detect_codex_version_from_binary_strings() {
  local codex_bin="$1"
  local version=""

  [[ -f "${codex_bin}" ]] || return 1

  # Strategy 1: version string appears as a standalone line (most reliable)
  version="$(
    strings "${codex_bin}" 2>/dev/null | \
      grep -E '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$' | \
      grep -E '^0\.' | \
      head -n 1 || true
  )"

  # Strategy 2: embedded in known patterns
  if [[ -z "${version}" ]]; then
    version="$(
      strings "${codex_bin}" 2>/dev/null | sed -nE \
        -e 's/.*Update available!(([0-9]+\.){2}[0-9]+([-.][0-9A-Za-z]+)*)See full release notes:.*/\1/p' \
        -e 's/.*Cli(([0-9]+\.){2}[0-9]+([-.][0-9A-Za-z]+)*)DiffCommand.*/\1/p' | \
        head -n 1
    )"
  fi

  version="$(normalize_codex_version_candidate "${version}")"
  [[ -n "${version}" ]] || return 1

  printf '%s' "${version}"
}

detect_codex_version_from_binary() {
  local codex_bin="$1"
  local version_output=""
  local version=""
  local fake_home="${WORK_DIR}/codex-version-home"

  [[ -x "${codex_bin}" ]] || return 1
  mkdir -p "${fake_home}"

  version_output="$(
    HOME="${fake_home}" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    TERM="xterm-256color" \
    "${codex_bin}" --version 2>&1 || true
  )"

  version="$(printf '%s\n' "${version_output}" | sed -nE 's/.*codex-cli[[:space:]]+([^[:space:]]+).*/\1/p' | tail -n 1)"
  version="$(normalize_codex_version_candidate "${version}")"
  [[ -n "${version}" ]] || return 1

  printf '%s' "${version}"
}

validate_source_app() {
  local signing_info_file="${WORK_DIR}/source-app-signing.txt"
  local bundle_id=""
  local team_id=""

  progress 15 "Validating source app identity"
  codesign -dv --verbose=4 "${SOURCE_APP}" >/dev/null 2>"${signing_info_file}" || \
    die "Source app is not code-signed. Please use the official Codex.dmg from OpenAI."

  if grep -q '^Signature=adhoc$' "${signing_info_file}"; then
    die "Source app uses ad-hoc signing, which does not look like an official OpenAI release."
  fi

  if ! grep -Eq "^Authority=.*${EXPECTED_SIGNER_NAME}" "${signing_info_file}"; then
    die "Source app signer does not appear to match the expected Developer ID certificate."
  fi

  team_id="$(sed -n 's/^TeamIdentifier=//p' "${signing_info_file}" | head -n 1)"
  [[ -n "${team_id}" ]] || die "Source app signature is missing TeamIdentifier metadata."

  bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${SOURCE_APP}/Contents/Info.plist" 2>/dev/null || true)"
  [[ -n "${bundle_id}" ]] || die "Cannot read source app bundle identifier."
  [[ "${bundle_id}" == "${EXPECTED_SOURCE_BUNDLE_ID}" ]] || \
    die "Unexpected source app bundle identifier: ${bundle_id} (expected ${EXPECTED_SOURCE_BUNDLE_ID})."

  log "Validated source app bundle id: ${bundle_id}"
  log "Validated source app TeamIdentifier: ${team_id}"
}

usage() {
  cat <<'EOF'
Usage:
  ./scripts/build-intel.sh [path/to/Codex.dmg]

Behavior:
  - Reads source DMG from ../Codex.dmg by default (or explicit path argument)
  - Never modifies the original DMG
  - Uses .tmp/* for all build steps
  - Writes full logs to log.txt
  - Produces ../Codex-Intel.dmg
EOF
}

run_with_timeout() {
  local timeout_seconds="$1"
  shift
  perl -e 'alarm shift @ARGV; exec @ARGV' "${timeout_seconds}" "$@"
}

format_duration() {
  local total_seconds="$1"
  local minutes=$((total_seconds / 60))
  local seconds=$((total_seconds % 60))

  if [[ "${minutes}" -gt 0 ]]; then
    printf "%dm%02ds" "${minutes}" "${seconds}"
  else
    printf "%ds" "${seconds}"
  fi
}

format_tenths_percent() {
  local tenths="$1"
  printf "%d.%d" $((tenths / 10)) $((tenths % 10))
}

run_with_estimated_progress() {
  local start_percent="$1"
  local end_percent="$2"
  local timeout_seconds="$3"
  local label="$4"
  shift 4

  local start_tenths=$((start_percent * 10))
  local end_tenths=$((end_percent * 10))
  local range_tenths=$((end_tenths - start_tenths))
  local last_reported_tenths="${start_tenths}"
  local heartbeat_seconds=0
  local start_time elapsed estimated_tenths current_percent

  "$@" &
  local command_pid=$!
  start_time="$(date +%s)"

  while kill -0 "${command_pid}" >/dev/null 2>&1; do
    sleep 5

    if ! kill -0 "${command_pid}" >/dev/null 2>&1; then
      break
    fi

    elapsed=$(( $(date +%s) - start_time ))
    estimated_tenths=$((start_tenths + (elapsed * range_tenths / timeout_seconds)))
    if [[ "${estimated_tenths}" -gt "${end_tenths}" ]]; then
      estimated_tenths="${end_tenths}"
    fi

    if [[ "${estimated_tenths}" -gt "${last_reported_tenths}" ]]; then
      last_reported_tenths="${estimated_tenths}"
      current_percent="$(format_tenths_percent "${last_reported_tenths}")"
      progress "${current_percent}" "${label} (estimated, elapsed $(format_duration "${elapsed}") / timeout $(format_duration "${timeout_seconds}"))"
      heartbeat_seconds=0
    else
      heartbeat_seconds=$((heartbeat_seconds + 5))
      if [[ "${heartbeat_seconds}" -ge 30 ]]; then
        current_percent="$(format_tenths_percent "${last_reported_tenths}")"
        progress "${current_percent}" "${label} (still running, elapsed $(format_duration "${elapsed}") / timeout $(format_duration "${timeout_seconds}"))"
        heartbeat_seconds=0
      fi
    fi
  done

  wait "${command_pid}"
}

cleanup() {
  local exit_code=$?

  # Detach only if this script mounted the DMG itself.
  if [[ "${ATTACHED_BY_SCRIPT}" -eq 1 && -d "${MOUNT_POINT}" ]]; then
    hdiutil detach "${MOUNT_POINT}" >/dev/null 2>&1 || hdiutil detach -force "${MOUNT_POINT}" >/dev/null 2>&1 || true
  fi

  if [[ ${exit_code} -ne 0 ]]; then
    log "Build failed. See ${LOG_FILE}"
    log "Temporary files kept at: ${WORK_DIR}"
  fi
}
trap cleanup EXIT

# Prepare log file and mirror output to console + log.txt.
mkdir -p "${TMP_BASE}"
: > "${LOG_FILE}"
if [[ "${CODEX_INTEL_NO_TEE:-0}" == "1" ]]; then
  exec >> "${LOG_FILE}" 2>&1
else
  exec > >(tee -a "${LOG_FILE}") 2>&1
fi

log "Starting Intel build pipeline"
log "Script dir: ${SCRIPT_DIR}"
log "Project root: ${ROOT_DIR}"
log "Default source location: ${ROOT_DIR}/Codex.dmg"
log "Default DMG output: ${OUTPUT_DMG}"
log "Work dir: ${WORK_DIR}"
mkdir -p "${WORK_DIR}"

# Validate required tools early.
for cmd in hdiutil ditto npm npx node file codesign xattr; do
  command -v "${cmd}" >/dev/null 2>&1 || die "Missing required command: ${cmd}"
done
[[ -x "/usr/libexec/PlistBuddy" ]] || die "Missing required command: /usr/libexec/PlistBuddy"

POSITIONAL_ARGS=()
for arg in "$@"; do
  case "${arg}" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      POSITIONAL_ARGS+=("${arg}")
      ;;
  esac
done

if [[ ${#POSITIONAL_ARGS[@]} -gt 1 ]]; then
  usage
  die "Too many arguments"
fi

# Resolve source DMG path:
# 1) explicit argument
# 2) ../Codex.dmg
# 3) single *.dmg in project root (if present)
if [[ ${#POSITIONAL_ARGS[@]} -eq 1 ]]; then
  INPUT_DMG="$(cd "$(dirname "${POSITIONAL_ARGS[0]}")" && pwd)/$(basename "${POSITIONAL_ARGS[0]}")"
else
  if [[ -f "${ROOT_DIR}/Codex.dmg" ]]; then
    INPUT_DMG="${ROOT_DIR}/Codex.dmg"
  else
    found_dmgs=()
    while IFS= read -r dmg_path; do
      found_dmgs+=("${dmg_path}")
    done < <(find "${ROOT_DIR}" -maxdepth 1 -type f -name "*.dmg" ! -name "$(basename "${OUTPUT_DMG}")" | sort)
    if [[ ${#found_dmgs[@]} -eq 0 ]]; then
      die "No source DMG found. Put Codex.dmg in the project root (${ROOT_DIR}/Codex.dmg) or pass a path."
    fi
    if [[ ${#found_dmgs[@]} -gt 1 ]]; then
      printf '%s\n' "${found_dmgs[@]}"
      die "Multiple DMGs found. Pass source DMG path explicitly."
    fi
    INPUT_DMG="${found_dmgs[0]}"
  fi
fi

[[ -f "${INPUT_DMG}" ]] || die "Source DMG not found: ${INPUT_DMG}"
log "Source DMG: ${INPUT_DMG}"

# Mount source DMG in read-only mode.
progress 10 "Mounting source DMG in read-only mode"
mkdir -p "${MOUNT_POINT}"
if hdiutil attach -readonly -nobrowse -mountpoint "${MOUNT_POINT}" "${INPUT_DMG}" >/dev/null; then
  ATTACHED_BY_SCRIPT=1
  SOURCE_APP="${MOUNT_POINT}/Codex.app"
else
  die "Failed to mount source DMG"
fi
[[ -d "${SOURCE_APP}" ]] || die "Codex.app not found inside DMG"
validate_source_app

ORIG_APP="${WORK_DIR}/CodexOriginal.app"
TARGET_APP="${WORK_DIR}/Codex.app"
BUILD_PROJECT="${WORK_DIR}/build-project"
DMG_ROOT="${WORK_DIR}/dmg-root"
SHIM_INCLUDE_DIR="${WORK_DIR}/shim-include"

# Copy app bundle from mounted DMG to local writable work dir.
progress 20 "Copying source app bundle to work dir"
ditto "${SOURCE_APP}" "${ORIG_APP}"

FRAMEWORK_INFO="${ORIG_APP}/Contents/Frameworks/Electron Framework.framework/Versions/A/Resources/Info.plist"
[[ -f "${FRAMEWORK_INFO}" ]] || die "Cannot read Electron framework info plist"
ELECTRON_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${FRAMEWORK_INFO}" 2>/dev/null || true)"
[[ -n "${ELECTRON_VERSION}" ]] || die "Cannot detect Electron version from source app"

ASAR_FILE="${ORIG_APP}/Contents/Resources/app.asar"
[[ -f "${ASAR_FILE}" ]] || die "app.asar not found in source app"

# Read dependency versions from app.asar metadata.
ASAR_META_DIR="${WORK_DIR}/asar-meta"
mkdir -p "${ASAR_META_DIR}"
(
  cd "${ASAR_META_DIR}"
  extract_asar_file "${ASAR_FILE}" "node_modules/better-sqlite3/package.json" "${ASAR_META_DIR}/better-sqlite3.package.json"
  extract_asar_file "${ASAR_FILE}" "node_modules/node-pty/package.json" "${ASAR_META_DIR}/node-pty.package.json"
  extract_asar_file "${ASAR_FILE}" "node_modules/@openai/codex/package.json" "${ASAR_META_DIR}/codex.package.json" || true
  extract_asar_file "${ASAR_FILE}" "package.json" "${ASAR_META_DIR}/app.package.json" || true
)

BS_PKG="${ASAR_META_DIR}/better-sqlite3.package.json"
NP_PKG="${ASAR_META_DIR}/node-pty.package.json"
CODEX_PKG="${ASAR_META_DIR}/codex.package.json"
APP_PKG="${ASAR_META_DIR}/app.package.json"
CODEX_BIN="${ORIG_APP}/Contents/Resources/codex"
[[ -f "${BS_PKG}" ]] || die "Cannot extract better-sqlite3 package.json from app.asar"
[[ -f "${NP_PKG}" ]] || die "Cannot extract node-pty package.json from app.asar"
BS_VERSION="$(node -p "require(process.argv[1]).version" "${BS_PKG}")"
NP_VERSION="$(node -p "require(process.argv[1]).version" "${NP_PKG}")"
CODEX_VERSION=""
CODEX_VERSION_SOURCE=""
if [[ -f "${CODEX_PKG}" ]]; then
  CODEX_VERSION="$(node -p "require(process.argv[1]).version" "${CODEX_PKG}")"
  CODEX_VERSION="$(normalize_codex_version_candidate "${CODEX_VERSION}")"
  if [[ -n "${CODEX_VERSION}" ]]; then
    CODEX_VERSION_SOURCE="app.asar node_modules/@openai/codex/package.json"
  fi
fi
if [[ -z "${CODEX_VERSION}" ]]; then
  if [[ -f "${APP_PKG}" ]]; then
    CODEX_VERSION="$(node -p "const pkg=require(process.argv[1]); const candidates=[pkg.dependencies?.['@openai/codex'], pkg.optionalDependencies?.['@openai/codex'], pkg.devDependencies?.['@openai/codex'], pkg.dependencies?.['@openai/codex-darwin-arm64'], pkg.optionalDependencies?.['@openai/codex-darwin-arm64'], pkg.devDependencies?.['@openai/codex-darwin-arm64'], pkg.dependencies?.['@openai/codex-darwin-x64'], pkg.optionalDependencies?.['@openai/codex-darwin-x64'], pkg.devDependencies?.['@openai/codex-darwin-x64']]; for (const candidate of candidates) { if (typeof candidate === 'string' && candidate.length > 0) { console.log(candidate); break; } }" "${APP_PKG}")"
    CODEX_VERSION="$(normalize_codex_version_candidate "${CODEX_VERSION}")"
    if [[ -n "${CODEX_VERSION}" ]]; then
      CODEX_VERSION_SOURCE="app.asar package.json dependency metadata"
    fi
  fi
fi
if [[ -z "${CODEX_VERSION}" ]]; then
  CODEX_VERSION="$(detect_codex_version_from_binary_strings "${CODEX_BIN}" || true)"
  if [[ -n "${CODEX_VERSION}" ]]; then
    CODEX_VERSION_SOURCE="bundled codex binary strings"
  fi
fi
if [[ -z "${CODEX_VERSION}" ]]; then
  if [[ -f "${APP_PKG}" ]]; then
    CODEX_VERSION="$(node -p "const pkg=require(process.argv[1]); pkg.name === 'openai-codex-electron' ? (pkg.version || '') : ''" "${APP_PKG}")"
    CODEX_VERSION="$(normalize_codex_version_candidate "${CODEX_VERSION}")"
    if [[ -n "${CODEX_VERSION}" ]]; then
      CODEX_VERSION_SOURCE="app.asar package.json version"
    fi
  fi
fi
if [[ -z "${CODEX_VERSION}" ]]; then
  CODEX_VERSION="$(detect_codex_version_from_binary "${CODEX_BIN}" || true)"
  if [[ -n "${CODEX_VERSION}" ]]; then
    CODEX_VERSION_SOURCE="bundled codex binary --version"
  fi
fi
[[ -n "${CODEX_VERSION}" ]] || die "Cannot detect @openai/codex version from source app"

log "Detected Electron version: ${ELECTRON_VERSION}"
log "Detected Codex CLI / @openai/codex version: ${CODEX_VERSION} (${CODEX_VERSION_SOURCE})"
log "Detected better-sqlite3 version: ${BS_VERSION}"
log "Detected node-pty version: ${NP_VERSION}"

CODEX_X64_PACKAGE_SPEC="npm:@openai/codex@${CODEX_VERSION}-darwin-x64"

# Electron 40's V8 headers require <source_location>, but older Apple CLT/libc++
# combinations on Intel Macs may advertise the feature without shipping the header.
# Provide a tiny local shim only when the standard header is actually missing.
if [[ ! -f "/Library/Developer/CommandLineTools/usr/include/c++/v1/source_location" ]] && \
   [[ ! -f "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/c++/v1/source_location" ]]; then
  log "System <source_location> header missing; preparing compatibility shim"
  mkdir -p "${SHIM_INCLUDE_DIR}"
  cat > "${SHIM_INCLUDE_DIR}/source_location" <<'EOF'
#ifndef CODEX_INTEL_SOURCE_LOCATION_SHIM_H
#define CODEX_INTEL_SOURCE_LOCATION_SHIM_H

namespace std {

struct source_location {
  static constexpr source_location current(
      const char* file_name = __builtin_FILE(),
      const char* function_name = __builtin_FUNCTION(),
      unsigned int line = __builtin_LINE(),
      unsigned int column = 0) noexcept {
    return source_location(file_name, function_name, line, column);
  }

  constexpr source_location() noexcept = default;

  constexpr const char* file_name() const noexcept { return file_name_; }
  constexpr const char* function_name() const noexcept { return function_name_; }
  constexpr unsigned int line() const noexcept { return line_; }
  constexpr unsigned int column() const noexcept { return column_; }

 private:
  constexpr source_location(
      const char* file_name,
      const char* function_name,
      unsigned int line,
      unsigned int column) noexcept
      : file_name_(file_name),
        function_name_(function_name),
        line_(line),
        column_(column) {}

  const char* file_name_ = "";
  const char* function_name_ = "";
  unsigned int line_ = 0;
  unsigned int column_ = 0;
};

}  // namespace std

#endif
EOF
  export CPPFLAGS="-I${SHIM_INCLUDE_DIR}${CPPFLAGS:+ ${CPPFLAGS}}"
  export CXXFLAGS="-I${SHIM_INCLUDE_DIR}${CXXFLAGS:+ ${CXXFLAGS}}"
fi

# Build a temporary project to fetch x64 Electron/runtime artifacts.
progress 35 "Preparing Intel rebuild workspace"
mkdir -p "${BUILD_PROJECT}"
cat > "${BUILD_PROJECT}/package.json" <<EOF
{
  "name": "codex-intel-rebuild",
  "private": true,
  "version": "1.0.0",
  "dependencies": {
    "@openai/codex": "${CODEX_VERSION}",
    "@openai/codex-darwin-x64": "${CODEX_X64_PACKAGE_SPEC}",
    "better-sqlite3": "${BS_VERSION}",
    "electron": "${ELECTRON_VERSION}",
    "node-pty": "${NP_VERSION}"
  },
  "devDependencies": {
    "@electron/rebuild": "3.7.2"
  }
}
EOF

(
  cd "${BUILD_PROJECT}"
  progress 45 "Installing npm dependencies (estimated progress will update during this stage; timeout: 20 minutes)"
  # Force npm/electron to resolve darwin-x64 artifacts even when building on Apple Silicon.
  run_with_estimated_progress 45 59 1200 "Installing npm dependencies" \
    run_with_timeout 1200 env \
      npm_config_platform=darwin \
      npm_config_arch=x64 \
      npm_config_force=true \
      npm install --no-audit --no-fund --package-lock=false --force
)

# Use Electron x64 app template as the destination runtime.
progress 60 "Creating Intel app bundle from Electron runtime"
ditto "${BUILD_PROJECT}/node_modules/electron/dist/Electron.app" "${TARGET_APP}"

# Inject original Codex app resources into the x64 runtime shell.
progress 68 "Injecting Codex resources from original app"
rm -rf "${TARGET_APP}/Contents/Resources"
ditto "${ORIG_APP}/Contents/Resources" "${TARGET_APP}/Contents/Resources"
cp "${ORIG_APP}/Contents/Info.plist" "${TARGET_APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Electron" "${TARGET_APP}/Contents/Info.plist" >/dev/null
# Codex main process treats isPackaged=false as dev and tries localhost:5175.
# Force renderer URL to bundled app protocol in this transplanted runtime.
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:ELECTRON_RENDERER_URL string app://-/index.html" "${TARGET_APP}/Contents/Info.plist" >/dev/null 2>&1 || \
  /usr/libexec/PlistBuddy -c "Set :LSEnvironment:ELECTRON_RENDERER_URL app://-/index.html" "${TARGET_APP}/Contents/Info.plist" >/dev/null

# Rebuild native modules against Electron x64 ABI.
progress 75 "Rebuilding native modules for Electron ${ELECTRON_VERSION} x64 (timeout: 30 minutes)"
(
  cd "${BUILD_PROJECT}"
  run_with_estimated_progress 75 84 1800 "Rebuilding native modules for Electron ${ELECTRON_VERSION} x64" \
    run_with_timeout 1800 npx --yes @electron/rebuild -f -w better-sqlite3,node-pty --arch=x64 --version "${ELECTRON_VERSION}" -m "${BUILD_PROJECT}"
)

TARGET_UNPACKED="${TARGET_APP}/Contents/Resources/app.asar.unpacked"
[[ -d "${TARGET_UNPACKED}" ]] || die "Target app.asar.unpacked not found"

# Replace arm64 native artifacts with rebuilt x64 binaries.
progress 85 "Replacing native binaries inside app.asar.unpacked"
install -m 755 "${BUILD_PROJECT}/node_modules/better-sqlite3/build/Release/better_sqlite3.node" \
  "${TARGET_UNPACKED}/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
install -m 755 "${BUILD_PROJECT}/node_modules/node-pty/build/Release/pty.node" \
  "${TARGET_UNPACKED}/node_modules/node-pty/build/Release/pty.node"
install -m 755 "${BUILD_PROJECT}/node_modules/node-pty/build/Release/spawn-helper" \
  "${TARGET_UNPACKED}/node_modules/node-pty/build/Release/spawn-helper"

NODE_PTY_BIN_SRC="$(find "${BUILD_PROJECT}/node_modules/node-pty/bin" -type f -name "node-pty.node" | grep "darwin-x64" | head -n 1 || true)"
if [[ -n "${NODE_PTY_BIN_SRC}" ]]; then
  mkdir -p "${TARGET_UNPACKED}/node_modules/node-pty/bin/darwin-x64-143"
  install -m 755 "${NODE_PTY_BIN_SRC}" "${TARGET_UNPACKED}/node_modules/node-pty/bin/darwin-x64-143/node-pty.node"
  if [[ -f "${TARGET_UNPACKED}/node_modules/node-pty/bin/darwin-arm64-143/node-pty.node" ]]; then
    # Keep hardcoded/fallback load paths functional even if the app references arm64 folder.
    install -m 755 "${NODE_PTY_BIN_SRC}" "${TARGET_UNPACKED}/node_modules/node-pty/bin/darwin-arm64-143/node-pty.node"
  fi
fi

CLI_X64_ROOT="${BUILD_PROJECT}/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin"
CLI_X64_BIN="${CLI_X64_ROOT}/codex/codex"
RG_X64_BIN="${CLI_X64_ROOT}/path/rg"
[[ -f "${CLI_X64_BIN}" ]] || die "x64 Codex CLI binary not found after npm install"
[[ -f "${RG_X64_BIN}" ]] || die "x64 rg binary not found after npm install"

# Replace bundled arm64 codex/rg command-line binaries.
progress 88 "Replacing bundled codex/rg binaries with x64 versions"
install -m 755 "${CLI_X64_BIN}" "${TARGET_APP}/Contents/Resources/codex"
install -m 755 "${CLI_X64_BIN}" "${TARGET_APP}/Contents/Resources/app.asar.unpacked/codex"
install -m 755 "${RG_X64_BIN}" "${TARGET_APP}/Contents/Resources/rg"

# Sparkle native addon is arm64-only in this flow; disable it.
progress 90 "Disabling incompatible Sparkle native addon"
rm -f "${TARGET_APP}/Contents/Resources/native/sparkle.node"
rm -f "${TARGET_APP}/Contents/Resources/app.asar.unpacked/native/sparkle.node"

# Sanity-check key binaries before signing/packaging.
progress 92 "Validating key binaries are x86_64"
for binary in \
  "${TARGET_APP}/Contents/MacOS/Electron" \
  "${TARGET_APP}/Contents/Resources/codex" \
  "${TARGET_APP}/Contents/Resources/rg" \
  "${TARGET_APP}/Contents/Resources/app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node" \
  "${TARGET_APP}/Contents/Resources/app.asar.unpacked/node_modules/node-pty/build/Release/pty.node"; do
  file_output="$(file "${binary}")"
  echo "${file_output}"
  [[ "${file_output}" == *"x86_64"* ]] || die "Expected x86_64 binary: ${binary}"
done

# Re-sign modified app ad-hoc to satisfy macOS code integrity checks.
progress 95 "Signing app ad-hoc"
xattr -cr "${TARGET_APP}" || true
codesign --force --deep --sign - --timestamp=none "${TARGET_APP}"
codesign --verify --deep --strict "${TARGET_APP}"

progress 98 "Building output DMG: ${OUTPUT_DMG}"
rm -f "${OUTPUT_DMG}"
rm -rf "${DMG_ROOT}"
mkdir -p "${DMG_ROOT}"
ditto "${TARGET_APP}" "${DMG_ROOT}/Codex.app"
ln -s /Applications "${DMG_ROOT}/Applications"
hdiutil create -volname "Codex-Intel" -srcfolder "${DMG_ROOT}" -ov -format UDZO "${OUTPUT_DMG}" >/dev/null

progress 100 "Done"
log "Output DMG: ${OUTPUT_DMG}"
log "Build log: ${LOG_FILE}"
log "Work dir: ${WORK_DIR}"
