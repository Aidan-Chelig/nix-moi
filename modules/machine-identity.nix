{ ... }:
{
  flake.nixosModules.machine-identity = { config, lib, ... }:
    let
      trim = s: builtins.replaceStrings [ "\n" "\r" "\t" " " ] [ "" "" "" "" ] s;

      targetRoot = builtins.getEnv "MACHINE_TARGET_ROOT";
      prefix = if targetRoot != "" then targetRoot else "";

      dir = "${prefix}/etc/nixos/machine";
      identityPath = "${dir}/identity.json";
      hostnamePath = "${dir}/hostname";
      facterPath = "${dir}/facter.json";

      readOr = path: fallback:
        if builtins.pathExists path then builtins.readFile path else fallback;

      identityJson =
        if builtins.pathExists identityPath
        then builtins.fromJSON (builtins.readFile identityPath)
        else {};

      hostnameFromFile = trim (readOr hostnamePath "");
      hostName =
        identityJson.hostName or identityJson.hostname or (
          if hostnameFromFile != "" then hostnameFromFile else ""
        );
      stateVersion = identityJson.stateVersion or "";
      hasFacter = builtins.pathExists facterPath;
    in
    {
      options.machineIdentity = {
        directory = lib.mkOption {
          type = lib.types.path;
          readOnly = true;
          default = /etc/nixos/machine;
          description = "Directory containing machine-local identity files.";
        };

        hostName = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = hostName;
          description = "Machine hostname read from machine identity state.";
        };

        stateVersion = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = stateVersion;
          description = "Original NixOS state version for this machine.";
        };
      };

      config = lib.mkMerge [
        {
          assertions = [
            {
              assertion = hostName != "";
              message = "machine identity is missing hostName/hostname in ${identityPath}";
            }
            {
              assertion = stateVersion != "";
              message = "machine identity is missing stateVersion in ${identityPath}";
            }
          ];
        }
        (lib.mkIf (hostName != "") {
          networking.hostName = hostName;
        })
        (lib.mkIf (stateVersion != "") {
          system.stateVersion = stateVersion;
        })
        (lib.mkIf hasFacter {
          hardware.facter.report = builtins.fromJSON (builtins.readFile facterPath);
        })
      ];
    };
}
