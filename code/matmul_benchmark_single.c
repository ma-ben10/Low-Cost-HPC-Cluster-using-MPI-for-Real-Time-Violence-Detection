/* MPI-enabled matrix multiplication benchmark
 * - Scatter rows of A among ranks
 * - Broadcast full B to all ranks
 * - Each rank computes its block of C
 * - Measure per-rank compute time and total time
 * Build: mpicc -O2 -march=native -o matmul_mpi matmul_benchmark_single.c
 * Run example: mpirun -np 4 ./matmul_mpi 2000
 */

#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef DEFAULT_N
#define DEFAULT_N 2000
#endif

static void fill_matrix(double *m, int n, unsigned int seed) {
    srand(seed);
    for (long long i = 0; i < (long long)n * n; i++) {
        m[i] = (double)rand() / RAND_MAX;
    }
}

/* local matmul: A_local (rrows x n) * B (n x n) -> C_local (rrows x n) */
static void matmul_block(double *A_local, double *B, double *C_local, int rrows, int n) {
    memset(C_local, 0, (size_t)rrows * n * sizeof(double));

    for (int i = 0; i < rrows; i++) {
        for (int k = 0; k < n; k++) {
            double a = A_local[(size_t)i * n + k];
            for (int j = 0; j < n; j++) {
                C_local[(size_t)i * n + j] += a * B[(size_t)k * n + j];
            }
        }
    }
}

int main(int argc, char **argv) {
    int rank, size;
    MPI_Init(&argc, &argv);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    int N = DEFAULT_N;
    if (argc >= 2) N = atoi(argv[1]);
    if (N <= 0) N = DEFAULT_N;

    if (rank == 0) {
        printf("MPI MatMul benchmark: N=%d, ranks=%d\n", N, size);
    }

    /* compute row counts and displacements for scatter */
    int base = N / size;
    int rem = N % size;
    int *rows = malloc(size * sizeof(int));
    int *displs = malloc(size * sizeof(int));
    int offset = 0;
    for (int r = 0; r < size; r++) {
        rows[r] = base + (r < rem ? 1 : 0);
        displs[r] = offset;
        offset += rows[r];
    }

    /* sizes in elements for scatterv/gatherv */
    int *sendcounts = malloc(size * sizeof(int));
    int *senddispls = malloc(size * sizeof(int));
    int *recvcounts = malloc(size * sizeof(int));
    int *recvdispls = malloc(size * sizeof(int));
    int cum = 0;
    for (int r = 0; r < size; r++) {
        sendcounts[r] = rows[r] * N; /* number of doubles */
        senddispls[r] = cum;
        recvcounts[r] = rows[r] * N;
        recvdispls[r] = cum;
        cum += sendcounts[r];
    }

    /* allocate local buffers */
    int rrows = rows[rank];
    double *A_local = malloc((size_t)rrows * N * sizeof(double));
    double *B = malloc((size_t)N * N * sizeof(double));
    double *C_local = malloc((size_t)rrows * N * sizeof(double));
    if (!A_local || !B || !C_local) {
        fprintf(stderr, "Rank %d: allocation failed (rows=%d N=%d)\n", rank, rrows, N);
        MPI_Abort(MPI_COMM_WORLD, 1);
    }

    double global_wall_start = 0.0;
    if (rank == 0) {
        /* root prepares full A and B */
        double *A = malloc((size_t)N * N * sizeof(double));
        if (!A) { fprintf(stderr, "root allocation A failed\n"); MPI_Abort(MPI_COMM_WORLD,1); }
        fill_matrix(A, N, 42);
        fill_matrix(B, N, 4242);

        /* start global wall clock AFTER data generation to measure distribution + compute */
        global_wall_start = MPI_Wtime();

        /* scatter rows of A to all ranks */
        MPI_Scatterv(A, sendcounts, senddispls, MPI_DOUBLE,
                     A_local, sendcounts[rank], MPI_DOUBLE, 0, MPI_COMM_WORLD);

        free(A);
    } else {
        /* other ranks receive their rows */
        MPI_Scatterv(NULL, sendcounts, senddispls, MPI_DOUBLE,
                     A_local, sendcounts[rank], MPI_DOUBLE, 0, MPI_COMM_WORLD);
    }

    /* broadcast B to all ranks (root already has B filled) */
    MPI_Bcast(B, N * N, MPI_DOUBLE, 0, MPI_COMM_WORLD);

    /* per-rank timing: measure times around computation */
    double t_recv_done = MPI_Wtime(); /* approximate time after recv/bcast */
    double t_compute_start = MPI_Wtime();

    matmul_block(A_local, B, C_local, rrows, N);

    double t_compute_end = MPI_Wtime();
    double t_after_compute = MPI_Wtime();

    /* optionally gather C_local back to root (size can be huge) - we skip gathering full C by default */

    /* gather timing info to root */
    double compute_time = t_compute_end - t_compute_start;
    double total_time_rank = t_after_compute - global_wall_start; /* note: global_wall_start==0 on non-root */

    /* share global_wall_start with others: broadcast root's start */
    MPI_Bcast(&global_wall_start, 1, MPI_DOUBLE, 0, MPI_COMM_WORLD);

    /* recompute total_time_rank properly now that global_wall_start is known on all ranks */
    double now = MPI_Wtime();
    total_time_rank = now - global_wall_start;

    char hostname[256]; hostname[0]='\0'; gethostname(hostname, sizeof(hostname));

    /* collect compute times and total times */
    double *all_compute = NULL; double *all_total = NULL;
    int *all_rows = NULL;
    if (rank == 0) {
        all_compute = malloc(size * sizeof(double));
        all_total = malloc(size * sizeof(double));
        all_rows = malloc(size * sizeof(int));
    }

    MPI_Gather(&compute_time, 1, MPI_DOUBLE, all_compute, 1, MPI_DOUBLE, 0, MPI_COMM_WORLD);
    MPI_Gather(&total_time_rank, 1, MPI_DOUBLE, all_total, 1, MPI_DOUBLE, 0, MPI_COMM_WORLD);
    MPI_Gather(&rrows, 1, MPI_INT, all_rows, 1, MPI_INT, 0, MPI_COMM_WORLD);

    /* gather hostnames (fixed-length strings) */
    int hn_len = 256;
    char *all_hosts = NULL;
    if (rank == 0) all_hosts = malloc(size * hn_len);
    MPI_Gather(hostname, hn_len, MPI_CHAR, all_hosts, hn_len, MPI_CHAR, 0, MPI_COMM_WORLD);

    if (rank == 0) {
        double wall_end = MPI_Wtime();
        double wall_total = wall_end - global_wall_start;

        printf("\n=== MatMul MPI Benchmark Summary ===\n");
        printf("Matrix: %d x %d, ranks: %d\n", N, N, size);
        printf("Global wall-clock (root measured): %.6f sec\n", wall_total);

        double sum_compute = 0.0, min_compute = 1e300, max_compute = 0.0;
        double sum_total = 0.0, min_total = 1e300, max_total = 0.0;
        int total_rows = 0;
        for (int r = 0; r < size; r++) {
            double ct = all_compute[r];
            double tt = all_total[r];
            int rr = all_rows[r];
            char *hn = &all_hosts[r * hn_len];
            printf("Rank %2d [%s]: rows=%5d compute=%.6f total=%.6f\n", r, hn, rr, ct, tt);
            sum_compute += ct; sum_total += tt; total_rows += rr;
            if (ct < min_compute) min_compute = ct;
            if (ct > max_compute) max_compute = ct;
            if (tt < min_total) min_total = tt;
            if (tt > max_total) max_total = tt;
        }

        printf("\nRows total: %d (N=%d)\n", total_rows, N);
        printf("Compute time: min=%.6f avg=%.6f max=%.6f\n", min_compute, sum_compute/size, max_compute);
        printf("Total time:   min=%.6f avg=%.6f max=%.6f\n", min_total, sum_total/size, max_total);

        /* basic flop estimate for this algorithm: 2*N^3 ops */
        double flops = 2.0 * (double)N * N * N;
        double gflops = (flops / max_compute) / 1e9;
        printf("Estimated peak GFLOPS (per slowest rank compute time): %.3f\n", gflops);

        free(all_compute); free(all_total); free(all_rows); free(all_hosts);
    }

    free(A_local); free(B); free(C_local);
    free(rows); free(displs); free(sendcounts); free(senddispls); free(recvcounts); free(recvdispls);

    MPI_Finalize();
    return 0;
}