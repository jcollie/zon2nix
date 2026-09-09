<!--
SPDX-FileCopyrightText: 2024 Jari Vetoniemi <jari.vetoniemi@cloudef.pw>
SPDX-FileCopyrightText: 2025 Jeffrey C. Ollie <jeff@ocjtech.us>

SPDX-License-Identifier: MIT
-->

# zon2nix

Convert the dependencies in a Zig `build.zig.zon` file into a Nix expression,
so that Zig projects can be built with [Nix](https://nixos.org/) without
network access.

`zon2nix` reads one or more `build.zig.zon` files, recursively discovers all
transitive dependencies (including `.path`-based local dependencies), fetches
each one to compute the hashes that Nix needs, and writes the results in one or
more output formats.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

- https://ziglang.org/
- https://nixos.org/

## Requirements

- [Nix](https://nixos.org/) with flakes enabled (to run the packaged version).
- Network access while running `zon2nix` (dependencies are downloaded in order
  to compute their hashes).

If you build `zon2nix` yourself instead of using the flake, the following
tools must be available at runtime: `nix-prefetch-git`, `nix-prefetch-url`,
and `nixfmt`. The Nix package wires in absolute paths to these automatically;
a hand-built binary looks for them in `PATH` (or at the paths given by the
`-Dnix-prefetch-git=`, `-Dnix-prefetch-url=`, and `-Dnixfmt=` build options).

## Usage

Run it from the flake in the directory containing your `build.zig.zon`:

```bash
nix run github:jcollie/zon2nix#zon2nix -- --nix=build.zig.zon.nix build.zig.zon
```

The general form is:

```
zon2nix [options] [path ...]
```

Each `path` is a `build.zig.zon` file to process. If no paths are given,
`zon2nix` looks for `build.zig.zon` in the current directory. Transitive
dependencies are followed automatically, so you only need to point it at your
top-level file(s).

### Output options

At least one output option is normally given; each writes a different format,
and they can be combined in a single run. Options take a value either as
`--nix=FILE` or `--nix FILE`.

| Option | Output |
| --- | --- |
| `--nix=FILE` | A Nix expression (formatted with `nixfmt`) that fetches every dependency — see below. |
| `--json=FILE` | A JSON object mapping each Zig package hash to its name, URL, and Nix hash. |
| `--txt=FILE` | A plain list of dependency URLs, one per line. |
| `--flatpak=FILE` | A JSON sources array for use in a [flatpak-builder](https://docs.flatpak.org/en/latest/flatpak-builder.html) manifest, with each dependency placed under `vendor/p/<hash>`. |

With only `--txt`, no hashes are computed, so the run is much faster.

### Zig version selection

The generated Nix expression uses Zig itself to unpack fetched artifacts, so
it must reference the matching Zig package from nixpkgs:

- `--15` — generated expression uses `zig_0_15`
- `--16` — generated expression uses `zig_0_16` (default)

It also decides where the generated packages have to be put at build time,
which the two versions do differently — see below.

### Fetching

Packages are fetched several at a time. Each one costs a download, a `zig
fetch` and a `nix-prefetch-*` run, nearly all of which is waiting, so this is
most of the wall-clock time of a run: eight dependencies that take 12 seconds
one after another take 4 fetched eight at a time.

- `--jobs=N` — fetch N packages at once (default 8)

Manifests are read one at a time, a level of the dependency graph at a time, so
what comes out does not depend on `N` — only how long it takes to produce.
Raising it much past the default tends not to help, since by then the work is
waiting on whoever is serving the packages rather than on zon2nix.

### Logging options

- `--quiet` — decrease verbosity (may be repeated)
- `--verbose` — increase verbosity (may be repeated)
- `--debug` — maximum verbosity

## Using the generated Nix expression

The file written by `--nix` is a function suitable for `callPackage`. It
evaluates to a directory holding one subdirectory per dependency, named by Zig
package hash — the layout Zig expects of its unpacked packages.

Where those packages have to be put depends on the Zig version, because 0.16
moved them: 0.15 keeps unpacked packages in `p/` under the global cache, while
0.16 keeps only the fetched tarballs there and unpacks into a `zig-pkg`
directory beside the sources being built.

### Zig 0.16

Hand the packages over with `--system`:

```nix
{
  stdenvNoCC,
  callPackage,
  zig_0_16,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "my-zig-project";
  version = "0.1.0";
  src = ./.;

  nativeBuildInputs = [ zig_0_16 ];

  zigBuildFlags = [
    "--system"
    "${callPackage ./build.zig.zon.nix { }}"
  ];
  # The check phase assembles its own flags rather than reusing the build's,
  # so without this a package with `doCheck = true` runs `zig build test`
  # without `--system`, tries to fetch, and fails in the sandbox.
  zigCheckFlags = finalAttrs.zigBuildFlags;
})
```

`--system` does more than point Zig at the packages: it forbids fetching
outright, so a package missing from the farm is an error naming it rather than
a silent attempt to reach the network, and it turns on every
`systemIntegrationOption` by default, which is usually what a distribution
build wants. Neither of those comes with the alternatives below.

#### Dependencies that have `.path` dependencies of their own

On Zig 0.16.0, `zig build --system` never finishes if any fetched package
declares a `.path` dependency — the kind a large project uses to vendor its
own subpackages, as ghostty does with `.freetype = .{ .path =
"./pkg/freetype" }`. It does not fail: the main thread spins in userspace at a
hundred per cent of one core, indefinitely, having stopped reading files
altogether and with every worker thread idle. It is past the fetch — which on
its own, with `zig build --fetch --system`, completes in milliseconds — and has
not yet begun to compile anything. One such dependency anywhere in the graph is
enough, lazy or not, and no arrangement of the farm avoids it: the same hang
follows the packages into the build directory, and into the global cache.

The cause is inside Zig rather than in anything the farm does. A `.path`
dependency's identity is hashed together with a flag saying whether its
package root lies inside the cache root, and `--system` makes those two
questions disagree: the fetch computes the hash against the farm, which *is*
the cache root in this mode, and the later pass that wires up each package's
`build.zig` module computes it against the real global cache, which is not.
The second lookup therefore misses, and the release compiler has no safety
check there to say so.

This appears to be fixed in Zig after 0.16.0: the restructuring that moved
`zig build` out of the compiler and into `lib/compiler/Maker.zig` gave the
system package directory a field of its own instead of aliasing it onto the
global cache, so both passes now hash against the same directory. Worth
re-testing when 0.17 arrives — if it is fixed there, the forking below becomes
dead weight for anyone building with it.

Forking the offending package past the farm gets `--system` working again,
because a forked package is rooted outside the farm and both hashes then agree.
The fork has to live inside the build root, and be given as a relative path.

`zon2nix` reads every fetched manifest, so it knows which packages these are and
names them: the generated expression carries the list as
`pathDependencyPackages`, and a package can write both the copies and the flags
out of it rather than pasting hashes by hand.

```nix
let
  zigDeps = callPackage ./build.zig.zon.nix { };
in
stdenv.mkDerivation (finalAttrs: {
  # ...

  postPatch = lib.concatMapStrings (p: ''
    cp -rsL --no-preserve=mode ${zigDeps}/${p} fork-${p}
  '') zigDeps.pathDependencyPackages;

  zigBuildFlags = [
    "--system"
    "${zigDeps}"
  ] ++ map (p: "--fork=fork-${p}") zigDeps.pathDependencyPackages;
  zigCheckFlags = finalAttrs.zigBuildFlags;
})
```

On a graph with nothing to fork the list is empty, both the `postPatch` and the
extra flags vanish, and what is left is the plain `--system` build above — so
this is safe to write once and leave in place.

Zig reports `fork <path> matched 1 <name> packages`, and fails the build if a
fork matches nothing, so a package that stops needing one does not pass
unnoticed. Note that a fork replaces the package without checking its hash;
here the contents come from the same store path either way.

#### Or give up `--system`

The other way is to put the packages where Zig looks for them itself and not
pass the flag at all. Zig 0.16 unpacks into a `zig-pkg` directory beside the
sources, so:

```nix
  postPatch = ''
    cp -rsL --no-preserve=mode ${callPackage ./build.zig.zon.nix { }} zig-pkg
  '';
```

This avoids the bug entirely, at the price of what `--system` was providing:
fetching is no longer forbidden, so a missing package is a failed download
rather than a clear error, and every `systemIntegrationOption` goes back to
defaulting off.

`cp -rs` in both recipes makes real directories holding symlinks to the files,
which costs nothing and is what Zig needs: a dependency's own build steps reach
the cache by a path relative to their package directory, so a package directory
that is itself a symlink into the store resolves `../../.zig-cache` to
somewhere near the root of the filesystem, and the build fails to spawn a
generator it has just finished building.

### Zig 0.15

Link the packages into Zig's global cache before building:

```nix
postPatch = ''
  ln -s ${callPackage ./build.zig.zon.nix { }} "$ZIG_GLOBAL_CACHE_DIR/p"
'';
```

or hand them over with `zig build --system <dir>`:

```nix
zigBuildFlags = [
  "--system"
  "${callPackage ./build.zig.zon.nix { }}"
];
```

Note that `stdenv`'s check phase assembles its own flags rather than reusing
the build's, so a package with `doCheck = true` wants
`zigCheckFlags = finalAttrs.zigBuildFlags;` as well, or `zig build test` runs
without `--system`, tries to fetch, and fails in the sandbox.

Whenever you add, remove, or update a dependency in `build.zig.zon`, re-run
`zon2nix` to regenerate the file and commit the result.

## Cloning with Radicle

The repository is published on [Radicle](https://radicle.xyz/), a peer-to-peer
code forge. To clone it:

```bash
rad clone rad:z4QfQ4qG1WzhFeo7ktFHc3VhZ1KuY
```

If you don't have Radicle set up yet, install the `rad` CLI and create an
identity first:

```bash
curl -sSf https://radicle.xyz/install | sh
rad auth
```

Cloning also seeds the repository, helping keep it available on the network.
The repository is additionally mirrored at
[github.com/jcollie/zon2nix](https://github.com/jcollie/zon2nix) and
[codeberg.org/jcollie/zon2nix](https://codeberg.org/jcollie/zon2nix).

## Development

A development shell with Zig, `nix-prefetch-git`, `nixfmt`, and `valgrind` is
provided:

```bash
nix develop
```

Common tasks:

```bash
zig build run -- --nix=build.zig.zon.nix   # build and run
zig build test                             # run the unit tests
zig build test-valgrind                    # run the tests under valgrind
```

## License

[MIT](LICENSE)
