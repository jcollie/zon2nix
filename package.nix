{
  lib,
  stdenvNoCC,
  makeWrapper,
  nix-prefetch-git,
  nixfmt-rfc-style,
  zig_0_15,
}:
let
  zig_hook = zig_0_15.hook.overrideAttrs {
    zig_default_flags = "-Dcpu=baseline -Doptimize=Debug --color off";
  };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  name = "zon2nix";
  src = lib.cleanSource ./.;
  nativeBuildInputs = [
    zig_hook
    makeWrapper
  ];
  depsHostHostPropagated = [
    zig_0_15
    nix-prefetch-git
    nixfmt-rfc-style
  ];
  zigBuildFlags = [
    "-Dzig=${lib.getExe zig_0_15}"
    "-Dnix-prefetch-git=${nix-prefetch-git}/bin/nix-prefetch-git"
    "-Dnixfmt=${lib.getExe nixfmt-rfc-style}"
  ];
  meta = {
    mainProgram = "zon2nix";
    license = lib.licenses.mit;
  };
})
