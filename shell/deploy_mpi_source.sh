#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  cat <<'EOF'
Usage: ./deploy_mpi_source.sh <source.c> <remote-folder>
  <source.c>      Path to the C source file to deploy (will be compiled with mpicc)
  <remote-folder> Folder name to create under /home/pi on every VM
Example:
  ./deploy_mpi_source.sh mpi_trap_pi.c mpi_practice
EOF
  exit 1
fi

SOURCE_FILE=$1
REMOTE_FOLDER_NAME=$2
REMOTE_ROOT="/home/pi/${REMOTE_FOLDER_NAME}"
REMOTE_COMPILER="/opt/openmpi/bin/mpicc"

if [[ ! -f "$SOURCE_FILE" ]]; then
  echo "Source file not found: $SOURCE_FILE" >&2
  exit 1
fi

if [[ -z "$REMOTE_FOLDER_NAME" ]]; then
  echo "Remote folder name cannot be empty" >&2
  exit 1
fi

BASENAME=$(basename "$SOURCE_FILE")
OUTPUT_NAME="${BASENAME%.c}"

if [[ "$OUTPUT_NAME" == "$BASENAME" ]]; then
  echo "Warning: source file does not end in .c; output binary will be named '$OUTPUT_NAME'" >&2
fi

# Discover VM IPs (same heuristic as other project scripts)
VMS=$(sudo arp-scan --interface=br0 --localnet | grep -E "QEMU|Raspberry|52:54|(Unknown: locally administered)" | awk '{print $1}')

if [[ -z "$VMS" ]]; then
  echo "No VMs detected on br0" >&2
  exit 1
fi

echo "Deploying $SOURCE_FILE to: $VMS"

for ip in $VMS; do
  echo "================ $ip ================"

  # Ensure remote directory exists and is clean
  ssh pi@"$ip" "set -euo pipefail; mkdir -p '$REMOTE_ROOT' && rm -f '$REMOTE_ROOT/$BASENAME'"

  # Copy the source file
  scp "$SOURCE_FILE" pi@"$ip":"$REMOTE_ROOT/$BASENAME"

  # Compile remotely inside the folder
  ssh pi@"$ip" "set -euo pipefail; cd '$REMOTE_ROOT' && \"$REMOTE_COMPILER\" -O2 -std=c11 '$BASENAME' -o '$OUTPUT_NAME'"

  echo "Done $ip: source stored in $REMOTE_ROOT and binary '$OUTPUT_NAME' built"
done

echo "Deployment complete."
