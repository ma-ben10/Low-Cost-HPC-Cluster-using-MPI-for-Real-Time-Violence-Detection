#!/bin/bash

VMS=$(sudo arp-scan --interface=br0 --localnet | grep -E "QEMU|Unknown" | awk '{print $1}')
echo "Found VMs: $VMS"

[ -f ~/.ssh/id_rsa ] || ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa

for ip in $VMS; do
  echo "=== Setting up VM $ip ==="

  ssh pi@${ip} "mkdir -p ~/.ssh && cat > ~/.ssh/config << 'EOF'
Host 192.168.100.*
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    User pi
EOF
chmod 600 ~/.ssh/config"

  ssh pi@${ip} "[ -f ~/.ssh/id_rsa ] || ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa"
  ssh-copy-id -i ~/.ssh/id_rsa.pub pi@${ip}

  VM_KEY=$(ssh pi@${ip} "cat ~/.ssh/id_rsa.pub")

  # add VM key to itself
  ssh pi@${ip} "echo '$VM_KEY' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

  for target in $VMS; do
    if [ "$target" != "$ip" ]; then
      echo "  → copying $ip key to $target"
      ssh pi@${target} "echo '$VM_KEY' >> ~/.ssh/authorized_keys"
    fi
  done

  echo "$VM_KEY" >> ~/.ssh/authorized_keys
  echo "Done $ip!"
done

echo "================================"
echo "Testing SSH between all VMs..."
for ip in $VMS; do
  for target in $VMS; do
    if [ "$ip" != "$target" ]; then
      result=$(ssh pi@${ip} "ssh pi@${target} hostname 2>/dev/null || echo FAILED")
      echo "  $ip → $target: $result"
    fi
  done
done

echo "All done! 🚀"