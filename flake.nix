{
  description = "zig2nix flake";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable-small/nixexprs.tar.xz";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {
          inherit system;
        };
      in {
        devShells = {
          default = self.devShells.${system}.zig_0_15;
          zig_0_15 = pkgs.mkShell {
            packages = [
              pkgs.zig_0_15
              pkgs.nix-prefetch-git
              pkgs.nixfmt-rfc-style
              pkgs.valgrind
            ];
          };
        };
        packages = {
          #! zon2nix: Converts build.zig.zon to nix deriviation
          zon2nix = pkgs.callPackage ./package.nix {};
        };
      }
    );
}
