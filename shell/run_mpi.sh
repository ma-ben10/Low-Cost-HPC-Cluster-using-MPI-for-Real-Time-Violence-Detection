#!/usr/bin/env bash
set -euo pipefail

MPI_BIN="/opt/openmpi/bin/mpirun"
MPI_PREFIX="/opt/openmpi"
MPI_ORTED="/opt/openmpi/bin/orted"
DEFAULT_APPFILE="/home/amine/project_2CS/Pi3_slave/appfile"

APPFILE="${1:-$DEFAULT_APPFILE}"

# NOTE: If you need to tweak PMIx/OpenMPI compression MCA params,
# export PMIX_MCA_pcompress / OMPI_MCA_compress *before* calling this
# script. We do not force any defaults here to avoid selecting
# non-existent components.

if [[ ! -x "$MPI_BIN" ]]; then
  echo "Error: mpirun not found at $MPI_BIN" >&2
  exit 1
fi

if [[ ! -f "$APPFILE" ]]; then
  echo "Error: appfile not found: $APPFILE" >&2
  exit 1
fi

exec "$MPI_BIN" \
  --prefix "$MPI_PREFIX" \
  --mca orte_launch_agent "$MPI_ORTED" \
  --mca plm_rsh_agent 'ssh -l pi' \
  --mca oob_tcp_if_include 192.168.100.0/24 \
  --mca btl_tcp_if_include 192.168.100.0/24 \
  --mca orte_hetero_nodes 1 \
  --oversubscribe \
  --app "$APPFILE"
