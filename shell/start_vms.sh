#!/bin/bash
BASE=$HOME/project_2CS/Pi3_slave/images

for i in $(seq 1 4); do
  MAC="52:54:00:00:00:0${i}"
  qemu-system-aarch64 \
    -machine raspi3b \
    -cpu cortex-a53 \
    -m 1024 \
    -kernel $BASE/kernel8_64.img \
    -dtb $BASE/bcm2710-rpi-3-b_64.dtb \
    -drive format=raw,file=$BASE/vm${i}_64.img \
    -append "console=ttyAMA0 root=/dev/mmcblk0p2 rw rootwait" \
    -netdev tap,id=net0,ifname=tap${i},script=no,downscript=no\
    -device usb-net,netdev=net0,mac=${MAC}\
    -no-reboot -display none -daemonize
  echo "VM${i} started with TAP tap${i} MAC ${MAC}"
done
