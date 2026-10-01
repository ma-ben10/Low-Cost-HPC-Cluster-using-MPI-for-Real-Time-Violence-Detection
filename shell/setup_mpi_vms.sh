#!/bin/bash

VMS=$(sudo arp-scan --interface=br0 --localnet | grep -E "QEMU|Unknown" | awk '{print $1}')

for ip in $VMS; do
  echo "================================"
  echo "Setting up MPI on $ip..."
  echo "================================"

  # fix sources.list
  ssh pi@${ip} "sudo bash -c 'cat > /etc/apt/sources.list << EOF
deb http://archive.raspberrypi.com/debian/ bookworm main
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free
deb http://deb.debian.org/debian bookworm-updates main contrib non-free
EOF'"

  # update and install
  ssh pi@${ip} "sudo apt-get update && sudo apt-get install -y --fix-missing openmpi-bin libopenmpi-dev"

  # verify
  echo "MPI version on $ip:"
  ssh pi@${ip} "mpirun --version"
  echo "Done with $ip!"
done

echo "All VMs done!"
