{
  config,
  lib,
  ...
}:
{
  options.mesa-git = {
    enable = lib.mkEnableOption "Use mesa-git (bleeding-edge) instead of nixpkgs mesa";

    drivers = lib.mkOption {
      type = lib.types.listOf (
        lib.types.enum [
          "amd"
          "intel"
          "nvidia"
        ]
      );
      default = [ ];
      example = [ "amd" ];
      description = ''
        GPU vendors to compile drivers for. Only the selected vendor drivers
        plus common essentials (llvmpipe, zink, virgl, swrast) are built.

        Use multiple entries for multi-GPU setups (e.g. Intel iGPU + NVIDIA dGPU).
        An empty list (default) builds all drivers.
      '';
    };
  };

  config = lib.mkIf config.mesa-git.enable (
    let
      mesaPkg =
        if config.mesa-git.drivers == [ ] then
          config._module.args.pkgs.mesa-git
        else
          config._module.args.pkgs.mkMesaGit { vendors = config.mesa-git.drivers; };

      mesaPkg32 =
        if config._module.args.pkgs.stdenv.hostPlatform.isx86_64 then
          if config.mesa-git.drivers == [ ] then
            config._module.args.pkgs.pkgsi686Linux.mesa-git
          else
            config._module.args.pkgs.mkMesaGit32 { vendors = config.mesa-git.drivers; }
        else
          null;
    in
    {
      hardware.graphics.package = mesaPkg;
      hardware.graphics.package32 = mesaPkg32;
    }
  );
}
