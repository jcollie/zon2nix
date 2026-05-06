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
            pkgs.valgrind
            pkgs.zig_0_16
          ];
        };
      });
      packages = forAllSystems (pkgs: {
        zon2nix = pkgs.callPackage ./package.nix { };
      });
    };
}
