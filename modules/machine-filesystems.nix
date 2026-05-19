{ ... }:
{
  flake.nixosModules.machine-filesystems = { lib, ... }:
    let
      targetRoot = builtins.getEnv "MACHINE_TARGET_ROOT";
      prefix = if targetRoot != "" then targetRoot else "";

      path = "${prefix}/etc/nixos/machine/filesystems.json";
      data =
        if builtins.pathExists path
        then builtins.fromJSON (builtins.readFile path)
        else {};

      fileSystemsData = data.fileSystems or {};
      swapDevicesData = data.swapDevices or [];

      deviceFor = spec:
        if spec ? device then spec.device
        else if spec ? uuid then "/dev/disk/by-uuid/${spec.uuid}"
        else if spec ? label then "/dev/disk/by-label/${spec.label}"
        else "";

      toFileSystem = _: spec: {
        device = deviceFor spec;
        fsType = spec.fsType or spec.fs or "auto";
      } // lib.optionalAttrs (spec ? options) {
        inherit (spec) options;
      };

      toSwapDevice = spec:
        if spec ? device then { device = spec.device; }
        else if spec ? uuid then { device = "/dev/disk/by-uuid/${spec.uuid}"; }
        else if spec ? label then { device = "/dev/disk/by-label/${spec.label}"; }
        else {};
    in
    {
      options.machineFilesystems = {
        path = lib.mkOption {
          type = lib.types.path;
          readOnly = true;
          default = /etc/nixos/machine/filesystems.json;
          description = "Machine-local filesystem layout file.";
        };
      };

      config = {
        assertions = [
          {
            assertion = data != {};
            message = "machine filesystem layout is missing at ${path}";
          }
          {
            assertion = fileSystemsData ? "/";
            message = "machine filesystem layout in ${path} is missing fileSystems.\"/\"";
          }
        ];

        fileSystems = lib.mapAttrs toFileSystem fileSystemsData;
        swapDevices = map toSwapDevice swapDevicesData;
      };
    };
}
