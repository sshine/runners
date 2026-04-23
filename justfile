list:
    @just --list --unsorted

bump:
    nix flake update

    @last_modified=$(nix eval --impure --expr \
      '(builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.nixpkgs.locked.lastModified') && \
        date_tag=$(date -u -d "@${last_modified}" +%Y%m%d) && \
        git add flake.lock && \
        git commit -m "chore(ci): Update nixos to ${date_tag}" && \
        git push
