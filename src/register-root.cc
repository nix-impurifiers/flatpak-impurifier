// SPDX-License-Identifier: MIT
#include <filesystem>
#include "nix/main/shared.hh"
#include "nix/store/store-open.hh"
#include "nix/store/indirect-root-store.hh"
#include "nix/store/gc-store.hh"
#include "nix/store/store-cast.hh"
#include "nix/util/error.hh"

int main(int argc, char **argv) {
    return nix::handleExceptions(argv[0], [&] {
        nix::initNix();
        if (argc != 2 && argc != 3) throw nix::UsageError("usage: impurifier-register-root HOST_SYMLINK [SANDBOX_SYMLINK]");
        auto root = std::filesystem::absolute(argv[1]).lexically_normal();
        auto view = argc == 3 ? std::filesystem::path(argv[2]) : root;
        if (!std::filesystem::is_symlink(view))
            throw nix::Error("the native deployment root must already be a symlink");
        auto target = std::filesystem::read_symlink(view);
        auto store = nix::openStore();
        auto path = store->parseStorePath(target.string());
        nix::require<nix::GcStore>(*store).addTempRoot(path);
        store->ensurePath(path);
        auto *indirect = dynamic_cast<nix::IndirectRootStore *>(&*store);
        if (!indirect) throw nix::Error("the host Nix provider does not support indirect GC roots");
        indirect->addIndirectRoot(root);
    });
}
