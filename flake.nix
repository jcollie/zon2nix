# SPDX-FileCopyrightText: 2024 Jari Vetoniemi <jari.vetoniemi@cloudef.pw>
# SPDX-FileCopyrightText: 2025 Jeffrey C. Ollie <jeff@ocjtech.us>
#
# SPDX-License-Identifier: MIT

{
  description = "zon2nix";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz";
    # nixpkgs has no Zig 0.17 yet, so the compiler comes from the overlay's
    # nightlies until there is a release to move to.
    zig = {
      url = "git+https://git.jcollie.dev/jeff/zig-overlay.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      zig,
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
            zig.packages.${pkgs.stdenv.hostPlatform.system}.master
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
          zig = zig.packages.${pkgs.stdenv.hostPlatform.system}.master;
        };
      });
    };
}
