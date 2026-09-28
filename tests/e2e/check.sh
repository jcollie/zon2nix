#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
#
# SPDX-License-Identifier: MIT

# Tests zon2nix from end to end against the manifest beside this script, and
# the Nix expression it writes against Nix and Zig themselves:
#
#   1. zon2nix writes the expression, which has to match expected.nix -- or,
#      for Zig 0.15, expected-0.15.nix -- and the JSON, which has to match
#      expected.json. The hashes do not depend on the platform, so a platform
#      that computes a different one fails here.
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

# The manifest names one dependency that cannot be fetched, which every run
# has to leave out, and reaches zigwin32, which is too large to be worth
# fetching here.
zon2nix=(zig-out/bin/zon2nix --exclude excluded --exclude zigwin32)

failed=0

# Checks the expression for one Zig version: $1 is the flag that asks for it,
# $2 the file it has to match.
check() {
  local flag="$1" expected="$2"

  echo "== generating with $flag"
  "${zon2nix[@]}" "$flag" --nix="$work/generated.nix" "$here/build.zig.zon"

  if ! diff -u "$expected" "$work/generated.nix"; then
    echo "the generated expression differs from $expected" >&2
    failed=1
    return
  fi

  echo "== building"
  cp "$work/generated.nix" "$work/default.nix"
  local farm
  farm="$(
    nix build --no-link --print-out-paths --impure --expr "
      let
        flake = builtins.getFlake (toString ./.);
        pkgs = flake.inputs.nixpkgs.legacyPackages.\${builtins.currentSystem};
      in
      pkgs.callPackage $work/default.nix {
        # Callers of older expressions override this; it has to be
        # accepted, and never used.
        linkFarm = throw \"linkFarm was used\";
      }
    "
  )"

  echo "== checking every package against zig fetch"
  rm -rf "$work/cache" "$work/src"
  mkdir -p "$work/cache/tmp" "$work/src"
  touch "$work/src/build.zig"
  local count=0 package name hash
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

  local expected_count
  expected_count="$(grep -cE '^    "[^"]+" = fetch[A-Za-z]+ \{' "$expected")"
  if [ "$count" -ne "$expected_count" ]; then
    echo "the result holds $count packages where $expected_count were expected" >&2
    failed=1
  fi
}

# The JSON is read by tools outside zon2nix, so it has to stay exactly as it
# was: expected.json was written by zon2nix 0.7.3.
echo "== generating JSON"
"${zon2nix[@]}" --json="$work/generated.json" "$here/build.zig.zon"
if ! diff -u "$here/expected.json" "$work/generated.json"; then
  echo "the generated JSON differs from $here/expected.json" >&2
  failed=1
fi

check --16 "$here/expected.nix"
check --15 "$here/expected-0.15.nix"

exit "$failed"
