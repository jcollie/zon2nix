# SPDX-FileCopyrightText: 2024 Jari Vetoniemi <jari.vetoniemi@cloudef.pw>
# SPDX-FileCopyrightText: 2025 Jeffrey C. Ollie <jeff@ocjtech.us>
#
# SPDX-License-Identifier: MIT

{
  description = "zon2nix";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz";
    # nixpkgs has no Zig 0.17 yet, so the compiler comes from the overlay.
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
      # The 0.17.0 release. The overlay lists it among the nightlies, under
      # the date it was published, rather than as a `0.17.0` of its own, and
      # `master` moves on to the 0.18 nightlies the next time it is updated.
      zigFor = pkgs: zig.packages.${pkgs.stdenv.hostPlatform.system}."master-2026-10-01";
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.nix-prefetch-git
            pkgs.nixfmt
            pkgs.reuse
            (zigFor pkgs)
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
          zig = zigFor pkgs;
        };
      });
    };
}
