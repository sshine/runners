{ config, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages = {
        nixos = config.lib.nixosRunner { inherit pkgs; };
      };
    };
}
