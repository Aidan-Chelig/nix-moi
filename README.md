# nix-moi

`nix-moi` is a Nix flake for treating machine-specific data as machine-owned state instead of flake-owned configuration.

In practice, that means values like:

- hardware facts
- filesystem layout
- `system.stateVersion`
- `networking.hostName`

do not need to be committed into a host flake. Instead, this repository provides NixOS modules that read those values from machine-local files under `/etc/nixos/machine`.

## Why "moi"

`moi` stands for "machine owns identity".

That is the core idea of this repository: identity and other machine-local facts belong to the machine being installed or managed, not to the shared flake that describes the system.

## Why use it

This project is useful when you want to reuse a single flake across a fleet of machines without hard-coding per-machine identity into that flake.

Instead of committing separate hostname, `system.stateVersion`, hardware facts, and filesystem layout for every host, you can keep one shared system definition and let each machine provide its own local identity data under `/etc/nixos/machine`.

That makes it easier to:

- reuse the same flake across many similar systems
- reduce per-host boilerplate in the repository
- keep installation-time and hardware-specific details with the machine they belong to
- avoid mixing shared system intent with machine-local state

## What it exports

This flake exports:

- `nixosModules.machine-identity`
- `nixosModules.machine-filesystems`
- `packages.<system>.machine-provision`
- `packages.<system>.machine-filesystems-provision`
- `packages.<system>.qemu-machine-provision-test`

Supported systems for flake outputs:

- `x86_64-linux`
- `aarch64-linux`
- `x86_64-darwin`
- `aarch64-darwin`

The NixOS modules are intended for Linux hosts. The provisioning helpers are exposed as flake apps as well.

## Machine-owned files

The modules read machine-local state from `/etc/nixos/machine`:

- `identity.json`
- `hostname`
- `facter.json`
- `filesystems.json`

### `identity.json`

Expected shape:

```json
{
  "hostName": "my-host",
  "stateVersion": "25.11"
}
```

`machine-identity` uses this to set:

- `networking.hostName`
- `system.stateVersion`
- `hardware.facter.report` when `facter.json` exists

It also exposes:

- `config.machineIdentity.directory`
- `config.machineIdentity.hostName`
- `config.machineIdentity.stateVersion`

### `filesystems.json`

Expected shape:

```json
{
  "fileSystems": {
    "/": {
      "uuid": "xxxx-xxxx",
      "fsType": "ext4"
    }
  },
  "swapDevices": []
}
```

`machine-filesystems` converts that JSON into NixOS `fileSystems` and `swapDevices`.

Entries may specify `device`, `uuid`, or `label`.

## Usage

Add this flake as an input and import the modules in your host configuration:

```nix
{
  inputs.nix-moi.url = "github:Aidan-Chelig/nix-moi";

  outputs = { self, nixpkgs, nix-moi, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nix-moi.nixosModules.machine-identity
        nix-moi.nixosModules.machine-filesystems
        ./configuration.nix
      ];
    };
  };
}
```

With those modules imported, `configuration.nix` can omit hard-coded hostname, state version, and filesystem device declarations, as long as the corresponding files exist under `/etc/nixos/machine`.

Because those values are read from machine-local paths at evaluation time, builds and rebuilds that use these modules need to be run with `--impure`.

## Provisioning a real machine

Mount the target system at `/mnt` as usual, then write the machine-owned state into that target root:

```sh
nix run github:Aidan-Chelig/nix-moi#machine-provision -- \
  --root /mnt \
  --hostname my-host

nix run github:Aidan-Chelig/nix-moi#machine-filesystems-provision -- \
  --root /mnt
```

`machine-provision`:

- writes `/etc/nixos/machine/identity.json`
- writes `/etc/nixos/machine/hostname`
- writes `/etc/nixos/machine/facter.json` when `nixos-facter` is available
- infers `stateVersion` from the running system unless you pass `--state-version`

`machine-filesystems-provision`:

- inspects mounts under the target root
- writes `/etc/nixos/machine/filesystems.json`
- records devices by UUID or label when possible

After that, evaluate or install the host normally with `nixos-install` or `nixos-rebuild`.

In practice, that means using impure evaluation for system builds, for example:

```sh
sudo nixos-rebuild switch --flake .#my-host --impure
```

or:

```sh
sudo nixos-install --flake .#my-host --impure
```

## Local evaluation

Both modules support `MACHINE_TARGET_ROOT` for impure local evaluation against a temporary directory instead of the real `/etc/nixos/machine`.

Example:

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

There is also a worked example in [examples/nixos-machine-identity/README.md](/home/icy/development/nix/nix-moi/examples/nixos-machine-identity/README.md).

## Notes

- `machine-identity` asserts that hostname and state version are present.
- `machine-filesystems` asserts that `filesystems.json` exists and includes `fileSystems."/"`.
- `machine-filesystems-provision` is only exposed on Linux systems.
- `qemu-machine-provision-test` is included for provisioning test workflows.
