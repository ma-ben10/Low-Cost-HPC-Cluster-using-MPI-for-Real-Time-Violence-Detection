#!/bin/bash
TAP_OWNER="${SUDO_USER:-$USER}"

# restore bridge IP
sudo ip addr add 192.168.100.1/24 dev br0 2>/dev/null
sudo ip link set br0 up

# restore TAPs
for i in 1 2 3 4; do
  sudo ip tuntap add tap${i} mode tap user "$TAP_OWNER" 2>/dev/null || \
  sudo ip tuntap change dev tap${i} mode tap user "$TAP_OWNER" 2>/dev/null
  sudo ip link set tap${i} up
  sudo ip link set tap${i} master br0
done

# restore iptables
sudo sysctl net.ipv4.ip_forward=1
sudo iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
sudo iptables -A FORWARD -i wlan0 -o br0 -j ACCEPT
sudo iptables -A FORWARD -i br0 -o wlan0 -j ACCEPT
sudo iptables -I INPUT -i br0 -p tcp --dport 22 -j ACCEPT
sudo iptables -I INPUT -i br0 -p udp --dport 67 -j ACCEPT
sudo iptables -I FORWARD -i br0 -j ACCEPT
sudo iptables -I FORWARD -o br0 -j ACCEPT

echo "Network setup done!"
