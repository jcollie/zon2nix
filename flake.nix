{
  description = "zig2nix flake";

  inputs = {
    nixpkgs.url = "nixpkgs/nixpkgs-unstable";
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
        zig_hook = pkgs.zig_0_14.hook.overrideAttrs {
          zig_default_flags = "-Dcpu=baseline -Doptimize=Debug --color off";
        };
      in {
        packages = {
          #! zon2json: Converts zon files to json
          zon2json = pkgs.callPackage tools/zon2json/default.nix {
            inherit zig_hook;
          };

          #! zon2json-lock: Converts build.zig.zon to a build.zig.zon2json lock file
          zon2json-lock = pkgs.callPackage tools/zon2json-lock.nix {
            inherit zig_hook;
            inherit (self.packages.${system}) zon2json;
          };

          #! zon2nix: Converts build.zig.zon and build.zig.zon2json-lock to nix deriviation
          zon2nix = pkgs.callPackage tools/zon2nix.nix {
            inherit (self.packages.${system}) zon2json-lock;
          };
        };
      }
    );
}
