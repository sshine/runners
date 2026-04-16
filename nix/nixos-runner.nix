{ lib, ... }:

let
  mkNixosRunner =
    { pkgs }:
    let
      inherit (pkgs)
        runCommandLocal
        buildEnv
        writeTextDir
        cacert
        ;

      nixProfile = runCommandLocal "nix-profile" { } ''
        mkdir -p $out/bin
        ln -s ${pkgs.nix}/bin/nix $out/bin/nix
        ln -s ${pkgs.nix}/bin/nix-store $out/bin/nix-store
        ln -s ${pkgs.nix}/bin/nix-build $out/bin/nix-build
        ln -s ${pkgs.nix}/bin/nix-shell $out/bin/nix-shell
        ln -s ${pkgs.nix}/bin/nix-env $out/bin/nix-env
        ln -s ${pkgs.nix}/bin/nix-instantiate $out/bin/nix-instantiate
        ln -s ${pkgs.nix}/bin/nix-hash $out/bin/nix-hash
        ln -s ${pkgs.nix}/bin/nix-copy-closure $out/bin/nix-copy-closure
      '';

      rootEnv = buildEnv {
        name = "root-env";
        paths = [
          nixProfile
          pkgs.bashInteractive
          pkgs.coreutils
          pkgs.git
          pkgs.git-lfs
          pkgs.curl
          pkgs.cacert
          pkgs.gnutar
          pkgs.gzip
          pkgs.bzip2
          pkgs.xz
          pkgs.zstd
          pkgs.openssh
          pkgs.gnugrep
          pkgs.gnused
          pkgs.gawk
          pkgs.findutils
          pkgs.which
          pkgs.file
          pkgs.gnumake
          pkgs.cpio
        ];
        pathsToLink = [
          "/bin"
          "/etc"
          "/lib"
          "/share"
        ];
      };

      nixConf = writeTextDir "etc/nix/nix.conf" ''
        build-users-group =
        experimental-features = nix-command flakes
        sandbox = false
        substituters = https://cache.nixos.org
        trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
        extra-platforms = x86_64-linux aarch64-linux
      '';

      sslCerts = runCommandLocal "ssl-certs" { } ''
        mkdir -p $out/etc/ssl/certs
        ln -s ${cacert}/etc/ssl/certs/ca-bundle.crt $out/etc/ssl/certs/ca-certificates.crt
      '';

    in
    pkgs.dockerTools.buildImage {
      name = "nixos-unstable";
      tag = "latest";

      copyToRoot = [
        rootEnv
        nixConf
        sslCerts
        (runCommandLocal "root-dirs" { } ''
          mkdir -p $out/tmp
          mkdir -p $out/root
          mkdir -p $out/nix/var/nix
          mkdir -p $out/etc
          echo "root:x:0:0:root:/root:/bin/bash" > $out/etc/passwd
          echo "root:x:0:" > $out/etc/group
        '')
      ];

      config = {
        Cmd = [ "/bin/bash" ];
        Env = [
          "PATH=/bin"
          "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
          "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
          "NIX_PATH=nixpkgs=channel:nixpkgs-unstable"
          "HOME=/root"
        ];
        WorkingDir = "/root";
      };
    };

in
{
  options.lib.nixosRunner = lib.mkOption {
    type = lib.types.raw;
  };

  config.lib.nixosRunner = mkNixosRunner;
}
