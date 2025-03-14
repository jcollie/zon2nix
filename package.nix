{
  lib,
  stdenvNoCC,
  makeWrapper,
  nix-prefetch-git,
  zig_0_14,
}: let
  zig_hook = zig_0_14.hook.overrideAttrs {
    zig_default_flags = "-Dcpu=baseline -Doptimize=Debug --color off";
  };
in
  stdenvNoCC.mkDerivation (
    finalAttrs: {
      name = "zon2nix";
      src = lib.cleanSource ./.;
      nativeBuildInputs = [
        zig_hook
        makeWrapper
      ];
      zigBuildFlags = [
        "-Dzig=${lib.getExe zig_0_14}"
        "-Dnix-prefetch-git=${lib.getExe nix-prefetch-git}"
      ];
      meta = {
        mainProgram = "zon2nix";
        license = lib.licenses.mit;
      };
    }
  )
