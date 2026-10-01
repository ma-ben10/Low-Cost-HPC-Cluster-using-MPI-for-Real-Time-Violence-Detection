#include <mpi.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

static inline double f(double x) {
    return 4.0 / (1.0 + x * x);
}

// Approximates pi via trapezoidal rule on f(x) = 4 / (1 + x^2)
// Each rank integrates a slice of [0, 1] and we sum the partial areas.
int main(int argc, char **argv) {
    const double a = 0.0;         // lower bound
    const double b = 1.0;         // upper bound
    int64_t n = INT64_C(100024) * INT64_C(100024);  // default number of trapezoids

    MPI_Init(&argc, &argv);

    double t_start = MPI_Wtime();

    int rank = 0;
    int world_size = 0;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &world_size);

    // Allow overriding the resolution: mpirun ... ./mpi_trap_pi 1000000
    if (argc > 1) {
        n = (int64_t)strtoll(argv[1], NULL, 10);
        if (n <= 0) {
            if (rank == 0) {
                fprintf(stderr, "n must be positive\n");
            }
            MPI_Abort(MPI_COMM_WORLD, 1);
        }
    }

    const double h = (b - a) / (double)n;   // width of one trapezoid

    // Compute local range by simple block partition of trapezoids
    const int64_t local_n = n / (int64_t)world_size;           // base count per rank
    const int64_t remainder = n % (int64_t)world_size;         // leftover trapezoids
    const int64_t extra = (rank < remainder) ? 1 : 0;          // some ranks get +1
    const int64_t local_traps = local_n + extra;

    // Starting trapezoid index assigned to this rank
    const int64_t start_index = (int64_t)rank * local_n + ((int64_t)rank < remainder ? rank : remainder);

    double local_a = a + start_index * h;
    double local_b = local_a + local_traps * h;

    // Trapezoidal rule on the local sub-interval
    double local_sum = 0.0;

    double x = local_a;
    local_sum += 0.5 * f(local_a);  // first endpoint weight 1/2
    for (int64_t i = 1; i < local_traps; ++i) {
        x += h;
        local_sum += f(x);          // interior points weight 1
    }
    local_sum += 0.5 * f(local_b);  // last endpoint weight 1/2

    local_sum *= h;                 // scale by trapezoid width

    double global_sum = 0.0;
    MPI_Reduce(&local_sum, &global_sum, 1, MPI_DOUBLE, MPI_SUM, 0, MPI_COMM_WORLD);

    double t_end = MPI_Wtime();

    if (rank == 0) {
         printf("Estimated pi = %.12f with n=%" PRId64 " trapezoids using %d ranks\n",
             global_sum, n, world_size);
        printf("Wall time     = %.6f seconds\n", t_end - t_start);
    }

    MPI_Finalize();
    return 0;
}
