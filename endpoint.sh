#!/bin/sh

set -e
test "$(id -u)" = "0" || { echo "run as root please (or create a userns)" >&2; exit 1; }

. ./vars.sh

case "$1" in
	a|b)	endpoint="$1"
		;;
	*)	echo 'add "a" or "b" as command line arg to select endpoint' >&2
		exit 1
		;;
esac

test -e /sys/class/net/bridge_$endpoint || { echo "bridge missing" >&2; exit 1; }

cleanup() {
	set +e
	echo "end of script, trying to not leave a mess..." >&2
	sleep 0.1
	ip netns del "$endpoint"
}

trap cleanup EXIT
set -x

eval "peer=\${peer_$endpoint}"
eval "underlay_self=\${underlay_$endpoint}"
eval "underlay_peer=\${underlay_$peer}"
eval "ingresslbl_self=\${ingresslbl_$endpoint}"
eval "ingresslbl_peer=\${ingresslbl_$peer}"
eval "core_self=\${core_$endpoint}"
eval "corelbl_self=\${corelbl_$endpoint}"

ip netns add "$endpoint"
ip -n "$endpoint" link set lo up
echo 1048575 | ip netns exec $endpoint tee /proc/sys/net/mpls/platform_labels
echo 1 | ip netns exec $endpoint tee /proc/sys/net/mpls/conf/lo/input

ip link add name "${endpoint}_core" type veth peer netns "$endpoint" name "core"
# turn off ipv6 on veth *outside* netns, generates noise otherwise
echo 1 > "/proc/sys/net/ipv6/conf/${endpoint}_core/disable_ipv6"
ip link set "${endpoint}_core" mtu 1700 master bridge_$endpoint up

ip link add name "${endpoint}_edge" type veth peer netns "$endpoint" name "edge"
ip link set "${endpoint}_edge" address "00:80:41:${endpoint}:ee:ee" up
echo 1 | ip netns exec $endpoint tee "/proc/sys/net/ipv6/conf/edge/disable_ipv6"
ip -n $endpoint link add name bridge0 type bridge stp 0 \
	mcast_snooping 0 mcast_vlan_snooping 0 mcast_querier 0 \
	nf_call_iptables 0 nf_call_ip6tables 0 nf_call_arptables 0 \
	#
ip -n $endpoint link set edge master bridge0 up
ip -n $endpoint link set bridge0 address "00:80:41:${endpoint}:bb:bb" up

ip -n $endpoint link set core mtu 1700 up
echo 1 | ip netns exec $endpoint tee /proc/sys/net/mpls/conf/core/input
ip -n $endpoint addr add ${underlay_self}/24 dev core
ip -n $endpoint link add name gretap type gretap local ${underlay_self} remote ${underlay_peer} ttl 64
echo 1 | ip netns exec $endpoint tee /proc/sys/net/mpls/conf/gretap/input
ip -n $endpoint link set gretap mtu 1500 master bridge0 up

# decap: 1001/1002 popped and rerouted to lo where it'll reach the gretap device
ip -n $endpoint -f mpls route add ${ingresslbl_self} dev lo

# encap: gretap sends to IP, IP route lookup adds stack of 2 MPLS labels e.g. (9901/1002)
ip -n $endpoint route add ${underlay_peer} encap mpls ${corelbl_self}/${ingresslbl_peer} via inet ${core_self}

echo "===== state ====="
ip -n $endpoint addr list core
ip -n $endpoint -d addr list gretap
bridge -n $endpoint link
ip -n $endpoint -4 route list
ip -n $endpoint -f mpls route list
ip netns exec "$endpoint" "$SHELL"
