{
  lib,
  stdenvNoCC,
  zig_hook,
}: {...} @ attrs:
with builtins;
with lib;
  stdenvNoCC.mkDerivation (attrs
    // {
      name = "zon2json";
      src = cleanSource ./.;
      nativeBuildInputs = [zig_hook];
      meta.mainProgram = "zon2json";
    })
