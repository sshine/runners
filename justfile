image := "git.shine.town/infra/runners/nixos"

list:
    @just --list --unsorted

build:
    nix build .#nixos -o nixos.tar.gz

bump:
    nix flake update

    @last_modified=$(nix eval --impure --expr \
      '(builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.nixpkgs.locked.lastModified') && \
        date_tag=$(date -u -d "@${last_modified}" +%Y%m%d) && \
        git add flake.lock && \
        git commit -m "chore(ci): Update nixos to ${date_tag}" && \
        git push

# Push tarball as :latest, :unstable, and :<nixpkgs-date> (SKOPEO_DEST_CREDS env for CI)
push: build
    #!/usr/bin/env bash
    set -euo pipefail
    # SKOPEO_DEST_CREDS ("user:token") is consumed when set; absent → ambient
    # auth from ~/.config/containers/auth.json.
    last_modified=$(nix eval --impure --expr \
      '(builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.nixpkgs.locked.lastModified')
    date_tag=$(date -u -d "@${last_modified}" +%Y%m%d)
    args=""
    if [ -n "${SKOPEO_DEST_CREDS:-}" ]; then
      args="--dest-creds $SKOPEO_DEST_CREDS"
    fi
    for tag in latest unstable "$date_tag"; do
      nix run nixpkgs#skopeo -- copy --insecure-policy $args \
        docker-archive:nixos.tar.gz \
        "docker://{{image}}:$tag"
    done
