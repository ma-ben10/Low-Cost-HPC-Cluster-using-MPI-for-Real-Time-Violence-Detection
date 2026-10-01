#!/usr/bin/env bash
set -euo pipefail

MPI_BIN="/opt/openmpi/bin/mpirun"
MPI_PREFIX="/opt/openmpi"
MPI_ORTED="/opt/openmpi/bin/orted"
APPFILE="/home/amine/project_2CS/Pi3_slave/appfile"
BINARY="/home/amine/project_2CS/Pi3_slave/code/mpi_trap_pi"
PI_HOST="${PI_HOST:-192.168.100.42}"
PI_BINARY="/home/pi/Pi_estimation/mpi_trap_pi"
PI_RANKS=1
N_TRAPEZOIDS="${N_TRAPEZOIDS:-100000000}"

TMP_APPFILE="$(mktemp)"
trap 'rm -f "$TMP_APPFILE"' EXIT

if [[ ! -x "$MPI_BIN" ]]; then
  echo "Error: mpirun not found at $MPI_BIN" >&2
  exit 1
fi

if [[ ! -f "$APPFILE" ]]; then
  echo "Error: appfile not found: $APPFILE" >&2
  exit 1
fi

if [[ ! -x "$BINARY" ]]; then
  echo "Error: binary not found: $BINARY" >&2
  exit 1
fi

awk -v n="$N_TRAPEZOIDS" '
  /^#/ || /^[[:space:]]*$/ { print; next }
  { print $0, n }
' "$APPFILE" > "$TMP_APPFILE"

SEPARATOR="=================================================="

# ── 1. Run on FULL CLUSTER ────────────────────────────────
echo ""
echo "$SEPARATOR"
echo "  RUNNING ON FULL CLUSTER (all nodes)"
echo "$SEPARATOR"

CLUSTER_OUTPUT=$( "$MPI_BIN" \
  --prefix "$MPI_PREFIX" \
  --mca orte_launch_agent "$MPI_ORTED" \
  --mca plm_rsh_agent 'ssh -l pi' \
  --mca oob_tcp_if_include 192.168.100.0/24 \
  --mca btl_tcp_if_include 192.168.100.0/24 \
  --mca orte_hetero_nodes 1 \
  --oversubscribe \
  --app "$TMP_APPFILE")

echo "$CLUSTER_OUTPUT"

CLUSTER_TIME=$(echo "$CLUSTER_OUTPUT" | grep "Wall time" | awk '{print $4}')

# ── 2. Run on ONE RPI NODE ONLY ──────────────────────────
echo ""
echo "$SEPARATOR"
echo "  RUNNING ON ONE RPI NODE ONLY ($PI_HOST, $PI_RANKS rank)"
echo "$SEPARATOR"

RPI_OUTPUT=$(ssh -l pi "$PI_HOST" \
  "cd /home/pi/Pi_estimation && $MPI_BIN --prefix $MPI_PREFIX --oversubscribe --host localhost:$PI_RANKS -np $PI_RANKS ./mpi_trap_pi $N_TRAPEZOIDS")

echo "$RPI_OUTPUT"

RPI_TIME=$(echo "$RPI_OUTPUT" | grep "Wall time" | awk '{print $4}')

# ── 3. Compute speedup ───────────────────────────────────
echo ""
echo "$SEPARATOR"
echo "  BENCHMARK RESULTS"
echo "$SEPARATOR"
echo "  One RPI only  : ${RPI_TIME} seconds"
echo "  Full cluster : ${CLUSTER_TIME} seconds"
echo ""

SPEEDUP=$(awk "BEGIN { printf \"%.2f\", $RPI_TIME / $CLUSTER_TIME }")

echo "  Speedup factor = $RPI_TIME / $CLUSTER_TIME ≈ ${SPEEDUP}×"
echo "$SEPARATOR"
echo ""