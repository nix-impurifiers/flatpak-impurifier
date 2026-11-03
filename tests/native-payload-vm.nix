# SPDX-License-Identifier: MIT
{ pkgs, impurifier }:
let
  runtime = pkgs.runCommand "native-flatpak-runtime" { } ''
    mkdir -p $out/usr/bin $out/files
    cp ${pkgs.pkgsStatic.busybox}/bin/busybox $out/usr/bin/busybox
    for command in sh env cat; do ln -s busybox $out/usr/bin/$command; done
    cat > $out/metadata <<'META'
    [Runtime]
    name=org.niximpurifiers.NativePlatform
    runtime=org.niximpurifiers.NativePlatform/x86_64/test
    sdk=org.niximpurifiers.NativePlatform/x86_64/test
    META
  '';
  app =
    version:
    impurifier.makeNativeApplication {
      id = "org.niximpurifiers.NativeProof";
      runtimeRef = "org.niximpurifiers.NativePlatform/x86_64/test";
      program = "native-proof";
      payload = pkgs.pkgsStatic.stdenv.mkDerivation {
        name = "native-flatpak-${version}";
        dontUnpack = true;
        buildPhase = ''
          cat > proof.c <<'C'
          #include <stdio.h>
          int main(void) { puts("native-proof-${version}"); return 0; }
          C
          $CC proof.c -o proof
        '';
        installPhase = "mkdir -p $out/bin; cp proof $out/bin/native-proof";
      };
    };
in
pkgs.testers.runNixOSTest {
  name = "flatpak-native-payload";
  requiredFeatures.kvm = false;
  requiredFeatures.devnet = false;
  nodes.machine = { lib, ... }: {
    virtualisation.qemu.package = lib.mkForce pkgs.qemu;
    virtualisation.qemu.forceAccel = false;
    virtualisation.memorySize = 2048;
    services.flatpak.enable = true;
    xdg.portal.enable = true;
    xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    xdg.portal.config.common.default = "gtk";
    environment.systemPackages = [
      pkgs.flatpak
      pkgs.dbus
      pkgs.ostree
    ];
    users.users.consumer.isNormalUser = true;
  };
  testScript = ''
    import shlex
    start_all()
    machine.wait_for_unit("multi-user.target")
    def user(command):
        return "su - consumer -c " + shlex.quote(command)
    machine.succeed("cp -r ${runtime} /home/consumer/runtime; cp -r ${app "1"} /home/consumer/one; cp -r ${app "2"} /home/consumer/two; chmod -R u+w /home/consumer/runtime; chown -R consumer:users /home/consumer/runtime /home/consumer/one /home/consumer/two")
    machine.succeed(user("flatpak build-export --runtime /home/consumer/platform-repository /home/consumer/runtime test"))
    machine.succeed(user("flatpak remote-add --user --no-gpg-verify platform file:///home/consumer/platform-repository; flatpak install --user --noninteractive platform org.niximpurifiers.NativePlatform"))
    machine.succeed(user("flatpak remote-add --user --no-gpg-verify native file:///home/consumer/one/repository; flatpak install --user --noninteractive native org.niximpurifiers.NativeProof"))
    machine.succeed(user("dbus-run-session -- flatpak run org.niximpurifiers.NativeProof") + " | grep '^native-proof-1$'")
    machine.succeed(user("dbus-run-session -- flatpak run --command=sh org.niximpurifiers.NativeProof -c 'test ! -e /nix/var/nix/db/db.sqlite && test ! -e /nix/var/nix/daemon-socket/socket && test ! -e /app/launch.py && ! command -v nix-store'"))
    metadata = machine.succeed(user("dbus-run-session -- flatpak run --command=/usr/bin/cat org.niximpurifiers.NativeProof /.flatpak-info"))
    assert "filesystems=/nix" not in metadata, metadata
    machine.succeed(user("flatpak remote-modify --user --url=file:///home/consumer/two/repository native; flatpak update --user --noninteractive org.niximpurifiers.NativeProof"))
    machine.succeed(user("dbus-run-session -- flatpak run org.niximpurifiers.NativeProof") + " | grep '^native-proof-2$'")
    machine.succeed(user("flatpak uninstall --user --noninteractive org.niximpurifiers.NativeProof"))
    machine.fail(user("flatpak info --user org.niximpurifiers.NativeProof"))
  '';
}
