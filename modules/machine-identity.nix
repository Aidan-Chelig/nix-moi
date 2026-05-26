{ ... }:
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

  machineIdentityOptions = { lib, ... }: {
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
  };

  machineHostname = { lib, ... }: {
    imports = [ machineIdentityOptions ];

    config = lib.mkMerge [
      {
        assertions = [
          {
            assertion = hostName != "";
            message = "machine identity is missing hostName/hostname in ${identityPath}";
          }
        ];
      }
      (lib.mkIf (hostName != "") {
        networking.hostName = hostName;
      })
    ];
  };

  machineStateVersion = { config, lib, pkgs, ... }:
    let
      initialStateVersion = config.machineStateVersion.initial;
      effectiveStateVersion =
        if stateVersion != ""
        then stateVersion
        else if initialStateVersion != null
        then initialStateVersion
        else "";
    in
    {
    imports = [ machineIdentityOptions ];

    options.machineStateVersion = {
      initial = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "25.11";
        description = ''
          Initial NixOS state version to use and persist when this machine does
          not already have machine-owned state version data.
        '';
      };
    };

    config = lib.mkMerge [
      {
        assertions = [
          {
            assertion = effectiveStateVersion != "";
            message = "machine identity is missing stateVersion in ${identityPath} and machineStateVersion.initial is not set";
          }
        ];
      }
      (lib.mkIf (effectiveStateVersion != "") {
        system.stateVersion = effectiveStateVersion;
      })
      (lib.mkIf (initialStateVersion != null) {
        system.activationScripts.nix-moi-machine-state-version.text = ''
          identity_dir=/etc/nixos/machine
          identity_path="$identity_dir/identity.json"

          mkdir -p "$identity_dir"

          if [ -f "$identity_path" ] \
            && ${pkgs.jq}/bin/jq -e '(.stateVersion // "") != ""' "$identity_path" >/dev/null 2>&1; then
            :
          elif [ -f "$identity_path" ] \
            && ${pkgs.jq}/bin/jq -e type "$identity_path" >/dev/null 2>&1; then
            tmp="$(${pkgs.coreutils}/bin/mktemp "$identity_path.XXXXXX")"
            ${pkgs.jq}/bin/jq \
              --arg stateVersion ${lib.escapeShellArg initialStateVersion} \
              '.stateVersion = $stateVersion' \
              "$identity_path" > "$tmp"
            ${pkgs.coreutils}/bin/mv "$tmp" "$identity_path"
          elif [ ! -e "$identity_path" ]; then
            ${pkgs.jq}/bin/jq -n \
              --arg stateVersion ${lib.escapeShellArg initialStateVersion} \
              '{ stateVersion: $stateVersion }' > "$identity_path"
          else
            echo "not writing $identity_path because it exists but is not valid JSON" >&2
          fi
        '';
      })
    ];
  };

  machineFacter = { lib, ... }: {
    imports = [ machineIdentityOptions ];

    config = lib.mkIf hasFacter {
      hardware.facter.report = builtins.fromJSON (builtins.readFile facterPath);
    };
  };
in
{
  flake.nixosModules = {
    machine-hostname = machineHostname;
    machine-state-version = machineStateVersion;
    machine-facter = machineFacter;

    machine-identity = {
      imports = [
        machineHostname
        machineStateVersion
        machineFacter
      ];
    };
  };
}
