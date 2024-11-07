#!/bin/sh

set -e
test "$(id -u)" = "0" || { echo "run as root please (or create a userns)" >&2; exit 1; }

. ./vars.sh

endpoint=core

test -e /sys/class/net/bridge_a || { echo "bridge missing" >&2; exit 1; }
test -e /sys/class/net/bridge_b || { echo "bridge missing" >&2; exit 1; }

cleanup() {
	set +e
	echo "end of script, trying to not leave a mess..." >&2
	sleep 0.1
	ip netns del "$endpoint"
}

trap cleanup EXIT
set -x

ip netns add "$endpoint"
ip -n "$endpoint" link set lo up
echo 1048575 | ip netns exec $endpoint tee /proc/sys/net/mpls/platform_labels
echo 1 | ip netns exec $endpoint tee /proc/sys/net/mpls/conf/lo/input

for n in a b; do
	dev="core_$n"
	outer="${n}_core_i"
	eval "peer=\${peer_$n}"
	eval "addr=\${core_$n}"

	ip link add name "$outer" type veth peer netns "$endpoint" name "$dev"
	# turn off ipv6 on veth *outside* netns, generates noise otherwise
	echo 1 > "/proc/sys/net/ipv6/conf/${outer}/disable_ipv6"
	ip link set "${outer}" mtu 1700 master bridge_$n up

	ip -n "$endpoint" link set "$dev" up
	echo 1 | ip netns exec $endpoint tee /proc/sys/net/mpls/conf/$dev/input

	ip -n "$endpoint" addr add $addr/24 dev $dev
done

for n in a b; do
	eval "peer=\${peer_$n}"
	eval "ingresslbl=\${corelbl_$n}"
	eval "egressaddr=\${underlay_$peer}"

	# this will pop 9901/9902 off the stack, and there will be 1001/1002 left
	ip -n "$endpoint" -f mpls route add $ingresslbl via \
		inet $egressaddr dev core_$peer
done

echo "===== state ====="
ip -n $endpoint addr list
ip -n $endpoint -4 route list
ip -n $endpoint -f mpls route list
ip netns exec "$endpoint" "$SHELL"
