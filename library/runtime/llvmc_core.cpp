// Core LLVM-C bridge, shared by the compiler's full shim and by the small
// object embedded into programs that call the LLVM API (self rebuilds).
// Defines only parse/optimise/emit functions; no linker dependency here.
#ifndef HARMONY_LLVMC_CORE_CPP
#define HARMONY_LLVMC_CORE_CPP

#include <cstdio>
#include <cstring>

#include <llvm-c/Core.h>
#include <llvm-c/Error.h>
#include <llvm-c/IRReader.h>
#include <llvm-c/Target.h>
#include <llvm-c/TargetMachine.h>
#include <llvm-c/Transforms/PassBuilder.h>

static char hc_error[8192];

static void hc_set(const char *msg) {
    if (!msg) msg = "unknown LLVM-C error";
    std::snprintf(hc_error, sizeof(hc_error), "%s", msg);
    std::fprintf(stderr, "harmony: llvm-c: %s\n", hc_error);
}

extern "C" const char *hc_llvm_error(void) { return hc_error; }

extern "C" void hc_llvm_init(void) {
    static bool done = false;
    if (done) return;
    LLVMInitializeNativeTarget();
    LLVMInitializeNativeAsmPrinter();
    LLVMInitializeNativeAsmParser();
    done = true;
}

extern "C" void *hc_llvm_parse_c(const char *text, unsigned long len) {
    hc_error[0] = 0;
    hc_llvm_init();
    LLVMMemoryBufferRef buf =
        LLVMCreateMemoryBufferWithMemoryRangeCopy(text, len, "harmony-ir");
    if (!buf) { hc_set("could not copy the IR buffer"); return nullptr; }
    LLVMModuleRef mod = nullptr;
    char *err = nullptr;
    // LLVMParseIRInContext takes ownership of the buffer on both paths.
    if (LLVMParseIRInContext(LLVMGetGlobalContext(), buf, &mod, &err) != 0) {
        hc_set(err ? err : "IR parse failed");
        if (err) LLVMDisposeMessage(err);
        return nullptr;
    }
    return mod;
}

static const char *hc_passes(const char *opt) {
    if (!opt) return "default<O2>";
    if (std::strcmp(opt, "-O0") == 0) return "default<O0>";
    if (std::strcmp(opt, "-O1") == 0 || std::strcmp(opt, "-Og") == 0) return "default<O1>";
    if (std::strcmp(opt, "-Os") == 0) return "default<Os>";
    if (std::strcmp(opt, "-Oz") == 0) return "default<Oz>";
    return "default<O2>";
}

static LLVMCodeGenOptLevel hc_level(const char *opt) {
    if (opt && std::strcmp(opt, "-O0") == 0) return LLVMCodeGenLevelNone;
    if (opt && (std::strcmp(opt, "-O1") == 0 || std::strcmp(opt, "-Og") == 0 ||
                std::strcmp(opt, "-Os") == 0 || std::strcmp(opt, "-Oz") == 0)) {
        return LLVMCodeGenLevelLess;
    }
    return LLVMCodeGenLevelAggressive;
}

extern "C" int hc_llvm_object_c(void *module, const char *obj, const char *opt) {
    hc_error[0] = 0;
    if (!module || !obj) { hc_set("null module or object path"); return 1; }
    hc_llvm_init();
    char *triple = LLVMGetDefaultTargetTriple();
    LLVMTargetRef target = nullptr;
    char *err = nullptr;
    if (LLVMGetTargetFromTriple(triple, &target, &err) != 0) {
        hc_set(err ? err : "no native target");
        if (err) LLVMDisposeMessage(err);
        LLVMDisposeMessage(triple);
        return 1;
    }
    LLVMTargetMachineRef tm = LLVMCreateTargetMachine(
        target, triple, "x86-64", "", hc_level(opt), LLVMRelocPIC,
        LLVMCodeModelDefault);
    LLVMDisposeMessage(triple);
    if (!tm) { hc_set("could not create a target machine"); return 1; }
    LLVMTargetDataRef dl = LLVMCreateTargetDataLayout(tm);
    LLVMSetModuleDataLayout((LLVMModuleRef)module, dl);
    LLVMPassBuilderOptionsRef pb = LLVMCreatePassBuilderOptions();
    LLVMErrorRef perr = LLVMRunPasses((LLVMModuleRef)module, hc_passes(opt), tm, pb);
    LLVMDisposePassBuilderOptions(pb);
    if (perr) {
        hc_set(LLVMGetErrorMessage(perr));
        LLVMConsumeError(perr);
        LLVMDisposeTargetData(dl);
        LLVMDisposeTargetMachine(tm);
        return 1;
    }
    int rc = 0;
    if (LLVMTargetMachineEmitToFile(tm, (LLVMModuleRef)module, obj,
                                    LLVMObjectFile, &err) != 0) {
        hc_set(err ? err : "object emission failed");
        if (err) LLVMDisposeMessage(err);
        rc = 1;
    }
    LLVMDisposeTargetData(dl);
    LLVMDisposeTargetMachine(tm);
    return rc;
}

extern "C" void hc_llvm_dispose_c(void *module) {
    if (module) LLVMDisposeModule((LLVMModuleRef)module);
}

#endif
