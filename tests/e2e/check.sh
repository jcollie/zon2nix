#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
#
# SPDX-License-Identifier: MIT

# Tests zon2nix from end to end against the manifest beside this script, and
# the Nix expression it writes against Nix and Zig themselves:
#
#   1. zon2nix writes the expression, which has to match expected.nix -- or,
#      for Zig 0.15 and 0.17, expected-0.15.nix and expected-0.17.nix -- and
#      the JSON, which has to match expected.json. The hashes do not depend
#      on the platform, so a platform that computes a different one fails
#      here.
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
# $2 the file it has to match, and $3 any arguments the expression has to be
# given, as a Nix attribute set.
check() {
  local flag="$1" expected="$2" args="{ }"
  if [ $# -ge 3 ]; then args="$3"; fi

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
        system = builtins.currentSystem;
        pkgs = flake.inputs.nixpkgs.legacyPackages.\${system};
      in
      pkgs.callPackage $work/default.nix ({
        # Callers of older expressions override this; it has to be
        # accepted, and never used.
        linkFarm = throw \"linkFarm was used\";
      } // $args)
    "
  )"

  echo "== checking every package against zig fetch"
  # Only the packages are cleared out: Zig 0.17 compiles the runner for `zig
  # fetch` into this cache, which takes a minute or more, and need not do it
  # again for every version.
  rm -rf "$work/cache/p" "$work/src"
  mkdir -p "$work/cache/tmp" "$work/src"
  touch "$work/src/build.zig"
  local count=0 package name hash
  for package in "$farm"/*; do
    name="$(basename "$package")"
    # Zig 0.17's `zig fetch` has no `--global-cache-dir`.
    hash="$(cd "$work/src" && ZIG_GLOBAL_CACHE_DIR="$work/cache" zig fetch "$package")"
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
# nixpkgs has no Zig 0.17, so it comes from the overlay this flake builds with.
check --17 "$here/expected-0.17.nix" "{ zig_0_17 = flake.inputs.zig.packages.\${system}.master; }"

exit "$failed"
