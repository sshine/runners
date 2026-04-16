{ inputs, ... }:
{
  imports = [ inputs.devshell.flakeModule ];

  perSystem =
    { pkgs, ... }:
    {
      devshells.default = {
        packages = [
          pkgs.just
          pkgs.skopeo
        ];
      };
    };
}
