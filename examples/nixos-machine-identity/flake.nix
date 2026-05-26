{
  description = "Example NixOS configuration using nix-moi machine identity";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/25.11";

    # In a real host config, replace this with the repo URL, for example:
    # nix-moi.url = "github:Aidan-Chelig/nix-moi";
    nix-moi.url = "path:../..";
  };

  outputs =
    { nix-moi, nixpkgs, ... }:
    {
      nixosConfigurations.example = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          nix-moi.nixosModules.machine-hostname
          nix-moi.nixosModules.machine-state-version
          nix-moi.nixosModules.machine-filesystems
          ./configuration.nix
        ];
      };
    };
}
