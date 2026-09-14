#!/bin/sh
# Install or update pstad on one repeater: sh install.sh <repeater-host>, e.g. repeater.local
set -e
host=${1:?usage: install.sh <repeater-host>}
dir=$(dirname "$0")

ssh "root@$host" 'opkg list-installed | grep -q "^tc-full " || { opkg update && opkg install tc-full kmod-sched-core kmod-sched-flower ip-bridge; }'
# The redirect is the whole mechanism; stop here if the kernel cannot do it.
ssh "root@$host" 'modprobe act_mirred; modprobe cls_flower; lsmod | grep -q "^act_mirred" && lsmod | grep -q "^cls_flower" && echo "mirred and flower loaded"'

[ -f "$dir/pstad" ] || { echo "packages only: no pstad beside install.sh"; exit 0; }
# -O: OpenWrt's dropbear ships no sftp-server, so scp's default SFTP mode fails.
scp -O "$dir/pstad" "root@$host:/usr/sbin/pstad"
scp -O "$dir/pstad.init" "root@$host:/etc/init.d/pstad"
ssh "root@$host" 'chmod 755 /usr/sbin/pstad /etc/init.d/pstad; mkdir -p /etc/psta; touch /etc/psta/allow; /etc/init.d/pstad enable; /etc/init.d/pstad restart'
