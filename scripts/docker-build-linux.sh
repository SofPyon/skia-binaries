#!/usr/bin/env bash
# Runs scripts/build-slice.sh for a Linux slice inside the container from docker/Dockerfile.
# The repository is bind-mounted, so the archives land in work/skia/out/<slice>/merged/ on the
# host exactly like the Apple slices, and make-linux-bundle.sh packages them from there.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

SLICE="${1:-}"
case "${SLICE}" in
  linux-arm64) DOCKER_PLATFORM="linux/arm64" ;;
  linux-x64) DOCKER_PLATFORM="linux/amd64" ;;
  *)
    echo "usage: $0 linux-arm64|linux-x64" >&2
    exit 1
    ;;
esac

IMAGE="skia-binaries-build:${SLICE}"
echo "== docker build ${IMAGE} (${DOCKER_PLATFORM}) =="
docker build --platform "${DOCKER_PLATFORM}" -t "${IMAGE}" -f "${ROOT_DIR}/docker/Dockerfile" "${ROOT_DIR}/docker"

echo "== docker run scripts/build-slice.sh ${SLICE} =="
# HOME points at a writable path because build-slice.sh looks for ~/depot_tools/ninja.
docker run --rm --platform "${DOCKER_PLATFORM}" \
  -v "${ROOT_DIR}:/work" -w /work -e HOME=/tmp \
  "${IMAGE}" scripts/build-slice.sh "${SLICE}"
