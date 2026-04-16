{ config, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages = {
        nixos-runner = config.lib.nixosRunner { inherit pkgs; };
      };
    };
}
