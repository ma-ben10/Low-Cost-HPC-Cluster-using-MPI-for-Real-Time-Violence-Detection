#!/bin/bash
VMS="192.168.100.41 192.168.100.42 192.168.100.43 192.168.100.10"

for ip in $VMS; do
  echo "================================"
  echo "Upgrading MPI on $ip..."
  echo "================================"
  ssh pi@${ip} << 'EOF'
    echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf
    cd ~
    wget -q https://download.open-mpi.org/release/open-mpi/v5.0/openmpi-5.0.6.tar.gz
    tar -xzf openmpi-5.0.6.tar.gz
    cd openmpi-5.0.6
    ./configure --prefix=/usr/local 2>&1 | tail -5
    make -j4 2>&1 | tail -5
    sudo make install 2>&1 | tail -5
    sudo ldconfig
    echo "Done! Version:"
    /usr/local/bin/mpirun --version
EOF
  echo "Finished $ip!"
done
