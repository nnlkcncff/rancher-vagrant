#!/usr/bin/env sh

## Input parameters.
{
	for var in \
		${DNS_TLD+} ${DNS_RESOURCE_RECORDS} ${DNS_FORWARDER+} ${DNS_IP+}
	do eval : "\${$var:?}"; done
}

## https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html
if [ "${DNS_RESOURCE_RECORDS}" ]; then
	echo "${DNS_RESOURCE_RECORDS}" | sudo install -D -m 644 /dev/stdin "/etc/dnsmasq.d/resource_records.conf"
	sudo apk --quiet add dnsmasq
	grep -q 127.0.0.1 /etc/resolv.conf || {
		sudo install -m 644 /dev/stdin /etc/dnsmasq.d/forwarder.conf <<-EOF
			$(
				ips=${DNS_FORWARDER:-"$( while read line; do case "${line}" in nameserver*) echo "${line#* }" ;; esac; done < /etc/resolv.conf )"}
				for ip in ${ips}; do echo "server=${ip}"; done
			)
		EOF

		echo nameserver 127.0.0.1 | sudo install /dev/stdin /etc/resolv.conf && sudo chattr +i /etc/resolv.conf
	}
	sudo rc-update add dnsmasq && sudo rc-service dnsmasq restart
	sed -E 's|address=/([^/]+)/([^ ]+)|\2 \1|' "/etc/dnsmasq.d/resource_records.conf"

	## https://man.openbsd.org/sshd_config#AllowTcpForwarding
	## https://man.openbsd.org/ssh_config#DynamicForward
	echo 'AllowTcpForwarding yes' | sudo install -m 644 /dev/stdin /etc/ssh/sshd_config.d/socks.conf && sudo rc-service sshd restart
fi

## https://www.freedesktop.org/software/systemd/man/latest/systemd-resolved.service.html
## https://netplan.readthedocs.io/en/stable/netplan-yaml/#dhcp-overrides
if [ "${DNS_IP}" ]; then
	sudo install -D --mode 644 /dev/stdin "/etc/systemd/resolved.conf.d/${DNS_TLD}.conf" <<-EOF
		[Resolve]
		DNS=${DNS_IP}
		Domains=${DNS_TLD}
	EOF
	sudo systemctl restart systemd-resolved
	sudo netplan set ethernets.eth0.dhcp4-overrides.use-dns=false && sudo netplan apply
	resolvectl dns
fi

