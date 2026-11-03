# SPDX-License-Identifier: MIT
{
  pkgs,
  impurifier,
  coreSrc,
  tools,
  bundled ? false,
}:
let
  app = pkgs.writeShellScriptBin "flatpak-app" "echo nix-in-flatpak" // {
    pname = "flatpak-app";
    version = "1";
  };
  cache = import (coreSrc + "/nix") {
    inherit pkgs;
    namespace = "flatpak-impurifier";
  };
  appCache = cache.offlineCache app;
  runtime = pkgs.runCommand "flatpak-native-runtime" { } ''
    mkdir -p $out/usr/bin $out/files
    cp ${pkgs.pkgsStatic.busybox}/bin/busybox $out/usr/bin/busybox
    for command in sh env printf cat id; do ln -s busybox $out/usr/bin/$command; done
    cat > $out/metadata <<'META'
    [Runtime]
    name=io.github.nix_impurifiers.Platform
    runtime=io.github.nix_impurifiers.Platform/x86_64/test
    sdk=io.github.nix_impurifiers.Platform/x86_64/test
    META
  '';
  application =
    pkgs.runCommand "flatpak-native-marker"
      {
        __structuredAttrs = true;
        unsafeDiscardReferences.out = true;
      }
      ''
        mkdir -p $out/files/bin
        ln -s ${app} $out/files/nix-root
        printf '#!/usr/bin/sh\nprintf "native-marker\\n"\n' > $out/files/bin/native-marker
        chmod 755 $out/files/bin/native-marker
        cat > $out/metadata <<'META'
        [Application]
        name=io.github.nix_impurifiers.NativeMarker
        runtime=io.github.nix_impurifiers.Platform/x86_64/test
        sdk=io.github.nix_impurifiers.Platform/x86_64/test
        command=native-marker
        [Context]
        filesystems=/nix/store:ro;/nix/var/nix/daemon-socket;
        [Environment]
        NIX_REMOTE=daemon
        META
      '';
  bundle = impurifier.makeOfflineApplication {
    pkg = app;
    id = "io.github.nix_impurifiers.Application";
  };
  app2 = pkgs.writeShellScriptBin "flatpak-app" "echo upgraded-flatpak" // {
    pname = "flatpak-app";
    version = "2";
  };
  bundle2 = impurifier.makeOfflineApplication {
    pkg = app2;
    id = "io.github.nix_impurifiers.Application";
  };
  net = impurifier.makeNetApplication {
    pkg = app;
    id = "io.github.nix_impurifiers.Application";
  };
  fixture = import (coreSrc + "/tests/hardware-fixture.nix") { inherit pkgs; };
  hardware = impurifier.makeOfflineApplication {
    pkg = fixture.tool;
    id = "io.github.nix_impurifiers.Hardware";
    inherit (fixture) hardware;
  };
  rooted = pkgs.writeText "flatpak-foreign-root-probe" "native GC chain";
in
{
  native-payload-vm = import ./native-payload-vm.nix { inherit pkgs impurifier; };
  native-vm = pkgs.testers.runNixOSTest {
    name = "flatpak-native-contract";
    requiredFeatures = {
      kvm = false;
      devnet = false;
    };
    nodes.machine = { lib, ... }: {
      virtualisation.qemu.package = lib.mkForce pkgs.qemu;
      virtualisation.qemu.forceAccel = false;
      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 8192;
      xdg.portal.enable = true;
      xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
      xdg.portal.config.common.default = "gtk";
      services.flatpak.enable = true;
      environment.systemPackages = [
        impurifier.package
        tools.registerRoot
        tools.package
        pkgs.ostree
        pkgs.nix
        pkgs.dbus
      ];
      users.users.consumer.isNormalUser = true;
    };
    testScript = ''
      import shlex
      start_all()
      machine.wait_for_unit("multi-user.target")
      def succeed(command):
          return machine.succeed("su - consumer -c " + shlex.quote(command))
      machine.succeed("cp -r ${hardware} /home/consumer/hardware; cp -r ${bundle} /home/consumer/bundle; cp -r ${bundle2} /home/consumer/bundle2; cp -r ${net} /home/consumer/net; chown -R consumer:users /home/consumer/bundle")
      machine.succeed("cp -r ${appCache} /home/consumer/app-cache; cp -r ${runtime} /home/consumer/runtime; cp -r ${application} /home/consumer/application; chmod -R u+w /home/consumer/runtime /home/consumer/application; chown -R consumer:users /home/consumer/runtime /home/consumer/application")
      machine.succeed("cp ${rooted} /home/consumer/root-content; mkdir -p /home/consumer/foreign /home/consumer/state; chown -R consumer:users /home/consumer/foreign /home/consumer/state /home/consumer/root-content")
      machine.succeed("mkdir -p /root/drivers /usr/lib; cp ${fixture.driver "1"}/usr/lib/libimpurifier-driver.so.1 /root/drivers/1.so; cp ${fixture.driver "2"}/usr/lib/libimpurifier-driver.so.1 /root/drivers/2.so")
      target = succeed("nix-store --add /home/consumer/root-content").strip()
      succeed("ln -s " + target + " /home/consumer/foreign/nix-root; chmod 555 /home/consumer/foreign")
      succeed("impurifier-register-root /home/consumer/foreign/nix-root")
      machine.succeed("nix-store --gc; test -e " + target)
      succeed("chmod 755 /home/consumer/foreign; rm /home/consumer/foreign/nix-root")
      machine.succeed("nix-store --gc; test ! -e " + target)
      succeed("flatpak build-export --runtime /home/consumer/repository /home/consumer/runtime test")
      succeed("flatpak build-finish /home/consumer/application")
      succeed("flatpak build-export /home/consumer/repository /home/consumer/application test")
      succeed("flatpak remote-add --user --no-gpg-verify local file:///home/consumer/repository")
      succeed("flatpak install --user --noninteractive local io.github.nix_impurifiers.NativeMarker")
      assert succeed("dbus-run-session -- flatpak run io.github.nix_impurifiers.NativeMarker").strip() == "native-marker"
      info = succeed("dbus-run-session -- flatpak run --command=/usr/bin/cat io.github.nix_impurifiers.NativeMarker /.flatpak-info")
      print(info)
      import configparser
      metadata = configparser.ConfigParser()
      metadata.read_string(info)
      app_path = metadata['Instance']['app-path']
      machine.succeed("nix-store --realise ${builtins.unsafeDiscardStringContext (toString app)} --option substituters file:///home/consumer/app-cache --option require-sigs false --add-root /home/consumer/temporary-root --indirect")
      succeed("dbus-run-session -- flatpak run --command=${tools.registerRoot}/bin/impurifier-register-root io.github.nix_impurifiers.NativeMarker " + shlex.quote(app_path + "/nix-root") + " /app/nix-root")
      machine.succeed("rm /home/consumer/temporary-root; nix-store --gc; test -e ${builtins.unsafeDiscardStringContext (toString app)}")
      assert succeed("dbus-run-session -- flatpak run --command=${builtins.unsafeDiscardStringContext (toString app)}/bin/flatpak-app io.github.nix_impurifiers.NativeMarker").strip() == "nix-in-flatpak"
      succeed("flatpak info --user io.github.nix_impurifiers.NativeMarker")
      succeed("flatpak uninstall --user --noninteractive io.github.nix_impurifiers.NativeMarker")
      machine.succeed("nix-store --gc; test ! -e ${builtins.unsafeDiscardStringContext (toString app)}")

      succeed("flatpak remote-add --user --no-gpg-verify impurifiers file:///home/consumer/bundle/repository")
      succeed("flatpak install --user --noninteractive impurifiers io.github.nix_impurifiers.Application")
      ${pkgs.lib.optionalString bundled ''succeed("dbus-run-session -- flatpak run --command=/usr/bin/sh io.github.nix_impurifiers.Application -c 'test -x /app/nix-store && ! command -v nix-store'")''}
      location = succeed("flatpak info --user --show-location io.github.nix_impurifiers.Application").strip()
      checksum = machine.succeed("find " + shlex.quote(location) + " -type f -exec sha256sum {} + | sort")
      machine.fail("su - consumer -c 'flatpak-impurifier prepare io.github.nix_impurifiers.Application'")
      machine.succeed("flatpak-impurifier prepare --owner consumer io.github.nix_impurifiers.Application")
      machine.succeed("nix-store --gc")
      assert succeed("dbus-run-session -- flatpak run io.github.nix_impurifiers.Application").strip() == "nix-in-flatpak"
      assert machine.succeed("find " + shlex.quote(location) + " -type f -exec sha256sum {} + | sort") == checksum
      succeed("flatpak remote-modify --user --url=file:///home/consumer/bundle2/repository impurifiers")
      succeed("flatpak update --user --noninteractive io.github.nix_impurifiers.Application")
      machine.fail("su - consumer -c 'dbus-run-session -- flatpak run io.github.nix_impurifiers.Application'")
      machine.succeed("flatpak-impurifier prepare --owner consumer io.github.nix_impurifiers.Application")
      assert succeed("dbus-run-session -- flatpak run io.github.nix_impurifiers.Application").strip() == "upgraded-flatpak"
      machine.succeed("nix-store --gc; test ! -e ${builtins.unsafeDiscardStringContext (toString app)}; test -e ${builtins.unsafeDiscardStringContext (toString app2)}")
      succeed("flatpak uninstall --user --noninteractive io.github.nix_impurifiers.Application")
      machine.succeed("nix-store --gc; test ! -e ${builtins.unsafeDiscardStringContext (toString app2)}")
      succeed("flatpak remote-modify --user --url=file:///home/consumer/net/repository impurifiers")
      succeed("flatpak install --user --noninteractive impurifiers io.github.nix_impurifiers.Application")
      machine.fail("su - consumer -c 'flatpak-impurifier prepare io.github.nix_impurifiers.Application'")
      succeed("flatpak uninstall --user --noninteractive io.github.nix_impurifiers.Application")
      machine.succeed("nix-store --gc; test ! -e ${builtins.unsafeDiscardStringContext (toString app)}")
      succeed("flatpak remote-add --user --no-gpg-verify hardware file:///home/consumer/hardware/repository")
      succeed("flatpak install --user --noninteractive hardware io.github.nix_impurifiers.Hardware")
      machine.succeed("flatpak-impurifier prepare --owner consumer io.github.nix_impurifiers.Hardware; cp /root/drivers/1.so /usr/lib/libimpurifier-driver.so.1")
      assert succeed("dbus-run-session -- flatpak run io.github.nix_impurifiers.Hardware").strip() == "1"
      machine.succeed("cp /root/drivers/2.so /usr/lib/libimpurifier-driver.so.1")
      assert succeed("dbus-run-session -- flatpak run io.github.nix_impurifiers.Hardware").strip() == "2"
      succeed("flatpak uninstall --user --noninteractive io.github.nix_impurifiers.Hardware")
      succeed("flatpak-impurifier prune")
      machine.succeed("nix-store --gc; test ! -e ${builtins.unsafeDiscardStringContext (toString fixture.tool)}")
    '';
  };
}
