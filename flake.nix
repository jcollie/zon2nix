{
  description = "zon2nix";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz";
    zig = {
      url = "git+https://codeberg.org/jcollie/zig-overlay.git";
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
      lib = nixpkgs.lib;
      platforms = lib.attrNames zig.packages;
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
            pkgs.valgrind
            zig.packages.${pkgs.stdenv.hostPlatform.system}.master
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
