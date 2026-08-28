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

- `--15` — generated expression uses `zig_0_15` (default)
- `--16` — generated expression uses `zig_0_16`

### Logging options

- `--quiet` — decrease verbosity (may be repeated)
- `--verbose` — increase verbosity (may be repeated)
- `--debug` — maximum verbosity

## Using the generated Nix expression

The file written by `--nix` is a function suitable for `callPackage`. It
evaluates to a [`linkFarm`](https://nixos.org/manual/nixpkgs/stable/#trivial-builder-linkFarm)
whose entries are named by Zig package hash — exactly the layout of the `p/`
directory in Zig's global cache, and what `zig build --system <dir>` expects.

A typical package:

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
})
```

Alternatively, link the packages into Zig's global cache before building:

```nix
postPatch = ''
  ln -s ${callPackage ./build.zig.zon.nix { }} "$ZIG_GLOBAL_CACHE_DIR/p"
'';
```

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
