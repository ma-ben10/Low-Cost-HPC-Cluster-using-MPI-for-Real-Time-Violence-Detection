#!/usr/bin/env bash
set -euo pipefail

# Sync ARM OpenMPI runtime from one discovered running Pi node into shared NFS root.
# Result: every netbooted node gets the same OpenMPI without per-node install.
#
# Usage:
#   ./shell/sync_openmpi_to_nfs_root.sh [nfs-root]
# Example:
#   ./shell/sync_openmpi_to_nfs_root.sh /exports/pi3-root

NFS_ROOT="${1:-/exports/pi3-root}"
SSH_USER="pi"
MPI_PREFIX="/opt/openmpi"
ARP_IFACE="br1"
OPENMPI_APT_VERSION="${OPENMPI_APT_VERSION:-}"

if ! command -v arp-scan >/dev/null 2>&1; then
  echo "Error: arp-scan is required but not installed." >&2
  exit 1
fi

if [[ ! -d "$NFS_ROOT" ]]; then
  echo "Error: NFS root not found: $NFS_ROOT" >&2
  exit 1
fi

# Discover active node IPs on br1 and exclude the master interface IP.
MASTER_IP=$(ip -4 -o addr show "$ARP_IFACE" | awk '{print $4}' | cut -d/ -f1 | head -n1)
if [[ -z "$MASTER_IP" ]]; then
  echo "Error: could not determine master IP on ${ARP_IFACE}" >&2
  exit 1
fi

mapfile -t NODE_IPS < <(
  sudo arp-scan --interface="$ARP_IFACE" --localnet \
    | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print $1}' \
    | grep -v "^${MASTER_IP}$" \
    | sort -u
)

if [[ ${#NODE_IPS[@]} -eq 0 ]]; then
  echo "Error: no node IPs discovered on ${ARP_IFACE}" >&2
  exit 1
fi

# Pick first SSH-reachable node (used for bootstrap if needed).
FIRST_REACHABLE_IP=""
for ip in "${NODE_IPS[@]}"; do
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${ip}" 'echo ssh_ok' >/dev/null 2>&1; then
    FIRST_REACHABLE_IP="$ip"
    break
  fi
done

if [[ -z "$FIRST_REACHABLE_IP" ]]; then
  echo "Error: discovered nodes exist, but none are SSH reachable" >&2
  exit 1
fi

# Pick the first reachable node that has /opt/openmpi/bin/mpirun as source.
SRC_IP=""
for ip in "${NODE_IPS[@]}"; do
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${ip}" "test -x ${MPI_PREFIX}/bin/mpirun" >/dev/null 2>&1; then
    SRC_IP="$ip"
    break
  fi
done

if [[ -z "$SRC_IP" ]]; then
  echo "No node has ${MPI_PREFIX}/bin/mpirun yet."
  echo "Bootstrapping OpenMPI on ${FIRST_REACHABLE_IP} (shared NFS root)..."

  if [[ -n "$OPENMPI_APT_VERSION" ]]; then
    ssh "${SSH_USER}@${FIRST_REACHABLE_IP}" "sudo apt-get update && sudo apt-get install -y \
      openmpi-bin=${OPENMPI_APT_VERSION} \
      libopenmpi-dev=${OPENMPI_APT_VERSION} \
      libopenmpi3=${OPENMPI_APT_VERSION} \
      openmpi-common=${OPENMPI_APT_VERSION}"
  else
    ssh "${SSH_USER}@${FIRST_REACHABLE_IP}" "sudo apt-get update && sudo apt-get install -y openmpi-bin libopenmpi-dev libopenmpi3 openmpi-common"
  fi

  # Project launcher expects /opt/openmpi/bin/* ; provide compatibility links.
  ssh "${SSH_USER}@${FIRST_REACHABLE_IP}" 'set -euo pipefail
sudo mkdir -p /opt/openmpi/bin /opt/openmpi/lib
sudo ln -sf "$(command -v mpirun)" /opt/openmpi/bin/mpirun
sudo ln -sf "$(command -v mpicc)" /opt/openmpi/bin/mpicc
sudo ln -sf "$(command -v orted)" /opt/openmpi/bin/orted
libdir=$(dirname "$(ldconfig -p | awk "/libmpi\.so/{print \$NF; exit}")")
if [[ -n "${libdir:-}" ]]; then
  sudo ln -snf "$libdir" /opt/openmpi/lib
fi'

  SRC_IP="$FIRST_REACHABLE_IP"
fi

NETWORK_CIDR=$(ip -4 -o addr show "$ARP_IFACE" | awk '{print $4}' | head -n1)

echo "Discovered nodes on ${ARP_IFACE}: ${NODE_IPS[*]}"
echo "Selected source node: ${SRC_IP}"
echo "Source node OpenMPI version:"
ssh "${SSH_USER}@${SRC_IP}" "${MPI_PREFIX}/bin/mpirun --version | head -n1"

# PMIx compression parity check (required to avoid runtime decompression errors).
if ! ssh "${SSH_USER}@${SRC_IP}" "test -f ${MPI_PREFIX}/lib/pmix/mca_pcompress_zlib.so"; then
  echo "Error: source node ${SRC_IP} is missing PMIx zlib compression component:" >&2
  echo "       ${MPI_PREFIX}/lib/pmix/mca_pcompress_zlib.so" >&2
  echo "Fix: install zlib dev on source node and rebuild OpenMPI with same flags as master." >&2
  exit 1
fi

echo "Syncing ${MPI_PREFIX} from ${SRC_IP} to ${NFS_ROOT}${MPI_PREFIX} ..."
sudo mkdir -p "${NFS_ROOT}/opt"

# Atomic-ish update: stream into temporary dir then swap.
TMP_DIR="${NFS_ROOT}/opt/.openmpi_sync_$$"
sudo rm -rf "$TMP_DIR"
sudo mkdir -p "$TMP_DIR"

ssh "${SSH_USER}@${SRC_IP}" "tar -C /opt -cf - openmpi" \
  | sudo tar -C "$TMP_DIR" -xf -

if [[ ! -x "$TMP_DIR/openmpi/bin/mpirun" ]]; then
  echo "Error: synced payload missing mpirun" >&2
  exit 1
fi

sudo rm -rf "${NFS_ROOT}${MPI_PREFIX}.prev"
if [[ -d "${NFS_ROOT}${MPI_PREFIX}" ]]; then
  sudo mv "${NFS_ROOT}${MPI_PREFIX}" "${NFS_ROOT}${MPI_PREFIX}.prev"
fi
sudo mv "$TMP_DIR/openmpi" "${NFS_ROOT}${MPI_PREFIX}"
sudo rmdir "$TMP_DIR" 2>/dev/null || true

# Ensure all netboot nodes get PATH/LD_LIBRARY_PATH automatically.
sudo mkdir -p "${NFS_ROOT}/etc/profile.d"
sudo tee "${NFS_ROOT}/etc/profile.d/openmpi.sh" >/dev/null <<'EOF'
export MPI_HOME=/opt/openmpi
export PATH="$MPI_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$MPI_HOME/lib:${LD_LIBRARY_PATH:-}"
EOF

# Keep OpenMPI MCA config aligned with project network conventions.
sudo mkdir -p "${NFS_ROOT}/home/pi/.openmpi"
sudo tee "${NFS_ROOT}/home/pi/.openmpi/mca-params.conf" >/dev/null <<'EOF'
btl = self,tcp
oob_tcp_if_include = __NETWORK_CIDR__
btl_tcp_if_include = __NETWORK_CIDR__
plm_rsh_no_tree_spawn = 1
EOF
sudo sed -i "s|__NETWORK_CIDR__|${NETWORK_CIDR}|g" "${NFS_ROOT}/home/pi/.openmpi/mca-params.conf"
sudo chown -R 1000:1000 "${NFS_ROOT}/home/pi/.openmpi" "${NFS_ROOT}/etc/profile.d/openmpi.sh" 2>/dev/null || true

echo "Done. Shared NFS OpenMPI is now at ${NFS_ROOT}${MPI_PREFIX}."
echo "MCA network include set to ${NETWORK_CIDR}."
echo "Node verification (best effort):"
for ip in "${NODE_IPS[@]}"; do
  if ssh -o BatchMode=yes -o ConnectTimeout=4 "${SSH_USER}@${ip}" "${MPI_PREFIX}/bin/mpirun --version | head -n1" >/dev/null 2>&1; then
    ver=$(ssh -o BatchMode=yes -o ConnectTimeout=4 "${SSH_USER}@${ip}" "${MPI_PREFIX}/bin/mpirun --version | head -n1")
    echo "  ${ip}: ${ver}"
  else
    echo "  ${ip}: SSH/unreachable right now"
  fi
done
echo "Reboot/restart netboot nodes to pick up this exact runtime."
