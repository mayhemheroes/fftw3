#!/usr/bin/env bash
#
# fftw3/mayhem/test.sh — behavioral oracle for FFTW.
#
# Runs /mayhem/fftw_checker, a known-answer test binary built by mayhem/build.sh:
#   Test 1 (N=8): unit impulse → flat spectrum (all bins = 1+0j)
#   Test 2 (N=4): DC signal → energy only in bin 0 (bin0=4+0j, rest=0)
#   Test 3 (N=8): IFFT(FFT(ramp)) ≈ N×ramp (round-trip identity)
#
# Anti-reward-hacking: fftw_checker prints computed FFT values and asserts them
# against known-correct answers numerically. A no-op / neutered fftw_checker
# produces NO output, so the absence of "FFTW_CHECKER PASS" is caught below →
# test fails → oracle IS behavioral (not exit-code-only).
#
# This script only RUNS the pre-built binary; it never compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"

CHECKER="/mayhem/fftw_checker"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-${SRC:-/mayhem}/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -x "$CHECKER" ]; then
  echo "missing $CHECKER — run mayhem/build.sh first" >&2
  emit_ctrf "fftw-checker" 0 1 0; exit 2
fi

echo "=== running FFTW known-answer checker ==="
CHECKER_OUT="$("$CHECKER" 2>&1)"
CHECKER_RC=$?

echo "$CHECKER_OUT"

PASS=0; FAIL=0

# Test 1: unit impulse → flat spectrum.
# fftw_checker prints "T1 binK re=<val> im=<val>" for each bin; all must be 1.000000 / 0.000000.
# When neutered (LD_PRELOAD), checker prints nothing → these checks fail → FAIL rises.
T1_LINES=$(printf '%s\n' "$CHECKER_OUT" | grep -c '^T1 bin' || true)
if [ "$T1_LINES" -eq 8 ]; then
  # Verify re≈1.0 and im≈0.0 for all bins via awk (no python required).
  if printf '%s\n' "$CHECKER_OUT" | awk '/^T1 bin/{
        split($0,a," "); re=substr(a[3],4)+0; im=substr(a[4],4)+0;
        if(re<0.999999||re>1.000001||im<-1e-9||im>1e-9){bad=1}
      } END{exit bad}'; then
    PASS=$((PASS+1)); echo "  PASS  T1: unit impulse → flat spectrum (8 bins ok)"
  else
    FAIL=$((FAIL+1)); echo "  FAIL  T1: unit impulse → flat spectrum (value mismatch)"
  fi
else
  FAIL=$((FAIL+1)); echo "  FAIL  T1: expected 8 T1 lines, got $T1_LINES (checker silent?)"
fi

# Test 2: DC signal → energy in bin 0 only.
T2_LINES=$(printf '%s\n' "$CHECKER_OUT" | grep -c '^T2 bin' || true)
if [ "$T2_LINES" -eq 4 ]; then
  if printf '%s\n' "$CHECKER_OUT" | awk '/^T2 bin/{
        split($0,a," "); k=substr(a[2],4)+0; re=substr(a[3],4)+0; im=substr(a[4],4)+0;
        if(k==0){ if(re<3.999999||re>4.000001||im<-1e-9||im>1e-9){bad=1} }
        else    { if(re<-1e-9||re>1e-9||im<-1e-9||im>1e-9){bad=1} }
      } END{exit bad}'; then
    PASS=$((PASS+1)); echo "  PASS  T2: DC signal → bin0 only (4 bins ok)"
  else
    FAIL=$((FAIL+1)); echo "  FAIL  T2: DC signal → bin0 only (value mismatch)"
  fi
else
  FAIL=$((FAIL+1)); echo "  FAIL  T2: expected 4 T2 lines, got $T2_LINES (checker silent?)"
fi

# Test 3: round-trip IFFT(FFT(ramp)) = N*ramp.
T3_LINES=$(printf '%s\n' "$CHECKER_OUT" | grep -c '^T3 i' || true)
if [ "$T3_LINES" -eq 8 ]; then
  if printf '%s\n' "$CHECKER_OUT" | awk '/^T3 i/{
        split($0,a," "); idx=substr(a[2],2)+0; re=substr(a[3],4)+0; im=substr(a[4],4)+0;
        expected=idx*8.0;
        if(re<expected-1e-6||re>expected+1e-6||im<-1e-9||im>1e-9){bad=1}
      } END{exit bad}'; then
    PASS=$((PASS+1)); echo "  PASS  T3: round-trip IFFT(FFT(ramp))=8*ramp (8 samples ok)"
  else
    FAIL=$((FAIL+1)); echo "  FAIL  T3: round-trip IFFT(FFT(ramp)) (value mismatch)"
  fi
else
  FAIL=$((FAIL+1)); echo "  FAIL  T3: expected 8 T3 lines, got $T3_LINES (checker silent?)"
fi

# Test 4: checker's own self-report — must print "FFTW_CHECKER PASS" and exit 0.
if printf '%s\n' "$CHECKER_OUT" | grep -qF 'FFTW_CHECKER PASS' && [ "$CHECKER_RC" -eq 0 ]; then
  PASS=$((PASS+1)); echo "  PASS  T4: checker self-report PASS + exit 0"
else
  FAIL=$((FAIL+1)); echo "  FAIL  T4: checker did not report PASS or exited non-zero (rc=$CHECKER_RC)"
fi

emit_ctrf "fftw-checker" "$PASS" "$FAIL"
