#!/bin/bash

for iface in $(ls /sys/class/net/ | grep -E "^(eno|wlo|ens|wls|enp|wlp|eth)" | grep -vE "\."); do
    cat << EOF > /etc/systemd/network/10-${iface}.link
[Match]
MACAddress=$(cat /sys/class/net/${iface}/address)

[Link]
Name=${iface}
EOF
done

ls -althr /etc/systemd/network/
