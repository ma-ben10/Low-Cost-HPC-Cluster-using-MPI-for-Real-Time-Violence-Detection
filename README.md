# Heterogeneous MPI Cluster and Distributed Video Inference

This project explores distributed computing across an x86_64 Linux host and ARM64 Raspberry Pi 3B nodes. The current lab setup uses QEMU to emulate four Raspberry Pi nodes, connected to the host through a private Linux bridge and TAP interfaces. OpenMPI launches parallel applications across the heterogeneous x86/ARM cluster over SSH.

## What is included

- QEMU-based ARM64 Raspberry Pi 3B cluster orchestration.
- Linux bridge (`br0`) and TAP networking on `192.168.100.0/24`.
- Automated VM startup, node discovery, SSH trust setup, hostname configuration, and hostfile generation.
- OpenMPI installation, synchronization, MCA network configuration, and remote deployment scripts.
- C MPI examples for numerical pi estimation and distributed matrix multiplication.
- A Python `mpi4py` video-inference pipeline using PyTorch TorchScript, OpenCV, and NumPy.
- Benchmarking scripts for comparing a single Raspberry Pi node with the full cluster.

## Architecture

```text
x86_64 Linux host
  |-- OpenMPI master process
  |-- br0 Linux bridge + TAP interfaces
  |-- QEMU ARM64 Raspberry Pi 3B node 1
  |-- QEMU ARM64 Raspberry Pi 3B node 2
  |-- QEMU ARM64 Raspberry Pi 3B node 3
  `-- QEMU ARM64 Raspberry Pi 3B node 4
```

The control flow is:

1. Configure the bridge and TAP devices with `shell/setup_network.sh`.
2. Start the ARM64 QEMU nodes with `shell/start_vms.sh`.
3. Discover nodes and configure SSH with `shell/setup_ssh_vms.sh` or `shell/add_node.sh`.
4. Install or synchronize OpenMPI with `shell/setup_mpi_vms.sh` and the synchronization scripts.
5. Launch an MPI workload with `shell/run_mpi.sh` or a workload-specific command.

## Workloads

### MPI numerical and benchmark programs

The `code/` directory contains:

- `hello_mpi.c`: MPI smoke test that reports rank, world size, and hostname.
- `mpi_trap_pi.c`: parallel trapezoidal integration with uneven-workload handling and `MPI_Reduce`.
- `matmul_benchmark_single.c`: row-distributed matrix multiplication using `MPI_Scatterv`, `MPI_Bcast`, and timing aggregation with `MPI_Gather`.

Example compilation:

```bash
mpicc -O2 -std=c11 code/mpi_trap_pi.c -o code/mpi_trap_pi
mpicc -O2 -std=c11 code/matmul_benchmark_single.c -o code/matmul
```

### Distributed video inference

`violanc/distributed_inference.py` runs a TorchScript video classifier with one MPI master and four workers. The master reads video frames with OpenCV, resizes and normalizes them, groups them into chunks, distributes chunks with `mpi4py`, and aggregates worker predictions into a final violence/non-violence result.

Python dependencies are listed in `violanc/requirements.txt`:

```bash
python3 -m venv violanc/.venv
source violanc/.venv/bin/activate
python -m pip install -r violanc/requirements.txt
```

The TorchScript model is intentionally excluded from Git because it is larger than GitHub's normal file limit. Place `hybrid_model3_torchscript_final.pt` in `violanc/` before running the inference workflow.

## Requirements

- Linux host with Bash, QEMU AArch64, OpenMPI, SSH, `arp-scan`, and bridge/TAP support.
- ARM64 Raspberry Pi OS images and a Raspberry Pi 3B-compatible QEMU kernel/DTB for the emulated setup.
- `sudo` access for bridge, TAP, firewall, and VM operations.
- Python 3 with `mpi4py`, PyTorch, OpenCV, and NumPy for video inference.

## Important safety notes

- The scripts target a private lab network and use example addresses. Adapt the network interface, subnet, VM images, and node addresses to your environment.
- Never commit SSH private keys, passwords, model files, VM disk images, or generated logs.
- `shell/add_node.sh` accepts an optional bootstrap password through `INITIAL_PI_PASSWORD`; prefer preconfigured SSH keys where possible.
- This repository contains orchestration and example code, not the VM disk images or trained model artifact.

## Project status

The repository documents a QEMU-emulated heterogeneous cluster. The same OpenMPI, SSH, hostfile, and workload concepts can be applied to a cluster of physical Raspberry Pis by replacing QEMU startup/network provisioning with the physical nodes' network configuration.
