{
  description = "Example NixOS configuration using lgnix machine identity";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/25.11";

    # In a real host config, replace this with the repo URL, for example:
    # lgnix.url = "github:aidan-chelig/machine-owned-identity";
    lgnix.url = "path:../..";
  };

  outputs =
    { lgnix, nixpkgs, ... }:
    {
      nixosConfigurations.example = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          lgnix.nixosModules.machine-identity
          lgnix.nixosModules.machine-filesystems
          ./configuration.nix
        ];
      };
    };
}
