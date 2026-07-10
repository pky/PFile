#!/bin/sh
set -eu

VERSION="3.7.2"
ARCHIVE_NAME="MobileVLCKit-3.7.2-3e42ae47-79128878.tar.xz"
ARCHIVE_URL="https://download.videolan.org/pub/cocoapods/prod/${ARCHIVE_NAME}"
ARCHIVE_SHA256="77b867667e5e62aa4062e71b7a4f76a0e2f505425916091c0eb0f94d9ad4af80"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
PACKAGE_DIR="${ROOT_DIR}/Packages/MobileVLCKitBinary"
ARTIFACT_DIR="${PACKAGE_DIR}/Artifacts"
FRAMEWORK_DIR="${ARTIFACT_DIR}/MobileVLCKit.xcframework"
CACHE_DIR="${ARTIFACT_DIR}/.cache"
ARCHIVE_PATH="${CACHE_DIR}/${ARCHIVE_NAME}"
EXTRACT_DIR="${CACHE_DIR}/extract"

if [ -d "${FRAMEWORK_DIR}" ]; then
  echo "MobileVLCKit ${VERSION} artifact already exists."
  exit 0
fi

mkdir -p "${ARTIFACT_DIR}" "${CACHE_DIR}"

echo "Downloading MobileVLCKit ${VERSION} artifact."
curl -L "${ARCHIVE_URL}" -o "${ARCHIVE_PATH}"

ACTUAL_SHA256=$(shasum -a 256 "${ARCHIVE_PATH}" | awk '{print $1}')
if [ "${ACTUAL_SHA256}" != "${ARCHIVE_SHA256}" ]; then
  echo "MobileVLCKit archive checksum mismatch." >&2
  echo "expected: ${ARCHIVE_SHA256}" >&2
  echo "actual:   ${ACTUAL_SHA256}" >&2
  exit 1
fi

rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"
tar -xf "${ARCHIVE_PATH}" -C "${EXTRACT_DIR}"

FOUND_FRAMEWORK=$(find "${EXTRACT_DIR}" -maxdepth 4 -name MobileVLCKit.xcframework -type d | head -n 1)
if [ -z "${FOUND_FRAMEWORK}" ]; then
  echo "MobileVLCKit.xcframework was not found in the archive." >&2
  exit 1
fi

cp -R "${FOUND_FRAMEWORK}" "${FRAMEWORK_DIR}"

FOUND_LICENSE=$(find "${EXTRACT_DIR}" -maxdepth 4 -name COPYING.txt -type f | head -n 1)
if [ -n "${FOUND_LICENSE}" ]; then
  cp "${FOUND_LICENSE}" "${ARTIFACT_DIR}/COPYING.txt"
fi

echo "Prepared MobileVLCKit ${VERSION} artifact."
