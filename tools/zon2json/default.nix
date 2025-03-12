{
  lib,
  stdenvNoCC,
  zig_hook,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  name = "zon2json";
  src = lib.cleanSource ./.;
  nativeBuildInputs = [zig_hook];
  meta.mainProgram = "zon2json";
})
