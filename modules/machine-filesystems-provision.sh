#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
machine-filesystems-provision [OPTIONS]

Writes machine-local filesystem state for the machine-filesystems NixOS module.
The layout is inferred from filesystems currently mounted under the target root.

Options:
  --root PATH        Mounted target root to inspect. Defaults to /mnt.
  --output PATH      Output JSON path. Defaults to ROOT/etc/nixos/machine/filesystems.json.
  --no-swap          Do not include currently active swap devices.
  -h, --help         Show this help.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

root="/mnt"
output=""
include_swap=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      root="${2:?--root requires a path}"
      shift 2
      ;;
    --output)
      output="${2:?--output requires a path}"
      shift 2
      ;;
    --no-swap)
      include_swap=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

root="${root%/}"
if [[ -z "$root" ]]; then
  root="/"
fi

[[ -d "$root" ]] || die "target root does not exist: $root"
findmnt -rn --mountpoint "$root" >/dev/null || die "target root is not a mount point: $root"

if [[ -z "$output" ]]; then
  output="$root/etc/nixos/machine/filesystems.json"
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

jq -n '{ fileSystems: {}, swapDevices: [] }' >"$tmp"

while IFS=$'\t' read -r target source fs_type; do
  [[ -n "$target" && -n "$source" && -n "$fs_type" ]] || continue
  [[ "$source" == /dev/* ]] || continue

  if [[ "$target" == "$root" ]]; then
    mount_point="/"
  elif [[ "$target" == "$root/"* ]]; then
    mount_point="/${target#"$root/"}"
  else
    continue
  fi

  uuid="$(blkid -s UUID -o value "$source" 2>/dev/null || true)"
  label="$(blkid -s LABEL -o value "$source" 2>/dev/null || true)"

  if [[ -n "$uuid" ]]; then
    entry="$(jq -n \
      --arg uuid "$uuid" \
      --arg fsType "$fs_type" \
      '{ uuid: $uuid, fsType: $fsType }')"
  elif [[ -n "$label" ]]; then
    entry="$(jq -n \
      --arg label "$label" \
      --arg fsType "$fs_type" \
      '{ label: $label, fsType: $fsType }')"
  else
    entry="$(jq -n \
      --arg device "$source" \
      --arg fsType "$fs_type" \
      '{ device: $device, fsType: $fsType }')"
  fi

  jq \
    --arg mountPoint "$mount_point" \
    --argjson entry "$entry" \
    '.fileSystems[$mountPoint] = $entry' \
    "$tmp" >"$tmp.next"
  mv "$tmp.next" "$tmp"
done < <(
  findmnt -R --json -o TARGET,SOURCE,FSTYPE "$root" \
    | jq -r '.filesystems[] | recurse(.children[]?) | [.target, .source, .fstype] | @tsv'
)

if [[ "$include_swap" -eq 1 && -r /proc/swaps ]]; then
  while read -r source _type _size _used _priority; do
    [[ "$source" == Filename ]] && continue
    [[ "$source" == /dev/* ]] || continue

    uuid="$(blkid -s UUID -o value "$source" 2>/dev/null || true)"
    label="$(blkid -s LABEL -o value "$source" 2>/dev/null || true)"

    if [[ -n "$uuid" ]]; then
      entry="$(jq -n --arg uuid "$uuid" '{ uuid: $uuid }')"
    elif [[ -n "$label" ]]; then
      entry="$(jq -n --arg label "$label" '{ label: $label }')"
    else
      entry="$(jq -n --arg device "$source" '{ device: $device }')"
    fi

    jq --argjson entry "$entry" '.swapDevices += [$entry]' "$tmp" >"$tmp.next"
    mv "$tmp.next" "$tmp"
  done </proc/swaps
fi

if ! jq -e '.fileSystems["/"]' "$tmp" >/dev/null; then
  die "could not infer root filesystem from mounts under $root"
fi

mkdir -p "$(dirname "$output")"
jq --sort-keys . "$tmp" >"$output"
printf 'Wrote machine filesystem layout to %s\n' "$output"
