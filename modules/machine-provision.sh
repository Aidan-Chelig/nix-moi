#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
machine-provision [OPTIONS]

Writes machine-local identity state for the nix-moi NixOS modules.

Options:
  --root PATH             Target root to write into. Defaults to /.
  --hostname NAME         Hostname to store.
  --state-version VALUE   NixOS stateVersion to store. Defaults to the running NixOS release.
  --skip-facter           Do not generate facter.json.
  -h, --help              Show this help.
USAGE
}

infer_state_version() {
  if [[ -n "${NIXOS_STATE_VERSION:-}" ]]; then
    printf '%s\n' "$NIXOS_STATE_VERSION"
    return 0
  fi

  if [[ -r /etc/os-release ]]; then
    local key value
    while IFS='=' read -r key value; do
      if [[ "$key" == "VERSION_ID" ]]; then
        value="${value%\"}"
        value="${value#\"}"
        if [[ "$value" =~ ^([0-9][0-9]\.[0-9][0-9]) ]]; then
          printf '%s\n' "${BASH_REMATCH[1]}"
          return 0
        fi
      fi
    done </etc/os-release
  fi

  if command -v nixos-version >/dev/null 2>&1; then
    local version
    version="$(nixos-version 2>/dev/null || true)"
    if [[ "$version" =~ ^([0-9][0-9]\.[0-9][0-9]) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  fi

  return 1
}

root="/"
host_name=""
state_version=""
skip_facter=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      root="${2:?--root requires a path}"
      shift 2
      ;;
    --hostname)
      host_name="${2:?--hostname requires a name}"
      shift 2
      ;;
    --state-version)
      state_version="${2:?--state-version requires a value}"
      shift 2
      ;;
    --skip-facter)
      skip_facter=1
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

if [[ -z "$host_name" ]]; then
  current_hostname="$(uname -n 2>/dev/null || true)"
  host_name="$(gum input --prompt "Hostname: " --value "$current_hostname")"
fi

if [[ -z "$state_version" ]]; then
  state_version="$(infer_state_version || true)"
fi

if [[ -z "$state_version" && -t 0 ]]; then
  state_version="$(gum input --prompt "NixOS stateVersion: ")"
fi

if [[ -z "$host_name" ]]; then
  echo "hostname cannot be empty" >&2
  exit 1
fi

if [[ -z "$state_version" ]]; then
  echo "stateVersion cannot be empty" >&2
  exit 1
fi

identity_dir="$root/etc/nixos/machine"
mkdir -p "$identity_dir"

jq -n \
  --arg hostName "$host_name" \
  --arg stateVersion "$state_version" \
  '{
    hostName: $hostName,
    stateVersion: $stateVersion
  }' >"$identity_dir/identity.json"

printf '%s\n' "$host_name" >"$identity_dir/hostname"

if [[ "$skip_facter" -eq 0 ]]; then
  if command -v nixos-facter >/dev/null 2>&1; then
    nixos-facter -o "$identity_dir/facter.json"
  else
    gum style --foreground 214 "nixos-facter not found; wrote identity without facter.json"
  fi
fi

gum style --foreground 42 "Wrote machine identity to $identity_dir"
