#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
qemu-machine-provision-test [OPTIONS]

Builds a disposable NixOS installer ISO, boots it with QEMU, attaches a blank
target disk, runs machine-provision inside the installer, validates the written
machine identity files, and powers off.

Options:
  --hostname NAME         Hostname to provision. Defaults to qemu-test.
  --state-version VALUE   NixOS stateVersion to provision. Defaults to the installer release.
  --system SYSTEM         Guest Linux system. Defaults from host arch.
  --disk-size-mib MiB     Empty target disk size. Defaults to 2048.
  --memory MiB            VM memory. Defaults to 2048.
  --timeout SECONDS       QEMU runtime timeout. Defaults to 300.
  --keep-workdir          Keep the temporary test directory.
  -h, --help              Show this help.
USAGE
}

repo_root="${REPO_ROOT:-$(pwd)}"
if [[ ! -f "$repo_root/flake.nix" ]]; then
  repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fi
if [[ ! -f "$repo_root/flake.nix" ]]; then
  echo "could not find repo root; run from the flake root or set REPO_ROOT" >&2
  exit 1
fi

host_name="qemu-test"
state_version=""
disk_size_mib="2048"
memory="2048"
timeout_seconds="300"
keep_workdir=0

case "$(uname -m)" in
  x86_64) system="x86_64-linux" ;;
  arm64|aarch64) system="aarch64-linux" ;;
  *) system="x86_64-linux" ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)
      host_name="${2:?--hostname requires a name}"
      shift 2
      ;;
    --state-version)
      state_version="${2:?--state-version requires a value}"
      shift 2
      ;;
    --system)
      system="${2:?--system requires a value}"
      shift 2
      ;;
    --disk-size-mib)
      disk_size_mib="${2:?--disk-size-mib requires a value}"
      shift 2
      ;;
    --memory)
      memory="${2:?--memory requires a value}"
      shift 2
      ;;
    --timeout)
      timeout_seconds="${2:?--timeout requires a value}"
      shift 2
      ;;
    --keep-workdir)
      keep_workdir=1
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

case "$system" in
  x86_64-linux)
    console_kernel_param="console=ttyS0,115200n8"
    ;;
  aarch64-linux)
    console_kernel_param="console=ttyAMA0,115200n8"
    ;;
  *)
    echo "unsupported guest system: $system" >&2
    echo "supported systems: x86_64-linux, aarch64-linux" >&2
    exit 2
    ;;
esac

workdir="$(mktemp -d -t machine-provision-qemu.XXXXXX)"
cleanup() {
  if [[ "$keep_workdir" -eq 0 ]]; then
    rm -rf "$workdir"
  else
    echo "kept workdir: $workdir"
  fi
}
trap cleanup EXIT

extra_features=(--extra-experimental-features "nix-command flakes")
flake_flags=(--no-write-lock-file)

printf -v host_name_q "%q" "$host_name"
printf -v state_version_q "%q" "$state_version"
state_version_arg=()
if [[ -n "$state_version" ]]; then
  state_version_arg=(--state-version "$state_version")
fi
printf -v state_version_args_q " %q" "${state_version_arg[@]}"

cat >"$workdir/installer-test.nix" <<EOF
{ lib, modulesPath, pkgs, ... }:
let
  flake = builtins.getFlake "git+file://$repo_root";
  machineProvision = flake.packages.\${pkgs.stdenv.hostPlatform.system}.machine-provision;
in
{
  imports = [
    "\${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
  ];

  boot.kernelParams = [
    "$console_kernel_param"
    "panic=1"
    "boot.panic_on_fail"
  ];

  environment.systemPackages = with pkgs; [
    e2fsprogs
    jq
    machineProvision
    util-linux
  ];

  networking.hostName = "machine-provision-installer-test";

  systemd.services.machine-provision-qemu-test = {
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    path = with pkgs; [
      coreutils
      e2fsprogs
      gawk
      gnugrep
      jq
      util-linux
    ];
    script = ''
      set -eux

      target_disk="\$(lsblk -dn -o NAME,TYPE,RO | awk '\$2 == "disk" && \$3 == "0" { print "/dev/" \$1; exit }')"
      if [ -z "\$target_disk" ]; then
        echo "could not find writable attached target disk" >&2
        lsblk >&2
        exit 1
      fi

      mkfs.ext4 -F "\$target_disk"
      mkdir -p /mnt/target
      mount "\$target_disk" /mnt/target

      \${machineProvision}/bin/machine-provision \\
        --root /mnt/target \\
        --hostname $host_name_q \\
        $state_version_args_q \\
        --skip-facter

      expected_state_version=$state_version_q
      if [ -z "\$expected_state_version" ]; then
        expected_state_version="\$(. /etc/os-release && printf '%s\n' "\$VERSION_ID")"
      fi

      test -f /mnt/target/etc/nixos/machine/identity.json
      test -f /mnt/target/etc/nixos/machine/hostname

      jq -e \\
        --arg hostName $host_name_q \\
        --arg stateVersion "\$expected_state_version" \\
        '.hostName == \$hostName and .stateVersion == \$stateVersion' \\
        /mnt/target/etc/nixos/machine/identity.json

      grep -Fx $host_name_q /mnt/target/etc/nixos/machine/hostname

      touch /tmp/machine-provision-qemu-test-passed
      umount /mnt/target
      systemctl poweroff
    '';
  };

  system.stateVersion = "25.11";
}
EOF

echo "building test installer ISO for $system"
iso_out="$(
  nix build "${extra_features[@]}" "${flake_flags[@]}" \
    --no-link --print-out-paths \
    --expr "let
      flake = builtins.getFlake \"git+file://$repo_root\";
      nixpkgs = flake.inputs.nixpkgs;
      system = \"$system\";
      nixos = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ \"$workdir/installer-test.nix\" ];
      };
    in nixos.config.system.build.isoImage" \
    --impure
)"

iso_path="$(find "$iso_out/iso" -maxdepth 1 -type f -name '*.iso' -print -quit)"
if [[ -z "$iso_path" ]]; then
  echo "could not find built ISO under $iso_out/iso" >&2
  exit 1
fi

disk_path="$workdir/target.qcow2"
qemu-img create -f qcow2 "$disk_path" "${disk_size_mib}M" >/dev/null

qemu_root="$(dirname "$(dirname "$(command -v qemu-img)")")"
qemu_share="$qemu_root/share/qemu"

case "$system" in
  aarch64-linux)
    qemu_bin="qemu-system-aarch64"
    firmware="$qemu_share/edk2-aarch64-code.fd"
    machine_arg="virt,accel=hvf"
    qemu_args=(
      -machine "$machine_arg"
      -cpu host
      -m "$memory"
      -display none
      -serial mon:stdio
      -bios "$firmware"
      -cdrom "$iso_path"
      -drive "file=$disk_path,if=virtio,format=qcow2"
      -device virtio-rng-pci
      -boot d
      -no-reboot
    )
    ;;
  x86_64-linux)
    qemu_bin="qemu-system-x86_64"
    accel="tcg"
    if [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "x86_64" ]]; then
      accel="hvf"
    elif [[ "$(uname -s)" == "Linux" ]]; then
      accel="kvm:tcg"
    fi
    machine_arg="q35,accel=$accel"
    qemu_args=(
      -machine "$machine_arg"
      -m "$memory"
      -display none
      -serial mon:stdio
      -cdrom "$iso_path"
      -drive "file=$disk_path,if=virtio,format=qcow2"
      -device virtio-rng-pci
      -boot d
      -no-reboot
    )
    ;;
esac

if [[ "$(uname -s)" == "Darwin" && "$system" == "aarch64-linux" && "$(uname -m)" != "arm64" ]]; then
  echo "aarch64-linux QEMU test on Darwin requires Apple Silicon." >&2
  exit 1
fi

echo "running QEMU installer test"
timeout --foreground -k 10 "$timeout_seconds" "$qemu_bin" "${qemu_args[@]}"
echo "machine-provision QEMU test passed"
