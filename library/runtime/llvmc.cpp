// Full LLVM shim linked into the compiler binary: the core LLVM-C bridge plus
// an embedded LLD linker. Generated programs never spawn clang or ld.
#include "llvmc_core.cpp"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include <dlfcn.h>
#include <libgen.h>
#include <limits.h>
#include <unistd.h>

#include <llvm/Config/llvm-config.h>
#include <llvm/ADT/ArrayRef.h>
#include <llvm/Support/raw_ostream.h>
#include <lld/Common/Driver.h>

LLD_HAS_DRIVER(elf)

static bool hc_exists(const std::string &p) {
    return std::filesystem::exists(p) && !std::filesystem::is_directory(p);
}

static std::string hc_first(const std::vector<std::string> &candidates) {
    for (const auto &p : candidates) if (hc_exists(p)) return p;
    return "";
}

static std::string hc_arch_dir() {
    char *triple = LLVMGetDefaultTargetTriple();
    std::string t(triple ? triple : "");
    LLVMDisposeMessage(triple);
    if (t.rfind("x86_64", 0) == 0) return "x86_64-linux-gnu";
    if (t.rfind("aarch64", 0) == 0) return "aarch64-linux-gnu";
    return "";
}

static std::string hc_gcc_crt_dir(const std::string &filename) {
    std::string arch = hc_arch_dir();
    std::vector<std::filesystem::path> roots = {
        "/usr/lib/gcc", "/usr/lib/gcc-cross", "/usr/local/lib/gcc"};
    std::vector<std::string> found;
    for (const auto &root : roots) {
        std::error_code ec;
        if (!std::filesystem::exists(root, ec)) continue;
        for (const auto &archdir : std::filesystem::directory_iterator(root, ec)) {
            if (!archdir.is_directory()) continue;
            for (const auto &verdir : std::filesystem::directory_iterator(archdir.path(), ec)) {
                if (!verdir.is_directory()) continue;
                std::string candidate = (verdir.path() / filename).string();
                if (!hc_exists(candidate)) continue;
                if (arch.empty() ||
                    archdir.path().filename().string().find(arch) != std::string::npos) {
                    found.push_back(candidate);
                }
            }
        }
    }
    if (found.empty()) return "";
    std::sort(found.begin(), found.end());
    return found.back();
}

static std::string hc_llvm_lib_dir() {
    Dl_info info;
    if (dladdr((void *)&LLVMGetGlobalContext, &info) != 0 && info.dli_fname) {
        char buf[PATH_MAX];
        char *copy = strdup(info.dli_fname);
        std::string dir = dirname(copy);
        free(copy);
        if (realpath(dir.c_str(), buf)) return buf;
        return dir;
    }
    return "";
}

static std::string hc_dynamic_linker(const std::string &arch) {
    if (arch == "aarch64-linux-gnu") {
        return hc_first({"/lib/ld-linux-aarch64.so.1",
                         "/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1"});
    }
    return hc_first({"/lib64/ld-linux-x86-64.so.2",
                     "/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2",
                     "/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"});
}

// Links objects with LLD in-process. `flags`: bit 0 includes the embedded
// host runtime objects; bit 1 also includes the small LLVM-C core object
// (needed when the program itself calls the LLVM API, i.e. a self rebuild).
extern "C" int hc_lld_link(int nobj, const char **objs, const char *output,
                           int flags, char *errbuf, int errlen) {
    hc_error[0] = 0;
    std::vector<std::string> args;
    args.push_back("ld.lld");
    args.push_back("-flavor"); args.push_back("gnu");
    args.push_back("--hash-style=gnu");
    args.push_back("--eh-frame-hdr");
    args.push_back("-m");
    std::string arch = hc_arch_dir();
    args.push_back(arch == "aarch64-linux-gnu" ? "aarch64_linux" : "elf_x86_64");
    args.push_back("-pie");
    std::string ldso = hc_dynamic_linker(arch);
    if (ldso.empty()) { hc_set("could not find the dynamic linker"); return 1; }
    args.push_back("-dynamic-linker"); args.push_back(ldso);
    args.push_back("-o"); args.push_back(output);

    std::string crt1 = hc_first({"/usr/lib/" + arch + "/Scrt1.o", "/lib/" + arch + "/Scrt1.o"});
    std::string crti = hc_first({"/usr/lib/" + arch + "/crti.o", "/lib/" + arch + "/crti.o"});
    std::string crtn = hc_first({"/usr/lib/" + arch + "/crtn.o", "/lib/" + arch + "/crtn.o"});
    std::string crtbegin = hc_gcc_crt_dir("crtbeginS.o");
    std::string crtend = hc_gcc_crt_dir("crtendS.o");
    if (crt1.empty() || crti.empty() || crtn.empty() || crtbegin.empty() || crtend.empty()) {
        hc_set("could not find the C runtime startup objects");
        return 1;
    }
    args.push_back(crt1);
    args.push_back(crti);
    args.push_back(crtbegin);
    args.push_back("-L" + std::filesystem::path(crtbegin).parent_path().string());
    args.push_back("-L/usr/lib/" + arch);
    args.push_back("-L/lib/" + arch);
    args.push_back("-L/usr/lib64");
    args.push_back("-L/lib64");
    std::string libdir = hc_llvm_lib_dir();
    if (libdir.empty()) { hc_set("could not locate libLLVM"); return 1; }
    args.push_back("-L" + libdir);
    args.push_back("-rpath"); args.push_back(libdir);

    // The caller supplies the runtime and LLVM-C shim objects alongside the
    // freshly generated objects. They are inputs to LLD, not external tools.
    (void)flags;
    for (int i = 0; i < nobj; ++i) args.push_back(objs[i] ? objs[i] : "");

    // The embedded shim itself contains LLD, so a self-rebuilt compiler also
    // needs the LLD archives and their system dependencies at link time.
    args.push_back("-llldELF");
    args.push_back("-llldCommon");
    args.push_back("-lLLVM-" + std::to_string(LLVM_VERSION_MAJOR));
    args.push_back("-lstdc++"); args.push_back("-lpthread");
    args.push_back("-lrt"); args.push_back("-ldl"); args.push_back("-lm");
    args.push_back("-lz"); args.push_back("-lzstd"); args.push_back("-lxml2");
    args.push_back("-lgcc");
    args.push_back("--as-needed"); args.push_back("-lgcc_s"); args.push_back("--no-as-needed");
    args.push_back("-lc");
    args.push_back("-lgcc");
    args.push_back("--as-needed"); args.push_back("-lgcc_s"); args.push_back("--no-as-needed");
    args.push_back(crtend);
    args.push_back(crtn);

    std::vector<const char *> cargs;
    for (auto &s : args) cargs.push_back(s.c_str());
    std::string out, errout;
    llvm::raw_string_ostream os(out), es(errout);
    auto r = lld::lldMain(llvm::ArrayRef<const char *>(cargs.data(), cargs.size()),
                          os, es, {{lld::Gnu, &lld::elf::link}});
    os.flush();
    es.flush();
    if (!out.empty()) std::fwrite(out.data(), 1, out.size(), stdout);
    if (r.retCode != 0) hc_set(errout.empty() ? "lld failed" : errout.c_str());
    if (errbuf && errlen > 0) {
        std::size_t n = std::min((std::size_t)errlen - 1, errout.size());
        if (n > 0) std::memcpy(errbuf, errout.data(), n);
        errbuf[n] = 0;
    }
    return r.retCode;
}
