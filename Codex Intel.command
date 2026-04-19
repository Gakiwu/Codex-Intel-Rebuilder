#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
BUILD_SCRIPT="${SCRIPT_DIR}/scripts/build-intel.sh"
OUTPUT_DMG="${SCRIPT_DIR}/Codex-Intel.dmg"
LOG_FILE="${SCRIPT_DIR}/log.txt"

pause() {
  printf '\nPress Enter to finish...'
  IFS= read -r _
}

main() {
  clear
  printf '\n'
  printf '  \033[1;36mCodex Intel Builder\033[0m\n\n'
  printf '  Starting the DMG build...\n'
  printf '  This will create \033[1m%s\033[0m in this folder.\n\n' "$(basename "${OUTPUT_DMG}")"

  if [[ ! -x "${BUILD_SCRIPT}" ]]; then
    printf '  \033[1;31mERROR:\033[0m Missing build script:\n'
    printf '  \033[1m%s\033[0m\n' "${BUILD_SCRIPT}"
    pause
    return 1
  fi

  if bash "${BUILD_SCRIPT}" "$@"; then
    printf '\n  Finished successfully.\n'
    printf '  Output DMG: \033[1m%s\033[0m\n' "${OUTPUT_DMG}"
  else
    printf '\n  The build did not complete.\n'
    printf '  Please check \033[1m%s\033[0m for details.\n' "${LOG_FILE}"
  fi

  pause
}

main "$@"
