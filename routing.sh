#!/usr/bin/env sh

## Input parameters.
{
	for var in \
		${LOCAL_IPS+}
	do eval : "\${$var:?}"; done
}

if [ "${LOCAL_IPS}" ]; then
	case "$( . /etc/os-release; echo ${ID} )" in
		## https://manpages.debian.org/ifupdown/interfaces.5.en.html
		## https://manpages.debian.org/ifupdown/ifup.8.en.html
		alpine)
			sudo install -m 755 /dev/stdin /etc/network/if-up.d/local.sh <<-EOF
				#!/bin/sh

				[ "\${IFACE}" = eth1 ] && {
					$( for ip in ${LOCAL_IPS}; do echo -e "\tip route add ${ip}/32 dev eth1"; done )
				}
				exit 0
			EOF
			sudo ifup --force --auto 2>/dev/null
		;;
		## https://netplan.readthedocs.io/en/stable/reference/
		## https://www.freedesktop.org/software/systemd/man/latest/systemd-networkd-wait-online.service.html
		ubuntu)
			sudo install --mode 644 /dev/stdin /etc/netplan/local.yaml <<-EOF
				network:
				  version: 2
				  ethernets:
				    eth1:
				      routes:
				$( for ip in ${LOCAL_IPS}; do echo "        - { to: ${ip}/32, scope: link }"; done )
			EOF
			sudo netplan apply; /usr/lib/systemd/systemd-networkd-wait-online
		;;
	esac
fi

ip route list

