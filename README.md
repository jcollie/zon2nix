# zon2nix flake

Flake for converting Zig build.zig.zon to nix derivations.

https://ziglang.org/
https://nixos.org/

---

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)


### Convert zon file to a nix derivation

```bash
nix run github:jcollie/zon2nix#zon2nix -- --nix=build.zig.zon.nix build.zig.zon
```
