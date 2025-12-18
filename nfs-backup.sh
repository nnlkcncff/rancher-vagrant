#!/usr/bin/env sh

## Imput parameters.
{
	for var in \
		${NFS_EXPORTS+} ${NFS_ADDR+} ${NFS_PATH+}
	do eval : "\${$var:?}"; done
}

## https://man7.org/linux/man-pages/man5/exports.5.html
## https://man7.org/linux/man-pages/man8/exportfs.8.html
if [ "${NFS_EXPORTS}" ]; then
	sudo apk --quiet add nfs-utils
	sudo rc-update add nfs && sudo rc-service nfs start
	echo "${NFS_EXPORTS}" | sudo install -D -m 644 /dev/stdin /etc/exports.d/etcd.exports
	for path in $( echo "${NFS_EXPORTS}" | while read export_point options; do echo "${export_point}"; done | uniq ); do
		sudo install -d -o nobody -g nogroup "${path}"
	done
	sudo exportfs -ar && showmount --exports --no-headers
fi

## https://man7.org/linux/man-pages/man5/nfs.5.html
## https://man7.org/linux/man-pages/man5/crontab.5.html
## https://www.gnu.org/software/coreutils/manual/html_node/cp-invocation.html
## https://www.gnu.org/software/findutils/manual/html_mono/find.html
## https://manpages.debian.org/debianutils/run-parts.8.en.html
if [ "${NFS_PATH}" ] && [ "${NFS_ADDR}" ]; then
	( sudo apt-get update; sudo DEBIAN_FRONTEND='noninteractive' apt-get --assume-yes install nfs-common ) > /dev/null
	sudo install --directory /mnt/etcdbackup
	{
		while read line; do [ "${line}" = /mnt/etcdbackup ] && continue || echo "${line}"; done
		echo "${NFS_ADDR}:${NFS_PATH} /mnt/etcdbackup nfs rw,rsize=8192,wsize=8192,timeo=10,hard,intr 0 0"
	} \
	< /etc/fstab | sudo install /dev/stdin /etc/fstab && sudo mount /mnt/etcdbackup --verbose

	sudo install --mode 755 /dev/stdin /etc/cron.daily/etcdbackup <<-EOF
		/usr/bin/env bash -c 'cp --no-clobber /var/lib/rancher/rke2/server/db/snapshots/* /mnt/etcdbackup'
	EOF
	sudo install --mode 755 /dev/stdin /etc/cron.daily/cleanupetcdbackup <<-EOF
		/usr/bin/env bash -c 'find /mnt/etcdbackup/. -type f -mtime +15 -delete'
	EOF
	run-parts --test /etc/cron.daily --regex etcdbackup
fi

