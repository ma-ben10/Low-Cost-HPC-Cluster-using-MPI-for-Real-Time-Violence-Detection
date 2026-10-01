#!/usr/bin/env bash
set -euo pipefail

GOLDEN_IP="192.168.100.24"
USER_NAME="pi"
TARGETS=("$@")

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "Usage: $0 <target-ip> [target-ip ...]"
  echo "Example: $0 192.168.100.32 192.168.100.43 192.168.100.45"
  exit 1
fi

WORKDIR="/tmp/vm_clone_${GOLDEN_IP//./_}"
mkdir -p "$WORKDIR"
PKG_FILE="$WORKDIR/golden_packages.txt"

echo "[0/6] Reading package list from golden VM ${GOLDEN_IP}..."
ssh "${USER_NAME}@${GOLDEN_IP}" "dpkg-query -W -f='\${binary:Package}\n' | sort -u" > "$PKG_FILE"

for ip in "${TARGETS[@]}"; do
  echo
  echo "================ ${ip} ================"

  if ! ping -c1 -W1 "$ip" >/dev/null 2>&1; then
    echo "Skip ${ip}: ping failed"
    continue
  fi

  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${USER_NAME}@${ip}" 'echo ssh_ok' >/dev/null 2>&1; then
    echo "Skip ${ip}: ssh failed"
    continue
  fi

  echo "[1/6] Fix hostname resolution warning (sudo)..."
  ssh "${USER_NAME}@${ip}" '
    set -e
    h=$(hostname)
    if ! grep -q "127.0.1.1[[:space:]]\+$h" /etc/hosts; then
      echo "127.0.1.1 $h" | sudo tee -a /etc/hosts >/dev/null
    fi
  '

  echo "[2/6] Install missing packages to match golden VM (can take time)..."
  scp -q "$PKG_FILE" "${USER_NAME}@${ip}:/tmp/golden_packages.txt"
  ssh "${USER_NAME}@${ip}" '
    set -e
    sudo apt-get update -qq
    dpkg-query -W -f="${binary:Package}\n" | sort -u > /tmp/current_packages.txt
    comm -23 /tmp/golden_packages.txt /tmp/current_packages.txt > /tmp/missing_packages.txt || true
    if [[ -s /tmp/missing_packages.txt ]]; then
      sudo xargs -a /tmp/missing_packages.txt apt-get install -y
    else
      echo "No missing packages"
    fi
    rm -f /tmp/current_packages.txt /tmp/missing_packages.txt /tmp/golden_packages.txt
  '

  echo "[3/6] Clone /opt/openmpi from golden VM..."
  ssh "${USER_NAME}@${GOLDEN_IP}" 'tar -C / -cf - opt/openmpi' \
    | ssh "${USER_NAME}@${ip}" 'sudo rm -rf /opt/openmpi && sudo tar -C / -xf -'

  echo "[4/6] Clone /home/pi files from golden VM..."
  ssh "${USER_NAME}@${GOLDEN_IP}" 'tar -C /home/pi --exclude=.cache --exclude=.local/share/Trash -cf - .' \
    | ssh "${USER_NAME}@${ip}" 'mkdir -p /home/pi && tar -C /home/pi -xf -'

  echo "[5/6] Ensure MPI env and config are present..."
  ssh "${USER_NAME}@${ip}" '
    set -e
    sudo ln -sf /opt/openmpi/bin/mpirun /usr/local/bin/mpirun
    sudo ln -sf /opt/openmpi/bin/ompi_info /usr/local/bin/ompi_info
    sudo ln -sf /opt/openmpi/bin/mpicc /usr/local/bin/mpicc

    mkdir -p ~/.openmpi
    cat > ~/.openmpi/mca-params.conf <<"EOF"
btl = self,tcp
btl_tcp_if_include = 192.168.100.0/24
oob_tcp_if_include = 192.168.100.0/24
plm_rsh_no_tree_spawn = 1
EOF

    if ! grep -q "# >>> OPENMPI_CUSTOM >>>" ~/.bashrc 2>/dev/null; then
      cat >> ~/.bashrc <<"EOF"

# >>> OPENMPI_CUSTOM >>>
export MPI_HOME=/opt/openmpi
export PATH="$MPI_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$MPI_HOME/lib:${LD_LIBRARY_PATH:-}"
# <<< OPENMPI_CUSTOM <<<
EOF
    fi
  '

  echo "[6/6] Verify OpenMPI on ${ip}..."
  ssh "${USER_NAME}@${ip}" '/opt/openmpi/bin/mpirun --version | head -n1'

  echo "Done ${ip}"
done

echo
echo "Clone operation completed for requested targets."
