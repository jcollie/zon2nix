# SPDX-FileCopyrightText: 2024 Jari Vetoniemi <jari.vetoniemi@cloudef.pw>
# SPDX-FileCopyrightText: 2025 Jeffrey C. Ollie <jeff@ocjtech.us>
#
# SPDX-License-Identifier: MIT

{
  lib,
  stdenvNoCC,
  nix,
  nix-prefetch-git,
  nixfmt,
  zig_0_16,
}:
let
in
stdenvNoCC.mkDerivation (finalAttrs: {
  name = "zon2nix";
  src = lib.cleanSource ./.;
  nativeBuildInputs = [
    zig_0_16
  ];
  zigBuildFlags = [
    "-Dnix-prefetch-git=${lib.getExe nix-prefetch-git}"
    "-Dnix-prefetch-url=${lib.getExe' nix "nix-prefetch-url"}"
    "-Dnixfmt=${lib.getExe nixfmt}"
  ];
  meta = {
    mainProgram = "zon2nix";
    license = lib.licenses.mit;
  };
})
