{ config, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages = {
        nixos-unstable = config.lib.nixosRunner { inherit pkgs; };
      };
    };
}
