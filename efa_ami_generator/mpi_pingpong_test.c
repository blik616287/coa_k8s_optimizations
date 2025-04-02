#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_MSG_SIZE (1024 * 1024)
#define NUM_ITERATIONS 100

int main(int argc, char** argv) {
    int rank, size;
    char *send_buffer, *recv_buffer;
    double start_time, end_time;
    MPI_Status status;

    // Initialize MPI
    MPI_Init(&argc, &argv);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    // Verify we have exactly 2 processes
    if (size != 2) {
        if (rank == 0) {
            fprintf(stderr, "This test requires exactly 2 processes\n");
        }
        MPI_Finalize();
        return 1;
    }

    // Allocate buffers
    send_buffer = malloc(MAX_MSG_SIZE);
    recv_buffer = malloc(MAX_MSG_SIZE);

    if (!send_buffer || !recv_buffer) {
        fprintf(stderr, "Memory allocation failed\n");
        MPI_Finalize();
        return 1;
    }

    // Initialize buffers
    memset(send_buffer, rank, MAX_MSG_SIZE);
    memset(recv_buffer, 0, MAX_MSG_SIZE);

    // Message size tests from 1 byte to 1 MB
    for (int msg_size = 1; msg_size <= MAX_MSG_SIZE; msg_size *= 2) {
        // Synchronize before test
        MPI_Barrier(MPI_COMM_WORLD);

        // Timing for ping-pong
        if (rank == 0) {
            start_time = MPI_Wtime();

            for (int i = 0; i < NUM_ITERATIONS; i++) {
                // Send message to rank 1
                MPI_Send(send_buffer, msg_size, MPI_CHAR, 1, 0, MPI_COMM_WORLD);

                // Receive message back from rank 1
                MPI_Recv(recv_buffer, msg_size, MPI_CHAR, 1, 1, MPI_COMM_WORLD, &status);
            }

            end_time = MPI_Wtime();

            // Calculate and print bandwidth
            double total_time = end_time - start_time;
            double avg_time = total_time / NUM_ITERATIONS;
            double bandwidth = (msg_size * 2.0) / (avg_time * 1024 * 1024);  // MB/s

            printf("Message Size: %d bytes\n", msg_size);
            printf("Average Latency: %f seconds\n", avg_time);
            printf("Bandwidth: %f MB/s\n", bandwidth);
        }
        else if (rank == 1) {
            for (int i = 0; i < NUM_ITERATIONS; i++) {
                // Receive message from rank 0
                MPI_Recv(recv_buffer, msg_size, MPI_CHAR, 0, 0, MPI_COMM_WORLD, &status);

                // Send message back to rank 0
                MPI_Send(send_buffer, msg_size, MPI_CHAR, 0, 1, MPI_COMM_WORLD);
            }
        }
    }

    // Cleanup
    free(send_buffer);
    free(recv_buffer);

    // Finalize MPI
    MPI_Finalize();
    return 0;
}
