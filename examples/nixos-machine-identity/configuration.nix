{ config, lib, ... }:
{
  nixpkgs.hostPlatform = "x86_64-linux";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  users.users.example = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };

  services.openssh.enable = true;

  # These values come from lgnix.nixosModules.machine-identity, which reads
  # /etc/nixos/machine/identity.json on a real host. The checks below make that
  # dependency visible in this example without hard-coding host identity here.
  assertions = [
    {
      assertion = config.networking.hostName == config.machineIdentity.hostName;
      message = "machine identity did not set networking.hostName";
    }
    {
      assertion = config.system.stateVersion == config.machineIdentity.stateVersion;
      message = "machine identity did not set system.stateVersion";
    }
  ];
}
