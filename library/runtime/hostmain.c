// Host entry point for compilers/programs linked against libLLVM.
//
// The freestanding runtime's `_start` is renamed at build time so the normal
// C runtime startup can run first (libLLVM needs libc and TLS initialised).
// This wrapper calls the Harmony `main`, which the compiler mangles to
// `harmony_main`, then flushes the runtime's output buffer.
extern int harmony_main(void);
extern void lc_flush(void);
extern void lc_host_init(int argc, char **argv);

int main(int argc, char **argv) {
    lc_host_init(argc, argv);
    int code = harmony_main();
    lc_flush();
    return code & 0xff;
}
