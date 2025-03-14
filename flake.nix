{
  description = "zig2nix flake";

  inputs = {
    nixpkgs.url = "nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
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
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.zig_0_14
            pkgs.nix-prefetch-git
            pkgs.nixfmt-rfc-style
          ];
        };
        packages = {
          #! zon2nix: Converts build.zig.zon and build.zig.zon2json-lock to nix deriviation
          zon2nix = pkgs.callPackage ./package.nix {};
        };
      }
    );
}
