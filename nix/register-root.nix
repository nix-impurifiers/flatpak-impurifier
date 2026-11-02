# SPDX-License-Identifier: MIT
{ pkgs }:
pkgs.stdenv.mkDerivation {
  pname = "impurifier-register-root";
  version = "1";
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.pkg-config ];
  buildInputs = [
    pkgs.nix.libs.nix-store
    pkgs.nix.libs.nix-main
  ];
  buildPhase = ''
    $CXX ${../src/register-root.cc} $(pkg-config --cflags --libs nix-main nix-store) -o impurifier-register-root
  '';
  installPhase = ''
    mkdir -p $out/bin $out/share/licenses/impurifier-register-root
    cp impurifier-register-root $out/bin/
    cp ${../LICENSE} $out/share/licenses/impurifier-register-root/LICENSE
  '';
}
