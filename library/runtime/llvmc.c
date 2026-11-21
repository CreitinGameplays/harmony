// LLVM-C backend shim for the self-hosted compiler.
//
// The Harmony compiler cannot pass C structs through its `extern "C"` FFI
// (raw pointers, integers and strings only), so this small host shim exposes
// the parts of the LLVM C API the driver needs: parse the deterministic IR
// text, run the -O pass pipeline, and emit one relocatable object file. The
// driver links that object with a prebuilt host runtime using `ld` directly.
//
// This is built into the compiler binary. The compiler that uses it still
// emits LLVM IR as text; `emit-llvm` keeps that path for debugging.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <llvm-c/Core.h>
#include <llvm-c/Error.h>
#include <llvm-c/IRReader.h>
#include <llvm-c/Target.h>
#include <llvm-c/TargetMachine.h>
#include <llvm-c/Transforms/PassBuilder.h>

static char hc_error[8192];

static void hc_set_error(const char *msg) {
    if (msg == 0) { msg = "unknown LLVM-C error"; }
    snprintf(hc_error, sizeof(hc_error), "%s", msg);
    fprintf(stderr, "harmony: llvm-c: %s\n", hc_error);
}

const char *hc_llvm_error(void) { return hc_error; }

void hc_llvm_init(void) {
    static int done = 0;
    if (done) { return; }
    LLVMInitializeNativeTarget();
    LLVMInitializeNativeAsmPrinter();
    LLVMInitializeNativeAsmParser();
    done = 1;
}

void *hc_llvm_parse_c(const char *text, unsigned long len) {
    LLVMMemoryBufferRef buf;
    LLVMModuleRef mod = 0;
    char *err = 0;
    hc_error[0] = 0;
    hc_llvm_init();
    buf = LLVMCreateMemoryBufferWithMemoryRangeCopy(text, len, "harmony-ir");
    if (buf == 0) {
        hc_set_error("could not copy the IR buffer");
        return 0;
    }
    // LLVMParseIRInContext takes ownership of the buffer on both paths.
    if (LLVMParseIRInContext(LLVMGetGlobalContext(), buf, &mod, &err) != 0) {
        hc_set_error(err);
        LLVMDisposeMessage(err);
        return 0;
    }
    return mod;
}

static const char *hc_passes(const char *opt) {
    if (opt == 0) { return "default<O2>"; }
    if (strcmp(opt, "-O0") == 0) { return "default<O0>"; }
    if (strcmp(opt, "-O1") == 0 || strcmp(opt, "-Og") == 0) { return "default<O1>"; }
    if (strcmp(opt, "-Os") == 0) { return "default<Os>"; }
    if (strcmp(opt, "-Oz") == 0) { return "default<Oz>"; }
    return "default<O2>";   // -O, -O2, -O3, -Ofast
}

static LLVMCodeGenOptLevel hc_codegen_level(const char *opt) {
    if (opt != 0 && strcmp(opt, "-O0") == 0) { return LLVMCodeGenLevelNone; }
    if (opt != 0 && (strcmp(opt, "-O1") == 0 || strcmp(opt, "-Og") == 0
                     || strcmp(opt, "-Os") == 0 || strcmp(opt, "-Oz") == 0)) {
        return LLVMCodeGenLevelLess;
    }
    return LLVMCodeGenLevelAggressive;
}

int hc_llvm_object_c(void *module, const char *obj, const char *opt) {
    LLVMTargetRef target = 0;
    LLVMTargetMachineRef tm = 0;
    LLVMTargetDataRef dl = 0;
    LLVMPassBuilderOptionsRef pbopts = 0;
    LLVMErrorRef perr = 0;
    char *triple = 0;
    char *err = 0;
    int rc = 0;
    hc_error[0] = 0;
    if (module == 0 || obj == 0) { hc_set_error("null module or object path"); return 1; }
    hc_llvm_init();
    triple = LLVMGetDefaultTargetTriple();
    if (LLVMGetTargetFromTriple(triple, &target, &err) != 0) {
        hc_set_error(err);
        LLVMDisposeMessage(err);
        LLVMDisposeMessage(triple);
        return 1;
    }
    tm = LLVMCreateTargetMachine(target, triple, "x86-64", "",
                                 hc_codegen_level(opt), LLVMRelocPIC,
                                 LLVMCodeModelDefault);
    LLVMDisposeMessage(triple);
    if (tm == 0) { hc_set_error("could not create a target machine"); return 1; }
    // Clang installs the target's data layout before its pass pipeline runs.
    // Do the same, or the optimizer reasons about the wrong pointer sizes.
    dl = LLVMCreateTargetDataLayout(tm);
    LLVMSetModuleDataLayout((LLVMModuleRef) module, dl);
    pbopts = LLVMCreatePassBuilderOptions();
    perr = LLVMRunPasses((LLVMModuleRef) module, hc_passes(opt), tm, pbopts);
    LLVMDisposePassBuilderOptions(pbopts);
    if (perr != 0) {
        hc_set_error(LLVMGetErrorMessage(perr));
        LLVMConsumeError(perr);
        LLVMDisposeTargetData(dl);
        LLVMDisposeTargetMachine(tm);
        return 1;
    }
    if (LLVMTargetMachineEmitToFile(tm, (LLVMModuleRef) module, obj,
                                    LLVMObjectFile, &err) != 0) {
        hc_set_error(err);
        LLVMDisposeMessage(err);
        rc = 1;
    }
    LLVMDisposeTargetData(dl);
    LLVMDisposeTargetMachine(tm);
    return rc;
}

void hc_llvm_dispose_c(void *module) {
    if (module != 0) { LLVMDisposeModule((LLVMModuleRef) module); }
}
