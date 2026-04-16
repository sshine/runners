{
  description = "Forgejo CI runner images";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    import-tree.url = "github:vic/import-tree";

    devshell.url = "github:numtide/devshell";
    devshell.inputs.nixpkgs.follows = "nixpkgs";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      flake-parts,
      import-tree,
      ...
    }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } (
      {
        systems = [ "x86_64-linux" "aarch64-linux" ];
      }
      // import-tree ./nix
    );
}
