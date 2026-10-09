# A forgejo-runner daemon image, as a fallback for the official one.
#
# The cluster pulls data.forgejo.org/forgejo/runner and should keep doing so; this
# exists for the day a patch has to go into the daemon itself, when having the build
# already working is worth more than the image is.
#
# Shaped for the runner-k8s chart's invocation: it runs `sh -ec 'exec
# /bin/forgejo-runner daemon ...'` as uid 1000 with a read-only root, so the image
# needs those two binaries on an absolute path, a CA bundle for the forge over
# https, and nothing else.
{ ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      inherit (pkgs)
        buildEnv
        runCommandLocal
        cacert
        forgejo-runner
        ;

      rootEnv = buildEnv {
        name = "runner-root-env";
        paths = [
          forgejo-runner
          pkgs.busybox
          cacert
        ];
        pathsToLink = [
          "/bin"
          "/etc"
        ];
      };
    in
    {
      packages.runner = pkgs.dockerTools.buildImage {
        name = "forgejo-runner";
        tag = forgejo-runner.version;

        copyToRoot = [
          rootEnv
          (runCommandLocal "runner-root-dirs" { } ''
            mkdir -p $out/etc/ssl/certs $out/tmp $out/data
            ln -s ${cacert}/etc/ssl/certs/ca-bundle.crt \
              $out/etc/ssl/certs/ca-certificates.crt

            # The daemon runs unprivileged under the chart's podSecurityContext, and
            # Go's os/user resolves the uid before anything else does.
            echo "root:x:0:0:root:/root:/bin/sh" > $out/etc/passwd
            echo "runner:x:1000:1000:runner:/data:/bin/sh" >> $out/etc/passwd
            echo "root:x:0:" > $out/etc/group
            echo "runner:x:1000:" >> $out/etc/group
          '')
        ];

        extraCommands = ''
          mkdir -p tmp data
          chmod 1777 tmp
          chmod 0777 data
        '';

        config = {
          Entrypoint = [ "/bin/forgejo-runner" ];
          User = "1000:1000";
          Env = [
            "PATH=/bin"
            "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
            "HOME=/data"
          ];
          WorkingDir = "/data";
        };
      };
    };
}
