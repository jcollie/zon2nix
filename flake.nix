# SPDX-FileCopyrightText: 2024 Jari Vetoniemi <jari.vetoniemi@cloudef.pw>
# SPDX-FileCopyrightText: 2025 Jeffrey C. Ollie <jeff@ocjtech.us>
#
# SPDX-License-Identifier: MIT

{
  description = "zon2nix";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz";
  };

  outputs =
    {
      nixpkgs,
      ...
    }:
    let
      platforms = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      makePackages =
        system:
        import nixpkgs {
          inherit system;
        };
      forAllSystems = (function: nixpkgs.lib.genAttrs platforms (system: function (makePackages system)));
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.nix-prefetch-git
            pkgs.nixfmt
            pkgs.reuse
            pkgs.zig_0_17
          ]
          # valgrind does not build on Darwin, and this flake offers an
          # aarch64-darwin devshell.
          ++ nixpkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
            pkgs.valgrind
          ];
        };
      });
      packages = forAllSystems (pkgs: {
        zon2nix = pkgs.callPackage ./package.nix {
          zig = pkgs.zig_0_17;
        };
      });
    };
}
