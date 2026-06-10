#!/usr/bin/env bash
#
# fftw3/mayhem/build.sh — build FFTW's OSS-Fuzz harness as a sanitized libFuzzer target
# (+ a standalone reproducer), AND FFTW's own `bench` verifier for mayhem/test.sh.
#
# The fuzzed surface (OSS-Fuzz fftw3_fuzzer): the input's first byte picks an FFT length
# ARRAY_SIZE = data[0]%250+1, the remaining bytes seed a complex signal, and the harness drives
# fftw_plan_dft_1d / fftw_execute / fftw_destroy_plan (FFTW_ESTIMATE) — i.e. FFTW's planner +
# scalar DFT codelet dispatch on attacker-sized/attacker-valued complex input.
#
# FFTW is autotools; building from the git checkout requires maintainer-mode + genfft (ocaml) to
# GENERATE the scalar codelets (n1_*.c/t1_*.c/...), exactly as OSS-Fuzz does. So we
# `sh bootstrap.sh` (== autoreconf --install + ./configure --enable-maintainer-mode --disable-shared
# --enable-threads) then `make`, producing ./.libs/libfftw3.a. We compile that library WITH
# $SANITIZER_FLAGS (CFLAGS) so the fuzzed planner/codelet code is instrumented.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) so an explicit empty --build-arg SANITIZER_FLAGS= builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS=-gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"
HARNESS_DIR="$SRC/mayhem/harnesses"

# ── 1) Generate codelets + build the sanitized static FFTW library ───────────────────────────────
# bootstrap.sh runs autoreconf and a maintainer-mode ./configure; pass our build flags so the
# library is compiled with the sanitizer. --disable-shared keeps the harness self-contained;
# --enable-threads matches the OSS-Fuzz/manual default (libpthread is linked below either way).
env CC="$CC" CFLAGS="$SANITIZER_FLAGS -O1" \
    sh bootstrap.sh --disable-shared --enable-threads
# Full `make`: genfft (ocaml) must build first and GENERATE the scalar codelets, which the dft/rdft
# subdir Makefiles then consume — so a selective per-subdir build can't shortcut codelet generation.
# (doc/ needs fig2dev, installed in the Dockerfile, so `all` completes; matches the OSS-Fuzz build.)
make -j"$MAYHEM_JOBS"

LIBFFTW="$SRC/.libs/libfftw3.a"
[ -f "$LIBFFTW" ] || { echo "ERROR: $LIBFFTW not built" >&2; exit 1; }

# ── 2) Standalone run-once driver (no libFuzzer runtime), compiled once as an object ─────────────
BUILD="$SRC/mayhem-build"
mkdir -p "$BUILD"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$HARNESS_DIR/standalone_main.c" -o "$BUILD/standalone_main.o"

mkdir -p /mayhem

# ── 3) Build each harness twice: libFuzzer (-> /mayhem/<name>) + standalone reproducer ───────────
INC="-I$SRC -I$SRC/api"
for f in "$HARNESS_DIR"/*_fuzzer.cc; do
  fuzzer=$(basename "$f" _fuzzer.cc)
  # libFuzzer target -> /mayhem/<fuzzer>_fuzzer
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $INC \
      "$f" $LIB_FUZZING_ENGINE "$LIBFFTW" -lpthread -lm \
      -o "/mayhem/${fuzzer}_fuzzer"

  # standalone reproducer -> /mayhem/<fuzzer>_fuzzer-standalone
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $INC \
      "$f" "$BUILD/standalone_main.o" "$LIBFFTW" -lpthread -lm \
      -o "/mayhem/${fuzzer}_fuzzer-standalone"

  echo "built ${fuzzer}_fuzzer (+ standalone)"
done

# ── 4) Build FFTW's own `bench` verifier with NORMAL flags (separate tree) for mayhem/test.sh.
#       `bench --verify` is a known-answer self-test (compares FFTW's DFT against a brute-force
#       reference and checks round-trip error tolerances). test.sh only RUNS it; never compiles. ──
TESTDIR="$SRC/mayhem-tests"
rm -rf "$TESTDIR"; mkdir -p "$TESTDIR"
# A clean checkout of the tracked sources (FFTW's configure refuses to build out-of-tree when $SRC
# itself is already configured, so we can't VPATH off the sanitized in-tree build) — then a full
# normal-flags maintainer build so test.sh's `bench` is an honest, non-sanitized oracle.
git -C "$SRC" archive HEAD | tar -x -C "$TESTDIR"
(
  cd "$TESTDIR"
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS CC="$CC" \
    sh bootstrap.sh --disable-shared --enable-threads >/dev/null 2>&1
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS make -j"$MAYHEM_JOBS" >/dev/null
)
if [ -x "$TESTDIR/tests/bench" ]; then
  echo "built FFTW bench verifier in mayhem-tests/tests/bench"
else
  echo "WARNING: bench verifier not built — mayhem/test.sh will fail loudly" >&2
fi

# ── 5) Build the behavioral oracle (fftw_checker) for mayhem/test.sh ────────────────────────────
# Built with NORMAL flags (no sanitizer), so it's a clean functional oracle that test.sh runs.
# When LD_PRELOAD-neutered (sabotage check), fftw_checker exits silently → test.sh catches the
# missing/wrong output → oracle is NOT reward-hackable.
$CC -O1 $DEBUG_FLAGS $INC \
    "$HARNESS_DIR/fftw_checker.c" "$SRC/mayhem-tests/.libs/libfftw3.a" -lpthread -lm \
    -o /mayhem/fftw_checker

echo "build.sh complete:"
ls -la /mayhem/*_fuzzer /mayhem/*_fuzzer-standalone /mayhem/fftw_checker 2>&1 || true
