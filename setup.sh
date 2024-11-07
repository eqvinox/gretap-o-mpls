#!/bin/sh

set -e
test "$(id -u)" = "0" || { echo "run as root please (or create a userns)" >&2; exit 1; }

for n in a b; do
	ip link add name bridge_$n type bridge stp 0 \
		mcast_snooping 0 mcast_vlan_snooping 0 mcast_querier 0 \
		nf_call_iptables 0 nf_call_ip6tables 0 nf_call_arptables 0 \
		#
	echo 1 > "/proc/sys/net/ipv6/conf/bridge_$n/disable_ipv6"
	ip link set bridge_$n mtu 1700 up
done

cat <<EOF
bridges created to interconnect things.  now run:

./endpoint.sh a
./endpoint.sh b
./core.sh

wireshark -kSi bridge_a

ping6 ff02::1%a_edge

EOF
