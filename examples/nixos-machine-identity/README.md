# NixOS Machine State Example

This example consumes `lgnix.nixosModules.machine-identity` and
`lgnix.nixosModules.machine-filesystems` directly. It keeps hostname,
`system.stateVersion`, and filesystem UUIDs out of `configuration.nix`; those
values come from machine-local files under `/etc/nixos/machine`.

For local evaluation, create machine state files in a temporary target root and
point `MACHINE_TARGET_ROOT` at it:

```sh
target_root=$(mktemp -d)
nix run .#machine-provision -- \
  --root "$target_root" \
  --hostname example-machine \
  --state-version 25.11 \
  --skip-facter

mkdir -p "$target_root/etc/nixos/machine"
cat >"$target_root/etc/nixos/machine/filesystems.json" <<'JSON'
{
  "fileSystems": {
    "/": {
      "device": "/dev/disk/by-label/nixos",
      "fsType": "ext4"
    }
  },
  "swapDevices": []
}
JSON

MACHINE_TARGET_ROOT=$target_root \
  nix eval --impure ./examples/nixos-machine-identity#nixosConfigurations.example.config.networking.hostName
```

On a real machine, mount the target filesystems under `/mnt`, then provision the
machine-local state before evaluating the NixOS configuration:

```sh
nix run github:achelig/lgnix2.0#machine-provision -- \
  --root /mnt \
  --hostname my-host

nix run github:achelig/lgnix2.0#machine-filesystems-provision -- \
  --root /mnt
```

Then import the `machine-identity` and `machine-filesystems` modules in that
host's flake and use `nixos-install` or `nixos-rebuild` as usual.
