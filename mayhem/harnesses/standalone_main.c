/* standalone_main.c — a libFuzzer-free run-once driver for the fftw3 harness.
 * Reads one input file, hands its bytes to LLVMFuzzerTestOneInput, exits.
 * Linked into each /mayhem/<fuzzer>-standalone reproducer (no libFuzzer runtime).
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s <input-file>\n", argv[0]);
    return 1;
  }
  FILE *f = fopen(argv[1], "rb");
  if (!f) {
    fprintf(stderr, "failed to open %s\n", argv[1]);
    return 2;
  }
  fseek(f, 0, SEEK_END);
  long size = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (size < 0) { fclose(f); return 3; }
  uint8_t *data = (uint8_t *)malloc((size_t)size ? (size_t)size : 1);
  if (!data) { fclose(f); return 4; }
  size_t r = size ? fread(data, (size_t)size, 1, f) : 0;
  fclose(f);
  if (size && r != 1) {
    fprintf(stderr, "read failed\n");
    free(data);
    return 5;
  }
  LLVMFuzzerTestOneInput(data, (size_t)size);
  free(data);
  return 0;
}
