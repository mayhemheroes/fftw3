/*
 * fftw_checker.c — known-answer functional oracle for mayhem/test.sh
 *
 * Runs FFTW on three deterministic inputs and prints the computed values.
 * test.sh checks the printed values against known-correct answers; a no-op
 * patch (or LD_PRELOAD neuter) produces no output → test.sh fails → oracle
 * is NOT reward-hackable.
 *
 * Tests:
 *   1. Unit impulse (N=8): DFT of [1,0,0,...,0] → all bins = (1.0, 0.0)
 *   2. DC signal  (N=4):  DFT of [1,1,1,1]     → bin0=(4,0), rest=(0,0)
 *   3. Inverse round-trip (N=8): IFFT(FFT(x)) ≈ N*x for a ramp signal
 *
 * Build: cc -O1 -I$SRC -I$SRC/api fftw_checker.c $LIBFFTW -lpthread -lm -o fftw_checker
 * Exit: 0 = all pass, 1 = any mismatch.
 */
#include <fftw3.h>
#include <stdio.h>
#include <math.h>
#include <stdlib.h>

#define TOL 1e-9

static int check_close(double a, double b, double tol, const char *label) {
    if (fabs(a - b) <= tol) return 1;
    fprintf(stderr, "MISMATCH %s: got %.10g expected %.10g (diff=%.3e)\n",
            label, a, b, fabs(a-b));
    return 0;
}

int main(void) {
    int ok = 1;
    int N;

    /* ── Test 1: unit impulse → flat spectrum ─────────────────────────── */
    N = 8;
    {
        fftw_complex *in  = fftw_alloc_complex(N);
        fftw_complex *out = fftw_alloc_complex(N);
        for (int i = 0; i < N; i++) { in[i][0] = 0.0; in[i][1] = 0.0; }
        in[0][0] = 1.0;   /* unit impulse */

        fftw_plan p = fftw_plan_dft_1d(N, in, out, FFTW_FORWARD, FFTW_ESTIMATE);
        fftw_execute(p);
        fftw_destroy_plan(p);

        /* Every bin of DFT(impulse) = (1+0j) */
        for (int k = 0; k < N; k++) {
            printf("T1 bin%d re=%.6f im=%.6f\n", k, out[k][0], out[k][1]);
            ok &= check_close(out[k][0], 1.0, TOL, "T1_re");
            ok &= check_close(out[k][1], 0.0, TOL, "T1_im");
        }

        fftw_free(in); fftw_free(out);
    }

    /* ── Test 2: DC signal → energy only in bin 0 ────────────────────── */
    N = 4;
    {
        fftw_complex *in  = fftw_alloc_complex(N);
        fftw_complex *out = fftw_alloc_complex(N);
        for (int i = 0; i < N; i++) { in[i][0] = 1.0; in[i][1] = 0.0; }

        fftw_plan p = fftw_plan_dft_1d(N, in, out, FFTW_FORWARD, FFTW_ESTIMATE);
        fftw_execute(p);
        fftw_destroy_plan(p);

        printf("T2 bin0 re=%.6f im=%.6f\n", out[0][0], out[0][1]);
        ok &= check_close(out[0][0], (double)N, TOL, "T2_bin0_re");
        ok &= check_close(out[0][1], 0.0,       TOL, "T2_bin0_im");
        for (int k = 1; k < N; k++) {
            printf("T2 bin%d re=%.6f im=%.6f\n", k, out[k][0], out[k][1]);
            ok &= check_close(out[k][0], 0.0, TOL, "T2_hi_re");
            ok &= check_close(out[k][1], 0.0, TOL, "T2_hi_im");
        }

        fftw_free(in); fftw_free(out);
    }

    /* ── Test 3: forward/inverse round-trip — IFFT(FFT(x)) = N*x ──────── */
    N = 8;
    {
        fftw_complex *x    = fftw_alloc_complex(N);
        fftw_complex *mid  = fftw_alloc_complex(N);
        fftw_complex *back = fftw_alloc_complex(N);
        for (int i = 0; i < N; i++) { x[i][0] = (double)i; x[i][1] = 0.0; }

        fftw_plan fwd = fftw_plan_dft_1d(N, x,   mid,  FFTW_FORWARD,  FFTW_ESTIMATE);
        fftw_plan inv = fftw_plan_dft_1d(N, mid, back,  FFTW_BACKWARD, FFTW_ESTIMATE);
        fftw_execute(fwd);
        fftw_execute(inv);
        fftw_destroy_plan(fwd);
        fftw_destroy_plan(inv);

        /* back[i] should be N * x[i] (FFTW doesn't normalize) */
        for (int i = 0; i < N; i++) {
            printf("T3 i%d re=%.6f im=%.6f\n", i, back[i][0], back[i][1]);
            ok &= check_close(back[i][0], (double)N * x[i][0], TOL, "T3_re");
            ok &= check_close(back[i][1], 0.0,                 TOL, "T3_im");
        }

        fftw_free(x); fftw_free(mid); fftw_free(back);
    }

    fftw_cleanup();
    printf("FFTW_CHECKER %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
