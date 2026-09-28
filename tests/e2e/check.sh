#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
#
# SPDX-License-Identifier: MIT

# Tests zon2nix from end to end against the manifest beside this script, and
# the Nix expression it writes against Nix and Zig themselves:
#
#   1. zon2nix writes the expression, which has to match expected.nix. The
#      hashes in it do not depend on the platform, so a platform that computes
#      a different one fails here.
#   2. Nix builds it, which fetches and unpacks every package the way a real
#      build would.
#   3. Every package in the result is hashed by `zig fetch`, and has to come
#      out as the name it is filed under -- which is what `zig build --system`
#      relies on.
#
# Run it from the root of the repository, inside the devshell:
#
#   nix develop -c tests/e2e/check.sh
#
# It needs the network, since fetching is the whole point.

set -euo pipefail

here=tests/e2e
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

zig build -Doptimize=ReleaseSafe

echo "== generating"
zig-out/bin/zon2nix --nix="$work/generated.nix" "$here/build.zig.zon"

if ! diff -u "$here/expected.nix" "$work/generated.nix"; then
  echo "the generated expression differs from $here/expected.nix" >&2
  exit 1
fi

echo "== building"
cp "$work/generated.nix" "$work/default.nix"
farm="$(
  nix build --no-link --print-out-paths --impure --expr "
    let
      flake = builtins.getFlake (toString ./.);
      pkgs = flake.inputs.nixpkgs.legacyPackages.\${builtins.currentSystem};
    in
    pkgs.callPackage $work/default.nix { }
  "
)"

echo "== checking every package against zig fetch"
mkdir -p "$work/cache/tmp" "$work/src"
touch "$work/src/build.zig"
failed=0
count=0
for package in "$farm"/*; do
  name="$(basename "$package")"
  hash="$(cd "$work/src" && zig fetch --global-cache-dir "$work/cache" "$package")"
  count=$((count + 1))
  if [ "$hash" = "$name" ]; then
    echo "ok       $name"
  else
    echo "MISMATCH $name hashes to $hash" >&2
    failed=1
  fi
done

expected_count="$(grep -c 'path = fetchZigArtifact' "$here/expected.nix")"
if [ "$count" -ne "$expected_count" ]; then
  echo "the result holds $count packages where $expected_count were expected" >&2
  failed=1
fi

exit "$failed"
