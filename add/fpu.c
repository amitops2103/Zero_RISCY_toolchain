void test_fpu() {
    asm volatile ("fadd.s f0, f0, f0");
}
