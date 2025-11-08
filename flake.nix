{
  description = "zig2nix";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz";
  };

  outputs =
    {
      self,
      nixpkgs,
      ...
    }:
    let
      makePackages =
        system:
        import nixpkgs {
          inherit system;
        };
      forAllSystems = (
        function:
        nixpkgs.lib.genAttrs [
          "aarch64-linux"
          "aarch64-darwin"
          "x86_64-linux"
          "x86_64-darwin"
        ] (system: function (makePackages system))
      );
    in
    {
      devShells = forAllSystems (pkgs: {
        default = self.devShells.${pkgs.system}.zig_0_15;
        zig_0_15 = pkgs.mkShell {
          packages = [
            pkgs.zig_0_15
            pkgs.nix-prefetch-git
            pkgs.nixfmt-rfc-style
            pkgs.valgrind
          ];
        };
      });
      packages = forAllSystems (pkgs: {
        zon2nix = pkgs.callPackage ./package.nix { };
      });
    };
}
