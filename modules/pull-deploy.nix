{ ... }:
{
  flake.nixosModules.machine-pull-deploy = { config, lib, pkgs, ... }:
    let
      cfg = config.machinePullDeploy;

      sshOptions =
        lib.optional (cfg.ssh.identityFile != null) "-i ${lib.escapeShellArg cfg.ssh.identityFile}"
        ++ lib.optional (cfg.ssh.identityFile != null) "-o IdentitiesOnly=yes"
        ++ lib.optional (cfg.ssh.knownHostsFile != null) "-o UserKnownHostsFile=${lib.escapeShellArg cfg.ssh.knownHostsFile}"
        ++ lib.optional cfg.ssh.acceptNewHostKeys "-o StrictHostKeyChecking=accept-new";

      sshCommand = lib.concatStringsSep " " ([ "${pkgs.openssh}/bin/ssh" ] ++ sshOptions);

      refFetchScript = {
        branch = ''
          ${pkgs.git}/bin/git fetch --prune origin ${lib.escapeShellArg "+refs/heads/${cfg.repository.ref}:refs/remotes/origin/${cfg.repository.ref}"}
          new_rev="$(${pkgs.git}/bin/git rev-parse ${lib.escapeShellArg "refs/remotes/origin/${cfg.repository.ref}"})"
          ${pkgs.git}/bin/git checkout -B nix-moi-deploy "$new_rev"
        '';

        tag = ''
          ${pkgs.git}/bin/git fetch --prune --tags origin ${lib.escapeShellArg "refs/tags/${cfg.repository.ref}:refs/tags/${cfg.repository.ref}"}
          new_rev="$(${pkgs.git}/bin/git rev-parse ${lib.escapeShellArg "refs/tags/${cfg.repository.ref}^{commit}"})"
          ${pkgs.git}/bin/git checkout --detach "$new_rev"
        '';

        rev = ''
          ${pkgs.git}/bin/git fetch --prune origin
          new_rev="$(${pkgs.git}/bin/git rev-parse ${lib.escapeShellArg "${cfg.repository.ref}^{commit}"})"
          ${pkgs.git}/bin/git checkout --detach "$new_rev"
        '';
      }.${cfg.repository.refType};

      rebuildArgs = lib.concatMapStringsSep " " lib.escapeShellArg cfg.extraRebuildArgs;

      deployScript = pkgs.writeShellScript "nix-moi-pull-deploy" ''
        set -euo pipefail

        state_dir=${lib.escapeShellArg cfg.stateDir}
        repo_dir="$state_dir/repo"
        home_dir="$state_dir/home"
        lock_file="$state_dir/deploy.lock"
        deployed_rev_file="$state_dir/deployed-rev"

        umask 077
        mkdir -p "$state_dir" "$home_dir"
        export HOME="$home_dir"
        export GIT_TERMINAL_PROMPT=0
        ${lib.optionalString (sshOptions != []) ''
          export GIT_SSH_COMMAND=${lib.escapeShellArg sshCommand}
        ''}

        exec 9>"$lock_file"
        if ! ${pkgs.util-linux}/bin/flock -n 9; then
          echo "nix-moi pull deploy is already running; exiting"
          exit 0
        fi

        if [ ! -d "$repo_dir/.git" ]; then
          rm -rf "$repo_dir"
          ${pkgs.git}/bin/git clone --no-checkout ${lib.escapeShellArg cfg.repository.url} "$repo_dir"
        fi

        cd "$repo_dir"
        ${pkgs.git}/bin/git remote set-url origin ${lib.escapeShellArg cfg.repository.url}

        ${refFetchScript}

        previous_deployed_rev=""
        if [ -f "$deployed_rev_file" ]; then
          previous_deployed_rev="$(cat "$deployed_rev_file")"
        fi

        if [ "$new_rev" = "$previous_deployed_rev" ]; then
          echo "already deployed $new_rev; no rebuild needed"
          exit 0
        fi

        echo "deploying $new_rev with nixos-rebuild ${cfg.rebuildMode}"
        ${pkgs.nixos-rebuild}/bin/nixos-rebuild ${cfg.rebuildMode} \
          --flake "$repo_dir#${cfg.flakeAttribute}" \
          --impure \
          ${rebuildArgs}

        printf '%s\n' "$new_rev" > "$deployed_rev_file"
      '';
    in
    {
      options.machinePullDeploy = {
        enable = lib.mkEnableOption "poll-based pull deployment for this NixOS host";

        repository = {
          url = lib.mkOption {
            type = lib.types.str;
            example = "git@github.com:example/infrastructure.git";
            description = "Git repository containing the NixOS flake to deploy.";
          };

          ref = lib.mkOption {
            type = lib.types.str;
            default = "main";
            example = "release-2026-05";
            description = "Branch, tag, or revision to deploy.";
          };

          refType = lib.mkOption {
            type = lib.types.enum [ "branch" "tag" "rev" ];
            default = "branch";
            description = "How to interpret machinePullDeploy.repository.ref.";
          };
        };

        flakeAttribute = lib.mkOption {
          type = lib.types.str;
          default = config.networking.hostName;
          defaultText = lib.literalExpression "config.networking.hostName";
          example = "my-host";
          description = "Flake attribute to pass to nixos-rebuild, without the leading '#'.";
        };

        rebuildMode = lib.mkOption {
          type = lib.types.enum [ "switch" "boot" ];
          default = "switch";
          description = "nixos-rebuild operation to run when the fetched revision changes.";
        };

        schedule = lib.mkOption {
          type = lib.types.str;
          default = "hourly";
          example = "*:0/15";
          description = "systemd OnCalendar expression controlling how often to poll.";
        };

        randomizedDelaySec = lib.mkOption {
          type = lib.types.str;
          default = "30min";
          example = "2h";
          description = "systemd RandomizedDelaySec value used to avoid thundering herd deploys.";
        };

        fixedRandomDelay = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether each machine should keep a stable randomized offset within randomizedDelaySec.";
        };

        persistent = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether missed timer runs should execute after boot.";
        };

        stateDir = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/nix-moi/pull-deploy";
          description = "Writable local state directory for the cloned repository and deploy metadata.";
        };

        extraRebuildArgs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          example = [ "--option" "substituters" "https://cache.nixos.org" ];
          description = "Additional arguments passed to nixos-rebuild after --impure.";
        };

        environmentFiles = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          example = [ "/run/secrets/nix-moi-pull-deploy.env" ];
          description = "Environment files loaded by the systemd service for tokens or other secret configuration.";
        };

        ssh = {
          identityFile = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "/run/secrets/nix-moi-deploy-key";
            description = "Optional SSH private key path used for Git fetches. Use a runtime secret path, not a Nix store path.";
          };

          knownHostsFile = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "/etc/ssh/ssh_known_hosts";
            description = "Optional known_hosts file used for Git fetches.";
          };

          acceptNewHostKeys = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether Git SSH fetches should accept new host keys automatically.";
          };
        };
      };

      config = lib.mkIf cfg.enable {
        assertions = [
          {
            assertion = cfg.repository.url != "";
            message = "machinePullDeploy.repository.url must not be empty";
          }
        ];

        systemd.services.nix-moi-pull-deploy = {
          description = "Poll and apply NixOS configuration from a Git flake";
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          environment.MACHINE_TARGET_ROOT = "/";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = deployScript;
            EnvironmentFile = cfg.environmentFiles;
            Nice = 10;
            IOSchedulingClass = "best-effort";
            IOSchedulingPriority = 7;
          };
        };

        systemd.timers.nix-moi-pull-deploy = {
          description = "Poll for NixOS configuration updates";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = cfg.schedule;
            RandomizedDelaySec = cfg.randomizedDelaySec;
            FixedRandomDelay = cfg.fixedRandomDelay;
            Persistent = cfg.persistent;
            Unit = "nix-moi-pull-deploy.service";
          };
        };
      };
    };
}
