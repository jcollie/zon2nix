# zig2nix flake

Flake for converting Zig build.zig.zon to nix derivations.

https://ziglang.org/
https://nixos.org/

---

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)


### Convert zon file to json

```bash
nix run github:jcollie/zig2nix#zon2json -- build.zig.zon
```

### Convert build.zig.zon to a build.zig.zon2json-lock

```bash
nix run github:jcollie/zig2nix#zon2json-lock -- build.zig.zon
# alternatively output to stdout
nix run github:jcollie/zig2nix#zon2json-lock -- build.zig.zon -
```

### Convert build.zig.zon/2json-lock to a nix derivation

```bash
# calls zon2json-lock if build.zig.zon2json-lock does not exist (requires network access)
nix run github:jcollie/zig2nix#zon2nix -- build.zig.zon
# alternatively run against the lock file (no network access required)
nix run github:jcollie/zig2nix#zon2nix -- build.zig.zon2json-lock
```
