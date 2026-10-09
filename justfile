image := "git.shine.town/infra/runners/nixos"
runner_image := "git.shine.town/infra/runners/forgejo-runner"
plugin_image := "git.shine.town/infra/runners/forgejo-runner-k8s"
plugin_upstream := "git.erwanleboucher.dev/eleboucher/runner-k8s-plugin"
plugin_version := "13.2.1"

list:
    @just --list --unsorted

build:
    nix build .#nixos -o nixos.tar.gz

build-runner:
    nix build .#runner -o forgejo-runner.tar.gz

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

# Push the fallback daemon image as :latest and :<forgejo-runner version>
#
# The cluster pulls the official daemon image. This one only has to exist and build.
push-runner: build-runner
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(nix eval --raw .#runner.imageTag)
    args=""
    if [ -n "${SKOPEO_DEST_CREDS:-}" ]; then
      args="--dest-creds $SKOPEO_DEST_CREDS"
    fi
    for tag in latest "$version"; do
      nix run nixpkgs#skopeo -- copy --insecure-policy $args \
        docker-archive:forgejo-runner.tar.gz \
        "docker://{{runner_image}}:$tag"
    done

# Mirror the Kubernetes backend plugin into the cluster's registry
#
# The plugin is a third party on a personal forge, and the runner pod will not start
# without its sidecar. Copying it here keeps that forge out of the pull path.
# --all carries every architecture in the manifest list rather than just this host's.
mirror-plugin:
    #!/usr/bin/env bash
    set -euo pipefail
    args=""
    if [ -n "${SKOPEO_DEST_CREDS:-}" ]; then
      args="--dest-creds $SKOPEO_DEST_CREDS"
    fi
    nix run nixpkgs#skopeo -- copy --all --insecure-policy $args \
      "docker://{{plugin_upstream}}:{{plugin_version}}" \
      "docker://{{plugin_image}}:{{plugin_version}}"

# Assert the built image contains what jobs rely on
#
# Reads the layer rather than running a container: the nixos runner has no docker daemon,
# and every claim below is about what is in the image rather than how it behaves.
test-image: build
    #!/usr/bin/env bash
    set -euo pipefail
    workdir=$(mktemp -d)
    # The layer preserves the store's read-only modes, so cleanup needs them back.
    trap 'chmod -R u+w "$workdir" 2>/dev/null; rm -rf "$workdir"' EXIT

    # Into a subdirectory: the tarball carries a mode for its own root, which would
    # otherwise land on $workdir and make the listing below unwritable.
    mkdir -p "$workdir/img"
    tar -xf nixos.tar.gz -C "$workdir/img"
    layer=$(find "$workdir/img" -name layer.tar | head -1)
    [ -n "$layer" ] || { echo "no layer.tar in the image" >&2; exit 1; }

    # Two listings: the verbose one carries modes, and the plain one is the only
    # reliable way to ask whether a path exists, because a verbose line for a symlink
    # ends in its target rather than in itself.
    listing="$workdir/listing"
    names="$workdir/names"
    tar -tvf "$layer" > "$listing"
    tar -tf "$layer" > "$names"

    fail() { echo "FAIL: $*" >&2; exit 1; }

    # initdb resolves its own uid through getpwuid and refuses a uid that is not there,
    # which is what as-runner would otherwise hand it.
    tar -xOf "$layer" ./etc/passwd | grep -q '^runner:x:1000:1000:' \
      || fail "no runner:1000 in /etc/passwd"

    # Store paths are read-only, so these two are the only places an unprivileged step
    # can write. Postgres puts its cluster in one and Go its build cache in the other.
    grep -qE '^drwxrwxrwt .* \./tmp/$' "$listing" || fail "/tmp is not 1777"
    grep -qE '^drwxrwxrwx .* \./home/runner/$' "$listing" || fail "/home/runner is not writable"

    # as-runner calls setpriv by store path rather than through PATH, so util-linux does
    # not take kill and more away from coreutils for every other job. That only works if
    # the binary it names is actually in the image.
    runner_script=$(sed -n "s|^l.* \./bin/as-runner -> ||p" "$listing" | head -1)
    [ -n "$runner_script" ] || fail "as-runner missing from /bin"
    setpriv_path=$(tar -xOf "$layer" "${runner_script#/}" \
      | grep -o '/nix/store/[^ ]*/bin/setpriv' | head -1)
    [ -n "$setpriv_path" ] || fail "as-runner does not call setpriv by store path"
    grep -qxF "${setpriv_path#/}" "$names" || fail "as-runner's setpriv is not in the image"

    for tool in as-runner just node skopeo nix; do
      # /bin is a tree of symlinks, so the entry reads "./bin/x -> /nix/store/...".
      target=$(sed -n "s|^l.* \./bin/$tool -> ||p" "$listing" | head -1)
      [ -n "$target" ] || fail "$tool missing from /bin"
      # And the target has to be in the image too: a symlink to a store path that was
      # never copied in passes any check on /bin alone, then fails on first use.
      grep -qxF "${target#/}" "$names" \
        || fail "$tool points at $target, which is not in the image"
    done

    # Under the Kubernetes backend the plugin, not the workflow, reaches into the
    # container: it holds it open with `sh -c "mkdir -p ... && sleep"` and moves files
    # with `tar cf -` and `tar xzf -`. Those four are resolved through PATH, so an
    # image that drops any of them fails every job on that label at once.
    for tool in sh mkdir tar gzip; do
      target=$(sed -n "s|^l.* \./bin/$tool -> ||p" "$listing" | head -1)
      [ -n "$target" ] || fail "$tool missing from /bin, needed by the k8s backend"
      grep -qxF "${target#/}" "$names" \
        || fail "$tool points at $target, which is not in the image"
    done

    echo "image contents ok"
