#!/usr/bin/env bash
set -euo pipefail

GOLDEN_IP="192.168.100.24"
USER_NAME="pi"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <target-ip> [target-ip ...]"
  echo "Example: $0 192.168.100.32 192.168.100.43 192.168.100.45"
  exit 1
fi

for ip in "$@"; do
  echo "===== Syncing ${ip} from ${GOLDEN_IP} ====="

  if ! ping -c1 -W1 "$ip" >/dev/null 2>&1; then
    echo "SKIP ${ip}: ping failed"
    continue
  fi

  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${USER_NAME}@${ip}" 'echo ssh_ok' >/dev/null 2>&1; then
    echo "SKIP ${ip}: SSH failed"
    continue
  fi

  # Stream-copy /opt/openmpi directly (no tar file left on golden VM)
  ssh "${USER_NAME}@${GOLDEN_IP}" 'tar -C / -cf - opt/openmpi' \
    | ssh "${USER_NAME}@${ip}" 'sudo rm -rf /opt/openmpi && sudo tar -C / -xf -'

  # Runtime config
  ssh "${USER_NAME}@${ip}" 'mkdir -p ~/.openmpi && cat > ~/.openmpi/mca-params.conf <<"EOF"
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
/opt/openmpi/bin/mpirun --version | head -n1'

  echo "DONE ${ip}"
done

echo "All requested targets processed."