#!/usr/bin/env bash
set -Eeuo pipefail
export GIT_TERMINAL_PROMPT=0
trap 'status=$?; echo "FATAL: command failed (exit ${status}): ${BASH_COMMAND}" >&2; exit "${status}"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORK_DIR="${WORK_DIR:-${PWD}/work}"
PVE_SRC="${WORK_DIR}/pve-kernel"
PVE_GIT_URL="${PVE_GIT_URL:-https://git.proxmox.com/git/pve-kernel.git}"
PVE_HEAD="${PVE_HEAD:-}"
LOCAL_PATCH="${REPO_ROOT}/patches/amlogic/x96-max-plus-dts.patch"
LOCAL_PVE_PATCH="${REPO_ROOT}/patches/pve/x96-max-plus-boot-deployment.patch"

if [ "$(dpkg --print-architecture)" != "arm64" ]; then
  echo "FATAL: native arm64 build required; use an arm64 runner" >&2
  exit 1
fi
for patch_file in "${LOCAL_PATCH}" "${LOCAL_PVE_PATCH}"; do
  if [ ! -f "${patch_file}" ]; then
    echo "FATAL: missing local patch: ${patch_file}" >&2
    exit 1
  fi
done

mkdir -p "${WORK_DIR}"

echo "==> Resolving PVE source"
if [ -z "${PVE_HEAD}" ]; then
  PVE_HEAD="$(git ls-remote "${PVE_GIT_URL}" HEAD | awk '{print $1}')"
fi
if ! [[ "${PVE_HEAD}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "FATAL: invalid PVE commit: ${PVE_HEAD}" >&2
  exit 1
fi

rm -rf "${PVE_SRC}"
git clone --quiet --depth 1 --no-tags "${PVE_GIT_URL}" "${PVE_SRC}"
if [ "$(git -C "${PVE_SRC}" rev-parse HEAD)" != "${PVE_HEAD}" ]; then
  git -C "${PVE_SRC}" fetch --quiet --depth 1 origin "${PVE_HEAD}"
  git -C "${PVE_SRC}" checkout --quiet FETCH_HEAD
fi
echo "    PVE_HEAD=${PVE_HEAD}"

KERNEL_MAJ="$(sed -n 's/^KERNEL_MAJ=//p' "${PVE_SRC}/Makefile")"
KERNEL_MIN="$(sed -n 's/^KERNEL_MIN=//p' "${PVE_SRC}/Makefile")"
KERNEL_PATCHLEVEL="$(sed -n 's/^KERNEL_PATCHLEVEL=//p' "${PVE_SRC}/Makefile")"
KERNEL_VER="${KERNEL_MAJ}.${KERNEL_MIN}.${KERNEL_PATCHLEVEL}"

echo "==> Installing downstream X96 Max+ patch"
cp "${LOCAL_PATCH}" "${PVE_SRC}/patches/kernel/9999-$(basename "${LOCAL_PATCH}")"
git -C "${PVE_SRC}" apply "${LOCAL_PVE_PATCH}"

# The generic Ubuntu arm64 config enables an Intel-only camera driver whose
# current source is not valid in this configuration. It is irrelevant to ARM64.
printf '%s\n' '-d CONFIG_IPU_BRIDGE' >> "${PVE_SRC}/debian/rules.d/config-arm64.opts"

BUILD_DIR="${PVE_SRC}/proxmox-kernel-${KERNEL_VER}"

echo "==> Preparing with PVE's native package target"
(
  cd "${PVE_SRC}"
  make build-dir-fresh
  mk-build-deps -ir --tool 'apt-get -y --no-install-recommends' \
    "${BUILD_DIR##${PVE_SRC}/}/debian/control"
  make deb
)

echo "build-pve-kernel.sh: DONE"
