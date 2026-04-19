#!/usr/bin/env bash
set -euo pipefail

# Resolve script and workspace paths.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_BASE="${ROOT_DIR}/.tmp"
LOG_FILE="${ROOT_DIR}/log-chatgpt.txt"
OUTPUT_DMG="${ROOT_DIR}/ChatGPT-Intel.dmg"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
WORK_DIR="${TMP_BASE}/chatgpt_intel_build_${RUN_ID}"
MOUNT_POINT="${WORK_DIR}/mount"
EXPECTED_SOURCE_BUNDLE_ID="${EXPECTED_SOURCE_BUNDLE_ID:-com.openai.chat}"
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

validate_source_app() {
  local signing_info_file="${WORK_DIR}/source-app-signing.txt"
  local bundle_id=""
  local team_id=""

  progress 15 "Validating source app identity"
  codesign -dv --verbose=4 "${SOURCE_APP}" >/dev/null 2>"${signing_info_file}" || \
    die "Source app is not code-signed. Please use the official ChatGPT.dmg from OpenAI."

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
  ./scripts/build-chatgpt-intel.sh [path/to/ChatGPT.dmg]

Behavior:
  - Reads source DMG from ../ChatGPT.dmg by default (or explicit path argument)
  - Never modifies the original DMG
  - Uses .tmp/* for all build steps
  - Writes full logs to log-chatgpt.txt
  - Produces ../ChatGPT-Intel.dmg

IMPORTANT:
  ChatGPT is a native Swift application (not Electron-based like Codex).
  This script attempts to create a compatible Intel build but may not work
  due to native framework dependencies.
EOF
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
if [[ "${CHATGPT_INTEL_NO_TEE:-0}" == "1" ]]; then
  exec >> "${LOG_FILE}" 2>&1
else
  exec > >(tee -a "${LOG_FILE}") 2>&1
fi

log "Starting ChatGPT Intel build pipeline"
log "Script dir: ${SCRIPT_DIR}"
log "Project root: ${ROOT_DIR}"
log "Default source location: ${ROOT_DIR}/ChatGPT.dmg"
log "Default DMG output: ${OUTPUT_DMG}"
log "Work dir: ${WORK_DIR}"
mkdir -p "${WORK_DIR}"

# Validate required tools early.
for cmd in hdiutil ditto file codesign xattr; do
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
# 2) ../ChatGPT.dmg
# 3) single *.dmg in project root (if present)
if [[ ${#POSITIONAL_ARGS[@]} -eq 1 ]]; then
  INPUT_DMG="$(cd "$(dirname "${POSITIONAL_ARGS[0]}")" && pwd)/$(basename "${POSITIONAL_ARGS[0]}")"
else
  if [[ -f "${ROOT_DIR}/ChatGPT.dmg" ]]; then
    INPUT_DMG="${ROOT_DIR}/ChatGPT.dmg"
  else
    found_dmgs=()
    while IFS= read -r dmg_path; do
      found_dmgs+=("${dmg_path}")
    done < <(find "${ROOT_DIR}" -maxdepth 1 -type f -name "*.dmg" ! -name "$(basename "${OUTPUT_DMG}")" | sort)
    if [[ ${#found_dmgs[@]} -eq 0 ]]; then
      die "No source DMG found. Put ChatGPT.dmg in the project root (${ROOT_DIR}/ChatGPT.dmg) or pass a path."
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
  SOURCE_APP="${MOUNT_POINT}/ChatGPT.app"
else
  die "Failed to mount source DMG"
fi
[[ -d "${SOURCE_APP}" ]] || die "ChatGPT.app not found inside DMG"
validate_source_app

# Check if the app is native Swift or Electron-based
progress 20 "Analyzing app structure"
if [[ -d "${SOURCE_APP}/Contents/Frameworks/Electron Framework.framework" ]]; then
  log "Detected Electron-based app"
  APP_TYPE="electron"
else
  log "WARNING: ChatGPT appears to be a native Swift app, not Electron-based"
  log "Native Swift apps cannot be easily recompiled for Intel x86_64"
  log "This build may not work correctly"
  APP_TYPE="native"
fi

ORIG_APP="${WORK_DIR}/ChatGPTOriginal.app"
TARGET_APP="${WORK_DIR}/ChatGPT.app"
DMG_ROOT="${WORK_DIR}/dmg-root"

# Copy app bundle from mounted DMG to local writable work dir.
progress 30 "Copying source app bundle to work dir"
ditto "${SOURCE_APP}" "${ORIG_APP}"

# Get version info
APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${ORIG_APP}/Contents/Info.plist" 2>/dev/null || true)"
log "Detected ChatGPT version: ${APP_VERSION}"

if [[ "${APP_TYPE}" == "native" ]]; then
  # For native Swift apps, we need to check what architectures are available
  progress 40 "Checking binary architectures"
  
  MAIN_BINARY="${ORIG_APP}/Contents/MacOS/ChatGPT"
  if [[ -f "${MAIN_BINARY}" ]]; then
    FILE_OUTPUT="$(file "${MAIN_BINARY}")"
    log "Main binary: ${FILE_OUTPUT}"
    
    # Check if it's universal binary
    if echo "${FILE_OUTPUT}" | grep -q "universal binary"; then
      log "Detected universal binary with multiple architectures"
      
      # Extract x86_64 slice if available
      if echo "${FILE_OUTPUT}" | grep -q "x86_64"; then
        progress 50 "Extracting x86_64 architecture from universal binary"
        
        # Create target app structure
        mkdir -p "${TARGET_APP}"
        ditto "${ORIG_APP}" "${TARGET_APP}"
        
        # Extract x86_64 slice from main binary
        lipo -extract x86_64 "${MAIN_BINARY}" -output "${TARGET_APP}/Contents/MacOS/ChatGPT" || \
          die "Failed to extract x86_64 from main binary"
        
        # Process frameworks
        for framework in "${TARGET_APP}/Contents/Frameworks/"*.framework; do
          if [[ -d "${framework}" ]]; then
            FRAMEWORK_NAME="$(basename "${framework}" .framework)"
            FRAMEWORK_BINARY="${framework}/Versions/A/${FRAMEWORK_NAME}"
            
            if [[ -f "${FRAMEWORK_BINARY}" ]]; then
              FRAMEWORK_FILE="$(file "${FRAMEWORK_BINARY}")"
              if echo "${FRAMEWORK_FILE}" | grep -q "universal binary" && echo "${FRAMEWORK_FILE}" | grep -q "x86_64"; then
                log "Extracting x86_64 from ${FRAMEWORK_NAME}.framework"
                lipo -extract x86_64 "${FRAMEWORK_BINARY}" -output "${FRAMEWORK_BINARY}.tmp" && \
                  mv "${FRAMEWORK_BINARY}.tmp" "${FRAMEWORK_BINARY}" || \
                  log "WARNING: Failed to extract x86_64 from ${FRAMEWORK_NAME}.framework"
              fi
            fi
          fi
        done
        
        # Process other binaries
        find "${TARGET_APP}" -type f -perm +111 | while read -r binary; do
          if file "${binary}" | grep -q "Mach-O"; then
            BINARY_FILE="$(file "${binary}")"
            if echo "${BINARY_FILE}" | grep -q "universal binary" && echo "${BINARY_FILE}" | grep -q "x86_64"; then
              lipo -extract x86_64 "${binary}" -output "${binary}.tmp" 2>/dev/null && \
                mv "${binary}.tmp" "${binary}" || true
            fi
          fi
        done
      else
        die "Universal binary does not contain x86_64 architecture"
      fi
    else
      die "ChatGPT is a native ARM64-only app and cannot be converted to Intel x86_64"
    fi
  else
    die "Cannot find main binary"
  fi
else
  # Electron-based (unlikely for ChatGPT, but handle it)
  die "Electron-based ChatGPT detected. This script is designed for native Swift apps."
fi

# Validate key binaries
progress 70 "Validating key binaries are x86_64"
for binary in \
  "${TARGET_APP}/Contents/MacOS/ChatGPT"; do
  if [[ -f "${binary}" ]]; then
    file_output="$(file "${binary}")"
    echo "${file_output}"
    if [[ "${file_output}" == *"x86_64"* ]]; then
      log "✓ ${binary} is x86_64"
    else
      die "Expected x86_64 binary: ${binary}"
    fi
  fi
done

# Re-sign modified app ad-hoc
progress 85 "Signing app ad-hoc"
xattr -cr "${TARGET_APP}" || true
codesign --force --deep --sign - --timestamp=none "${TARGET_APP}"
codesign --verify --deep --strict "${TARGET_APP}"

# Build output DMG
progress 95 "Building output DMG: ${OUTPUT_DMG}"
rm -f "${OUTPUT_DMG}"
rm -rf "${DMG_ROOT}"
mkdir -p "${DMG_ROOT}"
ditto "${TARGET_APP}" "${DMG_ROOT}/ChatGPT.app"
ln -s /Applications "${DMG_ROOT}/Applications"
hdiutil create -volname "ChatGPT-Intel" -srcfolder "${DMG_ROOT}" -ov -format UDZO "${OUTPUT_DMG}" >/dev/null

progress 100 "Done"
log "Output DMG: ${OUTPUT_DMG}"
log "Build log: ${LOG_FILE}"
log "Work dir: ${WORK_DIR}"
