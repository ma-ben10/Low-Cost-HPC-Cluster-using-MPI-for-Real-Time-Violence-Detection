#!/usr/bin/env bash
set -euo pipefail

# ── Config ────────────────────────────────────────────────
SSH_USER="pi"
REMOTE_DIR="/home/pi/violence_detection"
BRIDGE_IF="br0"

PY_FILE="distributed_inference.py"
MODEL_FILE="hybrid_model3_torchscript_final.pt"

SEPARATOR="=================================================="

# ── Guards ────────────────────────────────────────────────
if [[ ! -f "$PY_FILE" ]]; then
  echo "Error: $PY_FILE not found in current directory" >&2
  exit 1
fi

if [[ ! -f "$MODEL_FILE" ]]; then
  echo "Error: $MODEL_FILE not found in current directory" >&2
  exit 1
fi

# ── Discover QEMU VMs only ────────────────────────────────
echo ""
echo "$SEPARATOR"
echo "  Scanning $BRIDGE_IF for QEMU nodes..."
echo "$SEPARATOR"

VMS=$(sudo arp-scan --interface="$BRIDGE_IF" --localnet \
  | grep -i "QEMU" \
  | awk '{print $1}')

if [[ -z "$VMS" ]]; then
  echo "No QEMU VMs found on $BRIDGE_IF" >&2
  exit 1
fi

echo "Found nodes:"
for ip in $VMS; do
  echo "  → $ip"
done

# ── Deploy to each node ───────────────────────────────────
for ip in $VMS; do
  echo ""
  echo "$SEPARATOR"
  echo "  Deploying to $ip"
  echo "$SEPARATOR"

  # 1. Create remote directory
  echo "[$ip] Creating remote directory $REMOTE_DIR..."
  ssh -o StrictHostKeyChecking=no \
      -o ConnectTimeout=10 \
      "$SSH_USER@$ip" \
      "mkdir -p '$REMOTE_DIR'"

  # 2. Copy Python file
  echo "[$ip] Copying $PY_FILE..."
  scp -o StrictHostKeyChecking=no \
      "$PY_FILE" \
      "$SSH_USER@$ip":"$REMOTE_DIR/$PY_FILE"

  # 3. Copy model file (workers load it independently)
  echo "[$ip] Copying model $MODEL_FILE (this may take a while)..."
  scp -o StrictHostKeyChecking=no \
      "$MODEL_FILE" \
      "$SSH_USER@$ip":"$REMOTE_DIR/$MODEL_FILE"

  # 4. Install all required packages
  echo "[$ip] Installing required packages..."
  ssh -o StrictHostKeyChecking=no \
      "$SSH_USER@$ip" bash <<'ENDSSH'
    set -euo pipefail

    echo "  → Updating apt..."
    sudo apt-get update -qq

    echo "  → Installing system deps..."
    sudo apt-get install -y -qq \
      python3-pip \
      python3-dev \
      libopencv-dev \
      python3-opencv \
      libopenmpi-dev \
      openmpi-bin \
      libatlas-base-dev \
      libjpeg-dev \
      zlib1g-dev

    echo "  → Installing Python packages..."
    pip3 install --upgrade pip --quiet

    # mpi4py must match system OpenMPI
    pip3 install mpi4py --quiet

    # numpy
    pip3 install numpy --quiet

    # PyTorch for ARM (Raspberry Pi 3 → use lightweight wheel)
    pip3 install \
      --extra-index-url https://download.pytorch.org/whl/cpu \
      torch --quiet

    # opencv-python headless (no display needed on worker nodes)
    pip3 install opencv-python-headless --quiet

    echo "  → Verifying installs..."
    python3 -c "import mpi4py; import torch; import cv2; import numpy; print('All packages OK')"
ENDSSH

  echo "[$ip] Done ✓"
done

# ── Summary ───────────────────────────────────────────────
echo ""
echo "$SEPARATOR"
echo "  DEPLOYMENT COMPLETE"
echo "$SEPARATOR"
echo ""
echo "  Files deployed to all nodes:"
echo "    $REMOTE_DIR/$PY_FILE"
echo "    $REMOTE_DIR/$MODEL_FILE"
echo ""
echo "  To run the inference:"
echo ""
echo "  mpirun -np 5 \\"
echo "    --host 192.168.100.1,$(echo $VMS | tr ' ' ',') \\"
echo "    --mca btl_tcp_if_include 192.168.100.0/24 \\"
echo "    --mca oob_tcp_if_include 192.168.100.0/24 \\"
echo "    --mca plm_rsh_agent 'ssh -l pi' \\"
echo "    python3 $REMOTE_DIR/$PY_FILE /path/to/video.mp4"
echo ""
echo "$SEPARATOR"