{ ... }:
{
  perSystem =
    { pkgs, ... }:
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

      # Jobs run as root, which suits nix: the store lives inside the container and only
      # root can write it. Some tools refuse to run as root at all -- postgres' initdb
      # is the one that started this -- so a step that needs an unprivileged user wraps
      # itself in this rather than the workflow spelling out setpriv every time.
      #
      # Deliberately not an image-wide USER: that would take nix's store writes with it.
      asRunner = pkgs.writeShellScriptBin "as-runner" ''
        exec ${pkgs.util-linux}/bin/setpriv \
          --reuid=1000 --regid=1000 --clear-groups \
          env HOME=/home/runner "$@"
      '';

      rootEnv = buildEnv {
        name = "root-env";
        paths = [
          nixProfile
          pkgs.bashInteractive
          pkgs.coreutils
          pkgs.diffutils
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
          pkgs.just
          pkgs.cpio
          pkgs.nodejs
          pkgs.skopeo
          # Only the wrapper. util-linux itself stays off PATH, where it would take
          # kill and more away from coreutils for every job; as-runner reaches setpriv
          # by store path, so the closure is here either way.
          asRunner
        ];
        pathsToLink = [
          "/bin"
          "/etc"
          "/lib"
          "/share"
        ];
      };

      # The in-cluster cache is an nginx proxy in front of cache.nixos.org that
      # passes upstream signatures through, so it needs no key of its own. Keep
      # cache.nixos.org listed after it: an outage there should slow builds down
      # rather than break them.
      nixConf = writeTextDir "etc/nix/nix.conf" ''
        build-users-group =
        experimental-features = nix-command flakes
        sandbox = true
        # sandbox = true is a request, not a guarantee: nix builds without one whenever
        # the kernel namespaces are unavailable, and says so only at debug level. Those
        # builds run impure and usually still pass, until one leaves /homeless-shelter
        # behind and every later build in the container refuses to start. Failing where
        # the sandbox is lost costs one clear error instead of a chain of odd ones.
        sandbox-fallback = false
        substituters = http://nix-cache.nix-cache.svc.cluster.local:8080 https://cache.nixos.org
        trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
        extra-platforms = x86_64-linux aarch64-linux
      '';

      sslCerts = runCommandLocal "ssl-certs" { } ''
        mkdir -p $out/etc/ssl/certs
        ln -s ${cacert}/etc/ssl/certs/ca-bundle.crt $out/etc/ssl/certs/ca-certificates.crt
      '';

    in
    {
      packages.nixos = pkgs.dockerTools.buildImage {
        name = "nixos";
        tag = "latest";

        copyToRoot = [
          rootEnv
          nixConf
          sslCerts
          (runCommandLocal "root-dirs" { } ''
            mkdir -p $out/tmp
            mkdir -p $out/var/tmp
            mkdir -p $out/root
            mkdir -p $out/nix/var/nix
            mkdir -p $out/etc
            mkdir -p $out/usr/bin
            ln -s ${pkgs.coreutils}/bin/env $out/usr/bin/env

            # initdb calls getpwuid on its own uid and fails outright if it resolves to
            # nothing, so as-runner's uid has to be a real entry rather than just a
            # number handed to setpriv.
            echo "root:x:0:0:root:/root:/bin/bash" > $out/etc/passwd
            echo "runner:x:1000:1000:runner:/home/runner:/bin/bash" >> $out/etc/passwd
            echo "root:x:0:" > $out/etc/group
            echo "runner:x:1000:" >> $out/etc/group
          '')
        ];

        # Store paths are read-only, so the two directories an unprivileged step writes
        # to are made writable here instead. Ownership cannot be set without a VM build,
        # and these containers are per-job anyway, so the modes carry it.
        extraCommands = ''
          mkdir -p tmp home/runner
          chmod 1777 tmp
          chmod 0777 home/runner
        '';

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
    };
}
