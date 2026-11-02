# SPDX-License-Identifier: MIT
{
  pkgs,
  coreSrc,
  sourceInfo ? { },
}:
let
  inherit (pkgs) lib;
  registerRoot = import ./register-root.nix { inherit pkgs; };
  tools = {
    package = pkgs.flatpak;
    inherit registerRoot;
  };
  core = import (coreSrc + "/nix") {
    inherit pkgs;
    namespace = "flatpak-impurifier";
  };
  sdk = pkgs.linkFarm "flatpak-impurifier-sdk" [
    {
      name = "python";
      path = pkgs.python3;
    }
    {
      name = "nix";
      path = pkgs.nix;
    }
    {
      name = "register-root";
      path = registerRoot;
    }
  ];
  runtimeId = "io.github.nix_impurifiers.Platform";
  branch = builtins.substring 0 20 (builtins.hashString "sha256" (toString sdk));
  runtimeRef = "${runtimeId}/x86_64/${branch}";
  runtime = pkgs.runCommand "flatpak-impurifier-platform" { } ''
    mkdir -p $out/usr/bin $out/files
    cp ${pkgs.pkgsStatic.busybox}/bin/busybox $out/usr/bin/busybox
    for command in sh env cat; do ln -s busybox $out/usr/bin/$command; done
    ln -s ${sdk} $out/usr/nix-root
    cp -r ${core.offlineCache sdk} $out/usr/cache
    cat > $out/metadata <<'META'
    [Runtime]
    name=${runtimeId}
    runtime=${runtimeRef}
    sdk=${runtimeRef}
    META
  '';
  package = pkgs.writeShellApplication {
    name = "flatpak-impurifier";
    runtimeInputs = [
      pkgs.flatpak
      pkgs.python3
      pkgs.nix
      registerRoot
    ];
    text = ''
      case "''${1:-}" in
        prune) shift; exec python3 ${../src/prune.py} "$@" ;;
        prepare) shift; exec python3 ${../src/prepare.py} "$@" ;;
        *) echo 'usage: flatpak-impurifier prepare [--owner USER] APPLICATION' >&2; exit 2 ;;
      esac
    '';
  };
  makeApplication =
    {
      pkg,
      id,
      program ? pkg.meta.mainProgram or pkg.pname,
      offline ? false,
      permissions ? [ ],
      hardware ? null,
    }:
    assert lib.assertMsg (
      builtins.match "[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*){2,}" id != null
    ) "invalid Flatpak application ID";
    assert lib.assertMsg (
      builtins.match "[A-Za-z0-9_+-][A-Za-z0-9_.+-]*" program != null
    ) "invalid program";
    assert lib.assertMsg (
      hardware == null
      || (
        lib.elem program (hardware.programs or [ ])
        && lib.all (source: lib.hasPrefix "/usr/" source) (builtins.attrValues hardware.libraries)
      )
    ) "hardware must select this program and host libraries under /usr";
    pkgs.runCommand "${pkg.pname}-${pkg.version}-flatpak"
      {
        nativeBuildInputs = [ pkgs.flatpak ];
        __structuredAttrs = true;
        unsafeDiscardReferences.out = true;
      }
      ''
        export HOME=$TMPDIR/home
        mkdir -p "$HOME" app/files/bin $out
        cp ${../src/launch.py} app/files/launch.py
        cp ${coreSrc}/src/engine.py app/files/engine.py
        cp ${../LICENSE} app/files/LICENSE
        cp ${
          pkgs.writeText "application.json" (
            builtins.toJSON {
              inherit program;
              hardware = if hardware == null then null else { preload = [ ]; } // hardware;
              nixBin = "${pkgs.nix}/bin";
              registerRoot = "${registerRoot}/bin/impurifier-register-root";
            }
          )
        } app/files/application.json
        ln -s ${pkg} app/files/nix-root
        printf '#!/usr/bin/sh\nexec ${pkgs.python3}/bin/python3 /app/launch.py "$@"\n' > app/files/bin/impurifier-launch
        chmod 755 app/files/bin/impurifier-launch
        ${lib.optionalString offline "cp -r ${core.offlineCache pkg} app/files/cache"}
        cat > app/metadata <<'META'
        [Application]
        name=${id}
        runtime=${runtimeRef}
        sdk=${runtimeRef}
        command=impurifier-launch
        [Environment]
        NIX_REMOTE=daemon
        META
        cp -r ${runtime} platform
        chmod -R u+w platform
        flatpak build-export --runtime $out/repository platform ${branch}
        flatpak build-finish --filesystem=/nix/store:ro --filesystem=/nix/var/nix/daemon-socket ${
          lib.optionalString (hardware != null) "--filesystem=host-os:ro"
        } ${lib.escapeShellArgs permissions} app
        flatpak build-export $out/repository app stable
        flatpak build-bundle $out/repository $out/${id}.flatpak ${id} stable
      '';
in
{
  inherit
    tools
    package
    sdk
    runtime
    makeApplication
    ;
  makeNetApplication = args: makeApplication (args // { offline = false; });
  makeOfflineApplication = args: makeApplication (args // { offline = true; });
  makePackage = args: {
    net = makeApplication (args // { offline = false; });
    offline = makeApplication (args // { offline = true; });
  };
}
