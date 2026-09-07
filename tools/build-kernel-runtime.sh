#!/usr/bin/env bash
set -euo pipefail

root=$(realpath "$(dirname "$0")/..")
source="$root/packaging/proxmox-amlogic-kernel-runtime"
output="$root/dist/proxmox-amlogic-kernel-runtime_1.0_all.deb"
stage=""

usage() {
    printf 'usage: %s [--output PATH]\n' "$0"
}

while (($#)); do
    case "$1" in
        --output) output=${2:?missing value for --output}; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

for command in dpkg-deb install mktemp rm; do
    command -v "$command" >/dev/null || {
        printf 'error: missing command: %s\n' "$command" >&2
        exit 1
    }
done

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
chmod 0755 "$stage"
mkdir -p "$(dirname "$output")"
install -Dm0644 "$source/DEBIAN/control" "$stage/DEBIAN/control"
install -Dm0755 "$source/DEBIAN/postinst" "$stage/DEBIAN/postinst"
install -Dm0644 "$source/usr/lib/systemd/system/proxmox-amlogic-kernel-cleanup.service" \
    "$stage/usr/lib/systemd/system/proxmox-amlogic-kernel-cleanup.service"
install -Dm0755 "$source/usr/lib/proxmox-amlogic/kernel-cleanup" \
    "$stage/usr/lib/proxmox-amlogic/kernel-cleanup"
install -d -m0755 "$stage/var/lib/proxmox-amlogic"
dpkg-deb --root-owner-group --build "$stage" "$output" >/dev/null
printf 'Built %s\n' "$output"
