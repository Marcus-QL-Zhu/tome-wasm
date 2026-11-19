/* Added only to the verified upstream SFMT translation unit. */
int headless_sfmt_export(uint32_t *out, int *index) {
    if (!initialized) return 0;
    memcpy(out, psfmt32, N32 * sizeof(uint32_t));
    *index = idx;
    return N32;
}
int headless_sfmt_import(const uint32_t *in, int count, int index) {
    if (count != N32 || index < 0 || index > N32) return 0;
    memcpy(psfmt32, in, N32 * sizeof(uint32_t));
    idx = index;
    initialized = 1;
    return 1;
}
