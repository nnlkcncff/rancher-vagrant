#!/usr/bin/env sh

## Imput parameters.
{
	for var in \
		FLEET_GITREPO_PATHS ${FLEET_GITREPO_PORTS+} ${FLEET_GITREPO_SECRETS+} ${FLEET_ROOT_SEALED_SECRET+} ${SEALED_SECRETS_KEY+}
	do eval : "\${$var:?}"; done
}

sudoGit() {
	sudo --login --user git "${@}"
}

## https://git-scm.com/book/en/v2/Git-on-the-Server-Setting-Up-the-Server
{
	sudo apk add \
		git \
		kubeseal --repository 'http://dl-cdn.alpinelinux.org/alpine/edge/testing'
	sudo adduser -D git && sudo passwd git -u

	## https://git-scm.com/docs/git-config#Documentation/git-config.txt-safedirectory
	sudoGit git config --global --replace-all safe.directory '*'

	for p in 22 ${FLEET_GITREPO_PORTS}; do echo Port "${p}"; done | sudo install -m 644 /dev/stdin /etc/ssh/sshd_config.d/git.conf
	sudo rc-service sshd restart

	repo_SSH_Fleet_dir='/run/vagrant/run/repo-ssh-fleet'

	## https://github.com/bitnami-labs/sealed-secrets?tab=readme-ov-file#can-i-decrypt-my-secrets-offline-with-a-backup-key
	## https://man.openbsd.org/ssh-keygen
	if [ "${FLEET_ROOT_SEALED_SECRET}" ]; then
		kubeseal --recovery-unseal --recovery-private-key <( echo "${SEALED_SECRETS_KEY}" ) --secret-file <( echo "${FLEET_ROOT_SEALED_SECRET}" )
	elif [ "${FLEET_GITREPO_SECRETS:?}" ]; then
		ssh-keygen -t ed25519 -P '' -C 'generated' -f "${repo_SSH_Fleet_dir}/ssh"
	fi > /dev/null

	for path in "${repo_SSH_Fleet_dir}"/*; do
		[ -d "${path}" ] && for repo in ${FLEET_GITREPO_PATHS}; do
			Git=$( [ "${repo:0:1}" = / ] || echo Git )
			case "${repo##*/}" in *"${path##*/}"*) sudo${Git} mkdir --parents "${repo%/*}" && sudo${Git} ln -s -T -f -v "${path}" "${repo}";; esac
		done
	done

	for path in "${repo_SSH_Fleet_dir}"/*; do
		[ -f "${path}" ] && case "${path}" in *.pub) ssh-keygen -l -f "${path}" > /dev/null && echo "$( cat "${path}" )";; esac
	done \
	| ( sudoGit mkdir --parents .ssh && sudoGit tee .ssh/authorized_keys )
}

