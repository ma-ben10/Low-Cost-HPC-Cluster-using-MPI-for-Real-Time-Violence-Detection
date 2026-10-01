#!/bin/bash

# get all current VM IPs automatically
VMS=$(sudo arp-scan --interface=br0 --localnet | grep -E "QEMU|Unknown" | awk '{print $1}')
INITIAL_PI_PASSWORD="${INITIAL_PI_PASSWORD:-}"

echo "Found nodes: $VMS"

# generate Dell key if not exists
[ -f ~/.ssh/id_rsa ] || ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa

for ip in $VMS; do
  echo "=== Configuring node $ip ==="

  # 1. copy Dell key to VM (using sshpass for first time)
  if [[ -n "$INITIAL_PI_PASSWORD" ]]; then
    sudo pacman -S sshpass --noconfirm 2>/dev/null
    sshpass -p "$INITIAL_PI_PASSWORD" ssh-copy-id -o StrictHostKeyChecking=no pi@${ip} 2>/dev/null
  fi
  ssh-copy-id -o StrictHostKeyChecking=no pi@${ip} 2>/dev/null

  # 2. disable strict host checking on VM
  ssh -o StrictHostKeyChecking=no pi@${ip} "mkdir -p ~/.ssh && cat > ~/.ssh/config << 'EOF'
Host 192.168.100.*
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    User pi
EOF
chmod 600 ~/.ssh/config"

  # 3. generate key on VM
  ssh pi@${ip} "[ -f ~/.ssh/id_rsa ] || ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa"

  # 4. get VM public key
  VM_KEY=$(ssh pi@${ip} "cat ~/.ssh/id_rsa.pub")

  # 5. add VM key to Dell
  echo "$VM_KEY" >> ~/.ssh/authorized_keys

  # 6. distribute VM key to ALL other VMs
  for target in $VMS; do
    if [ "$target" != "$ip" ]; then
      ssh pi@${target} "echo '$VM_KEY' >> ~/.ssh/authorized_keys" 2>/dev/null
    fi
  done

  # 7. set hostname based on IP
  LAST=$(echo $ip | cut -d. -f4)
  ssh pi@${ip} "sudo hostnamectl set-hostname rasp${LAST}"

  # 8. configure MCA params
  ssh pi@${ip} "mkdir -p ~/.openmpi && cat > ~/.openmpi/mca-params.conf << 'EOF'
routed = direct
btl = self,tcp
plm_rsh_no_tree_spawn = 1
btl_tcp_if_include = 192.168.100.0/24
oob_tcp_if_include = 192.168.100.0/24
EOF"

  echo "Node $ip configured!"
done

# update hostfile on Dell
echo "Updating hostfile..."
> ~/project_2CS/Pi3_slave/hostfile
echo "192.168.100.1 slots=4" >> ~/project_2CS/Pi3_slave/hostfile
for ip in $VMS; do
  echo "$ip slots=4" >> ~/project_2CS/Pi3_slave/hostfile
done

echo "================================"
echo "Hostfile updated:"
cat ~/project_2CS/Pi3_slave/hostfile

echo "================================"
echo "Testing SSH between all nodes..."
for ip in $VMS; do
  for target in $VMS; do
    if [ "$ip" != "$target" ]; then
      result=$(ssh pi@${ip} "ssh pi@${target} hostname 2>/dev/null || echo FAILED")
      echo "  $ip → $target: $result"
    fi
  done
done

echo "All nodes configured! Run add_node.sh anytime you add a new VM! 🚀"
