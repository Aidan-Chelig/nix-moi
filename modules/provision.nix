{ ... }:
{
  perSystem = { lib, pkgs, ... }:
    let
      machine-provision = pkgs.writeShellApplication {
        name = "machine-provision";
        runtimeInputs =
          with pkgs; [
            bash
            coreutils
            jq
            gum
          ]
          ++ lib.optional
            (pkgs ? nixos-facter && lib.meta.availableOn pkgs.stdenv.hostPlatform pkgs.nixos-facter)
            pkgs.nixos-facter;
        text = builtins.readFile ./machine-provision.sh;
      };

      qemu-machine-provision-test = pkgs.writeShellApplication {
        name = "qemu-machine-provision-test";
        runtimeInputs = with pkgs; [
          bash
          coreutils
          nix
          qemu
        ];
        text = builtins.readFile ../scripts/qemu-machine-provision-test.sh;
      };

      machine-filesystems-provision = pkgs.writeShellApplication {
        name = "machine-filesystems-provision";
        runtimeInputs = with pkgs; [
          bash
          coreutils
          jq
          util-linux
        ];
        text = builtins.readFile ./machine-filesystems-provision.sh;
      };
    in
    {
      packages = {
        machine-provision = machine-provision;
        qemu-machine-provision-test = qemu-machine-provision-test;
      }
      // lib.optionalAttrs pkgs.stdenv.isLinux {
        machine-filesystems-provision = machine-filesystems-provision;
      };

      apps = {
        machine-provision = {
          type = "app";
          program = "${machine-provision}/bin/machine-provision";
        };

        qemu-machine-provision-test = {
          type = "app";
          program = "${qemu-machine-provision-test}/bin/qemu-machine-provision-test";
        };
      }
      // lib.optionalAttrs pkgs.stdenv.isLinux {
        machine-filesystems-provision = {
          type = "app";
          program = "${machine-filesystems-provision}/bin/machine-filesystems-provision";
        };
      };
    };
}
