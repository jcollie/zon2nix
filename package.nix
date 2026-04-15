{
  lib,
  stdenvNoCC,
  nix-prefetch-git,
  nixfmt,
  zig,
}:
let
in
stdenvNoCC.mkDerivation (finalAttrs: {
  name = "zon2nix";
  src = lib.cleanSource ./.;
  nativeBuildInputs = [
    zig
  ];
  zigBuildFlags = [
    "-Dnix-prefetch-git=${lib.getExe nix-prefetch-git}"
    "-Dnixfmt=${lib.getExe nixfmt}"
  ];
  meta = {
    mainProgram = "zon2nix";
    license = lib.licenses.mit;
  };
})
