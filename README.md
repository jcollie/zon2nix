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

`zon2nix --help` lists the options.

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

The `hash` in the JSON is in Nix's SRI form. For a naked package, one whose
hash begins `N-V-` because it has no manifest of its own, it is the SHA-256 of
the archive file as downloaded; for any other archive it is the Nix hash of
the unpacked contents, stripped of their top-level directory, and for a git
repository the Nix hash of an ordinary checkout, `.gitattributes` applied —
which the Nix expression's own git hash, taken without them, can differ from. Tools outside zon2nix build
distribution packages from this file, so that meaning does not change, even
though the Nix expression now fetches most naked packages unpacked and so
gives some of them a different hash from the JSON.

Every one of these names the file to **write**, which is worth saying because
the `--txt FILE` form reads so naturally as the file to *read*: `zon2nix --txt
build.zig.zon` is a request to replace the manifest with a list of URLs, not to
list the URLs in it. zon2nix refuses an output that is named `build.zig.zon`,
or that resolves to a manifest it is about to read, rather than doing what it
was asked.

### Zig version selection

The generated Nix expression uses Zig itself to unpack fetched artifacts, so
it must reference the matching Zig package:

- `--15` — generated expression uses `zig_0_15`
- `--16` — generated expression uses `zig_0_16` (default)
- `--17` — generated expression uses `zig_0_17`, which nixpkgs does not have
  yet, so the caller has to pass one in — see below

It also decides where the generated packages have to be put at build time,
which the versions do differently — see below.

### Fetching

Every package is checked against the hash its manifest names before anything
is written, so a URL and hash that do not belong together fail the run rather
than the eventual Nix build. For an archive — a `.tar.gz`, `.tar.xz`,
`.tar.zst`, `.tar` or `.zip` — zon2nix unpacks it and computes Zig's package
hash itself, following the same rules as `zig fetch` in Zig 0.16.0: the same
unpacking, the manifest's `.paths` deciding which files count, and the same
digest over them. It does not run `zig fetch` for these, because `zig fetch`
also recompresses every package into its cache at gzip level 9, which is
nearly all of its time — eight seconds of one core for gettext's 27 MB tarball,
against under half a second to unpack and hash it. A `git+https` dependency
still goes through `zig fetch`, using whichever Zig is on the `PATH`; Zig 0.17
leaves such a package only as a tarball in its cache, which zon2nix then
unpacks and hashes the same way as any other archive.

An archive's URL has to end in its extension — `.tar.gz` or `.tgz`, `.tar.xz`
or `.txz`, `.tar.zst` or `.tzst`, `.tar`, or `.zip` or `.jar`. Zig itself can
also go by the `Content-Type` a server sends, but the Nix expression zon2nix
writes decides how to unpack a package by its name, so zon2nix refuses a URL
without one rather than writing an expression that cannot build. A GitHub
`codeload.github.com/…/tar.gz/<commit>` URL is the usual case; the
`github.com/…/archive/<commit>.tar.gz` form of it works.

Packages are fetched several at a time. Each one costs a download, the check
above and a `nix-prefetch-*` run, most of which is waiting, so this is most of
the wall-clock time of a run: eight dependencies that take 12 seconds one after
another take 4 fetched eight at a time.

- `--jobs=N` — fetch N packages at once (default 8)

A package's own dependencies are started as soon as it has been fetched,
rather than when everything found alongside it has been, so one slow package
holds up only what is below it. Raising `N` much past the default tends not to
help, since by then the work is waiting on whoever is serving the packages
rather than on zon2nix.

What comes out does not depend on `N`, or on which package happened to finish
first. That matters when one package is reached more than one way — two
manifests naming the same package hash by different names, or with different
URLs, which zon2nix warns about. The name written out is then the
alphabetically first, and the URL is an archive in preference to a `git+`
URL, since Nix fetches an archive far more cheaply than it clones a repository,
and otherwise the alphabetically first. The Nix hash belongs to the URL that
was fetched, so a package fetched before a better URL for it turned up is
fetched again from that one.

### Excluding packages

- `--exclude=NAME` — leave out a dependency, and everything beneath it (may
  be repeated)

zon2nix follows every dependency, lazy ones included, since it cannot know
which a build will ask for. That sometimes reaches a package that cannot be
fetched at all — one whose own manifest uses a hash format the current Zig
refuses, say — beneath a lazy dependency the project never uses. `--exclude`
names such a dependency: it is neither fetched nor looked inside, so nothing
beneath it is either.

`NAME` matches the name a manifest gives a dependency, in any manifest, or its
package hash. An `--exclude` that matches nothing draws a warning, since it is
most likely misspelled. If an excluded package turns out to be needed after
all, `zig build --system` fails naming it, so leaving out too much is not
silent.

### Logging options

- `--quiet` — decrease verbosity (may be repeated)
- `--verbose` — increase verbosity (may be repeated)
- `--debug` — maximum verbosity

## Using the generated Nix expression

The file written by `--nix` is a function suitable for `callPackage`. It
evaluates to a directory holding one subdirectory per dependency, named by Zig
package hash — the layout Zig expects of its unpacked packages.

Each package is fetched by the ordinary nixpkgs fetcher for it: `fetchgit` for
a git repository, `fetchzip` for an archive with a single top-level directory,
and `fetchurl` for one without, which `fetchzip` cannot strip. A git repository
goes through `fetchZigGit`, a `fetchgit` that checks out every file as
committed, ignoring the repository's `.gitattributes`: an ordinary checkout
can rewrite a file's line endings, and Zig reads the files as committed, so
the package would no longer match its hash. `fetchzip` is
preferred because Nix then hashes the contents rather than the archive, so a
server regenerating the archive — as GitHub has — does not break the hash. One
derivation then runs `zig fetch` on every package, several at a time, which
filters each by its manifest's `.paths`, checks it against its hash, and puts
it in place as real files; Zig mishandles a package directory that is a
symlink.

Expressions from zon2nix before 0.8 built the directory with `linkFarm`, and a
project that worked around the symlinks by passing its own copying `linkFarm`
to `callPackage` can drop it: the argument is still accepted, so that passing
it is not an error, but nothing uses it.

Where those packages have to be put depends on the Zig version, because 0.16
moved them: 0.15 keeps unpacked packages in `p/` under the global cache, while
0.16 and 0.17 keep only the fetched tarballs there and unpack into a `zig-pkg`
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

The second is also a way for a build that worked with fetched packages to
fail: every integration a dependency offers is switched on, so it looks for a
system library the derivation does not provide — dvui's `freetype`
integration looking for the system's `freetype2`, for instance. Turn such an
integration back off with `-fno-sys=NAME` in `zigBuildFlags`; `zig build
--help` lists the names under "Available System Integrations". Pipit, which
builds on dvui, passes:

```nix
  zigBuildFlags = [
    "--system"
    "${callPackage ./build.zig.zon.nix { }}"
    "-fno-sys=accesskit"
    "-fno-sys=freetype"
    "-fno-sys=wio"
  ];
```

Or give the derivation the library, and leave the integration on.

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
global cache, so both passes now hash against the same directory. It has not
yet been re-tested against the 0.17.0 release — if it is fixed there, the
forking below is dead weight for anyone building with it.

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

### Zig 0.17

Zig 0.17 takes the packages exactly as 0.16 does, so everything in the
section above applies — `--system`, `-fno-sys`, the forking of packages with
`.path` dependencies, and the `zig-pkg` alternative — with `zig_0_17` in
place of `zig_0_16`.

The difference is that nixpkgs has no `zig_0_17` yet, so `callPackage` cannot
supply the one the expression asks for, and the caller passes it in. From
[zig-overlay](https://git.jcollie.dev/jeff/zig-overlay), which packages each
Zig release:

```nix
let
  zigDeps = callPackage ./build.zig.zon.nix {
    zig_0_17 = zig-overlay.packages.${stdenv.hostPlatform.system}."0.17.0";
  };
in
stdenv.mkDerivation (finalAttrs: {
  # ...
  nativeBuildInputs = [ zig-overlay.packages.${stdenv.hostPlatform.system}."0.17.0" ];

  zigBuildFlags = [
    "--system"
    "${zigDeps}"
  ];
  zigCheckFlags = finalAttrs.zigBuildFlags;
})
```

Zig 0.17 runs `zig fetch` in a build runner it compiles the first time it is
asked, which takes a minute or more of one core, so building the expression
costs that much more than it does for 0.16. It is paid once per build of the
expression, not once per package.

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
provided. Its Zig is the 0.17.0 release from
[zig-overlay](https://git.jcollie.dev/jeff/zig-overlay), and the package is
built with the same one:

```bash
nix develop
```

Common tasks:

```bash
zig build run -- --nix=build.zig.zon.nix   # build and run
zig build test                             # run the unit tests
zig build test-valgrind                    # run the tests under valgrind
tests/e2e/check.sh                         # test from end to end (needs the network)
```

`tests/e2e/check.sh` runs zon2nix on `tests/e2e/build.zig.zon`, whose
dependencies cover an archive in every format, a package without a manifest, a
git repository and a `.path` dependency. The expression it writes has to match
`tests/e2e/expected.nix` (or `expected-0.15.nix` or `expected-0.17.nix`, for
those versions), has to build, and every package in the result has to
hash to its own name by `zig fetch`. After changing what zon2nix writes,
regenerate the expected file and review the difference:

```bash
zig build
zig-out/bin/zon2nix --exclude excluded --16 --nix=tests/e2e/expected.nix tests/e2e/build.zig.zon
zig-out/bin/zon2nix --exclude excluded --15 --nix=tests/e2e/expected-0.15.nix tests/e2e/build.zig.zon
zig-out/bin/zon2nix --exclude excluded --17 --nix=tests/e2e/expected-0.17.nix tests/e2e/build.zig.zon
```

All of this, and the build of the package, runs in
[GitHub Actions](.github/workflows/test.yml) on x86_64 and aarch64 Linux and on
aarch64 macOS, and in [Forgejo Actions](.forgejo/workflows/test.yml) on x86_64
Linux, which is all the Forgejo runners are.

## References cited

- Zig Software Foundation. *Zig 0.16.0: src/Package/Fetch.zig* (2026).
  <https://codeberg.org/ziglang/zig/src/tag/0.16.0/src/Package/Fetch.zig> —
  how `zig fetch` unpacks an archive, applies a manifest's `.paths`, computes
  the package hash, and recompresses the package into its cache. zon2nix's
  archive hashing is a port of it.
- Zig Software Foundation. *Zig 0.16.0: src/Package.zig* (2026).
  <https://codeberg.org/ziglang/zig/src/tag/0.16.0/src/Package.zig> — the
  format of a Zig package hash.
- Zig Software Foundation. *Zig 0.17.0: lib/compiler/Maker.zig* (2026).
  <https://codeberg.org/ziglang/zig/src/tag/0.17.0/lib/compiler/Maker.zig>
  — `zig fetch` in 0.17: no `--global-cache-dir`, and nothing unpacked
  outside the global cache's tarball unless `--save` is given; and
  `zig build --system`, which still takes a directory of unpacked packages
  named by hash.
- Zig Software Foundation. *Zig 0.17.0: lib/std/zon/parse.zig* (2026).
  <https://codeberg.org/ziglang/zig/src/tag/0.17.0/lib/std/zon/parse.zig> —
  `fromZoir`, whose `node` option is never passed on, so it always parses from
  the root; which is why zon2nix reads each dependency's fields itself.

## License

[MIT](LICENSE)
