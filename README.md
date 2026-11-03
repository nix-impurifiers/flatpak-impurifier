# flatpak-impurifier

Build native Flatpak repositories and application bundles for Nix applications.
Original code is MIT licensed. Flatpak, OSTree, BusyBox, Nix and Python retain
their upstream licenses and notices; dependencies are supplied by pinned Nixpkgs.

```nix
let
  impurifier = inputs.flatpak-impurifier.lib.flatpak-impurifier { inherit pkgs; };
in impurifier.makeOfflineApplication {
  pkg = pkgs.hello;
  id = "org.example.Hello";
}
```

The output contains `repository/` with an application and its private runtime,
and an application `.flatpak` bundle. Add the repository with native Flatpak
and install the application. Use an appropriately signed remote in production;
`--no-gpg-verify` is only an explicit local development policy. The private
runtime must be available from the remote when installing the single-app bundle.

The host needs a working multi-user Nix provider and this project's helper.
Preparing an offline application imports its packaged cache:

```
sudo flatpak-impurifier prepare --owner "$USER" org.example.Hello
flatpak run org.example.Hello
```

Preparation queries the owner's actual native Flatpak installation, imports
only store data, and registers existing deployment symlinks as that owner.
It does not execute application code as root. A normal user can run
`flatpak-impurifier prepare org.example.Hello` with trusted substituters.
Unsigned offline imports remain subject to the host daemon's trust policy.
This helper is not yet a Nix installer; providing Nix through a native package
is a deferred project goal.

`makeNetApplication`, `makeOfflineApplication` and `makePackage` (net/offline
pair) select transport. `program` selects the Nix package executable.
`permissions` accepts native `flatpak build-finish` arguments. Application
permissions always include read-only `/nix/store` and the Nix daemon socket:
this grants access to host Nix and must be considered when choosing sandbox
permissions. The private runtime uses BusyBox plus pinned Nix/Python tools.
Its branch identifies the tool closure, keeping incompatible runtime versions
separate. This is not a general Freedesktop/GNOME runtime.

Nix roots belong to immutable native app/runtime deployments. The helper uses
the native Nix store API to register an existing root without rewriting it;
Flatpak's OSTree files remain unchanged. Launch discovers host deployment paths
from Flatpak's own `/.flatpak-info`, registers roots through the daemon and
executes the selected application. Native uninstall releases the deployment
root; retained runtime deployments continue to retain their own tool closure.
User application data follows native Flatpak retention policy.

Optional `hardware` uses the shared explicit library/program mapping. Source
libraries under `/usr` are read through Flatpak's native `host-os:ro` permission,
then captured as immutable Nix store snapshots at each launch. This grants
read access to host OS files. The snapshots remain rooted in the application's
native user data directory so already-running processes can retain old DSOs.
After uninstall or update, run `flatpak-impurifier prune` as the owner to release
snapshots whose native deployment was removed. This does not claim real GPU or
kernel ABI compatibility.

The current VM checks use real Flatpak, OSTree, bubblewrap, D-Bus and Nix.
They verify immutable root registration, sandbox execution, GC retention and
native removal. System installations, remote signing, GUI portals and service integration
remain additional coverage. Native updates, unsigned-cache rejection, unchanged
deployment checksums and host-library replacement are covered by the VM suite.

## Native app trees and bundled clients

`makeNativeApplication { id; payload; program; runtimeRef; branch?; architecture?; permissions?; }`
exports a native application repository and bundle from a producer-prepared `/app`
tree. Supply the runtime reference explicitly and make it available to consumers.
This path adds no Nix SDK, launcher, daemon access or `/nix` permission. The
producer supplies files that work in the chosen runtime; binaries are not relocated.
The native sandbox VM installs, executes, upgrades and removes the application,
checking the absence of a Nix client, socket, database and engine launcher.

Nix-backed application constructors optionally accept `bundledNixStore` and
`bundledNixNotices` for a static ELF client with upstream notices. Their private
runtime retains Python and the immutable-root registration API; the Nix CLI is
private to the app. Compatible external clients take precedence, explicit
`IMPURIFIER_NIX_STORE` disables fallback, and failed mutations are never retried
through another client. A bundled variant repeats the existing lifecycle suite
without an external Nix client on the sandbox PATH.

Nix-backed applications still require their host store/daemon, permissions and
initial trusted preparation. Preparation never executes a user-owned client
as root. The Nix provider/installer remains deferred.
