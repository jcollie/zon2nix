{
  description = "zig2nix flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    flake-utils,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = self.inputs.nixpkgs.outputs.legacyPackages.${system};

      zig_hook = pkgs.zig_0_13.hook.overrideAttrs {
        zig_default_flags = "-Dcpu=baseline -Doptimize=Debug --color off";
      };

      # Converts zon files to json
      zon2json = (pkgs.callPackage tools/zon2json/default.nix {inherit zig_hook;}) {};

      # Converts build.zig.zon to a build.zig.zon2json lock file
      zon2json-lock = pkgs.callPackage tools/zon2json-lock.nix {
        inherit zig_hook zon2json;
      };

      # Converts build.zig.zon and build.zig.zon2json-lock to nix deriviation
      zon2nix = pkgs.callPackage tools/zon2nix.nix {
        inherit zon2json-lock;
      };
      # Tools for bridging zig and nix
      # Package a Zig project
      # For the convenience flake outputs
    in {
      #! zon2json: Converts zon files to json
      packages.zon2json = zon2json;

      #! zon2json-lock: Converts build.zig.zon to a build.zig.zon2json lock file
      packages.zon2json-lock = zon2json-lock;

      #! zon2nix: Converts build.zig.zon and build.zig.zon2json-lock to nix deriviation
      packages.zon2nix = zon2nix;
    });
}
