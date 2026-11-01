#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/dist"
MODULE_PROP="${SCRIPT_DIR}/module.prop"

MODULE_ID="$(grep -E '^id=' "${MODULE_PROP}" | cut -d= -f2)"
MODULE_VER="$(grep -E '^version=' "${MODULE_PROP}" | cut -d= -f2)"
ZIP_NAME="${MODULE_ID}-${MODULE_VER}.zip"

mkdir -p "${OUTPUT_DIR}"
rm -f "${OUTPUT_DIR}"/*.zip "${OUTPUT_DIR}"/SHA256SUMS

echo "Packaging ${ZIP_NAME}..."

cd "${SCRIPT_DIR}"
zip -r9 "${OUTPUT_DIR}/${ZIP_NAME}" \
    module.prop \
    customize.sh \
    service.sh \
    sepolicy.rule \
    system \
    META-INF \
    -x "*.git*" "*.DS_Store*" "*~"

if [ -f "${SCRIPT_DIR}/update.json" ]; then
    cp -p "${SCRIPT_DIR}/update.json" "${OUTPUT_DIR}/update.json"
fi

echo "Successfully created: ${OUTPUT_DIR}/${ZIP_NAME}"
