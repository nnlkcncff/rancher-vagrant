#!/usr/bin/env bash


## Functions.
{
	waitFor() { local description="${1}" command=( "${@:2}" ) stdin stdout stdout_req stderr stderr_fd stderr_last try
		[[ -s /dev/stdin || -p /dev/stdin ]] && read -d '' -r stdin
		exec {stderr_fd}<> >(:)
			while :; do
				stdout=$( { eval ${command[@]@Q}; } <<< "${stdin}" 2>&${stderr_fd} )
				[[ ${?} = 0 && ( ! -v stdout_req || -n ${stdout_req+${stdout}} ) || ${try+$(( --try ))} -lt 0 ]] && break || sleep 1s
				echo -e '\x00' >&${stderr_fd}; read -d '' -u ${stderr_fd} stderr
				[[ -n ${stderr} && ${stderr} != ${stderr_last} ]] && echo "Waiting for ${description} (${stderr})" > /dev/stderr && stderr_last="${stderr}"
			done
		exec {stderr_fd}<&-
		[[ -z ${stdout} ]] || echo "${stdout}"
	}

	sed() {
		command sed --quiet --regexp-extended "${@}"
	}

	kubectl() {
		sudo --login kubectl "${@}"
	}
}

## Input parameters.
{
	for var in \
		TZ \
		${INSTALL_RKE2_VERSION+} \
		IP ${LB_IP_RKE2+} LB_FQDN_RKE2 ${LB_IP_INGRESS+} \
		${CLUSTER_REGISTRATION+} \
		${CONTAINER_REGISTRY+} ${CONTAINER_REGISTRY_USER+} ${CONTAINER_REGISTRY_PASSWORD+} ${CONTAINER_REGISTRY_MIRROR+} \
		${RANCHER_FQDN+} \
		${TLS_RANCHER_INGRESS_CRT+} ${TLS_RANCHER_INGRESS_KEY+} ${TLS_CA+} \
		${BOOTSTRAP_PASSWORD+} \
		${SEALED_SECRETS_KEY+} ${SEALED_SECRETS_CRT+} \
		${FLEET_ROOT_GITREPO+} ${FLEET_ROOT_SEALED_SECRET+} ${FLEET_GITREPO_SECRETS+} ${FLEET_SSH_KNOWN_HOSTS+}
	do eval : "\${$var:?}"; done

	case "${NODE_TYPE:?}" in
		          first*) first=         ;;&
		      *upstream*) upstream=      ;;&
		    *downstream*) downstream=    ;;&
		*'control plane') control_plane= ;;&
		           *node) node=          ;;
	esac
}

## Provisioning.
{
	## Operating system.
	{
		## Time.
		{
			## https://www.freedesktop.org/software/systemd/man/latest/systemd-timesyncd.service.html
			## https://www.freedesktop.org/software/systemd/man/latest/timedatectl.html
			## https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade/installation-requirements#operating-systems-and-container-runtime-requirements

			sudo timedatectl set-timezone "${TZ}"
			sudo timedatectl set-ntp true
		}

		## Memory paging.
		{
			## https://man7.org/linux/man-pages/man5/fstab.5.html
			while read; do
				[[ ${REPLY:0:1} != '#' ]] && {
					read fs_spec fs_file fs_vfstype fs_mntops fs_freq fs_passno <<< ${REPLY}
					[[ ${fs_spec} = swap ]] && echo "# ${REPLY}" && continue
				}
				echo "${REPLY}"
			done < /etc/fstab | sudo install /dev/stdin /etc/fstab

			## https://man7.org/linux/man-pages/man8/swapon.8.html
			swap_files=($( swapon --show=NAME --noheadings ))

			## https://www.freedesktop.org/software/systemd/man/latest/systemctl.html
			## https://www.freedesktop.org/software/systemd/man/latest/systemd-fstab-generator.html
			sudo systemctl stop --type=swap '*'; sudo systemctl daemon-reload
		
			sudo rm --force "${swap_files[@]}"
		}

		## Kernel.
		{
			## https://man7.org/linux/man-pages/man7/inotify.7.html
			## https://www.freedesktop.org/software/systemd/man/latest/systemd-sysctl.html
			[[ -v node ]] && {
				sudo install --mode 644 /dev/stdin /etc/sysctl.d/rke2.conf <<-EOF && systemctl restart systemd-sysctl && sysctl --all --pattern inotify
					fs.inotify.max_user_instances = 1048576
					fs.inotify.max_user_watches = 524288
				EOF
			}
		}

		## CLI tools.
		{
			## https://github.com/containerd/containerd/blob/HEAD/cmd/ctr/app/main.go
			## https://github.com/kubernetes-sigs/cri-tools/blob/HEAD/docs/crictl.md#usage
			## https://kubernetes.io/docs/reference/kubectl/kubectl/#environment-variables
			sudo install /dev/stdin /etc/profile.d/rke2.sh <<-EOF
				PATH=\${PATH}:/var/lib/rancher/rke2/bin
				export CONTAINERD_ADDRESS=/run/k3s/containerd/containerd.sock
				export CONTAINER_RUNTIME_ENDPOINT=unix:///run/k3s/containerd/containerd.sock
				export KUBECONFIG=/var/lib/rancher/rke2/${control_plane+"server/cred/admin"}${node+"agent/kubelet"}.kubeconfig
			EOF

			## https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
			curl --silent --show-error --location --url "https://dl.k8s.io/release/$( curl --silent --show-error --location --url https://dl.k8s.io/release/stable.txt )/bin/linux/amd64/kubectl" \
			| sudo install --mode 755 /dev/stdin /usr/local/bin/kubectl

			## https://kubernetes.io/docs/reference/kubectl/generated/kubectl_completion/
			( sudo apt-get update; sudo DEBIAN_FRONTEND='noninteractive' apt-get install bash-completion ) > /dev/null
			sudo install --mode 644 /dev/stdin /etc/bash_completion.d/kubectl <<< "$( waitFor 'RKE2' kubectl completion bash )" &

			## https://metallb.io/troubleshooting/#checking-the-l2-advertisement-works
			# ( sudo apt-get update; sudo apt-get --assume-yes install arping ) > /dev/null

			# [[ -v control_plane ]] && {
			# 	curl \
			# 		--location --url "https://github.com/kubernetes-sigs/krew/releases/${KREW_VERSION:-latest}/download/krew-linux_amd64.tar.gz" \
			# 		--silent --show-error \
			# 	| sudo tar \
			# 		--verbose --extract --gzip \
			# 		--directory /usr/local/bin \
			# 		--transform 's/.*/krew/'

			# 	# https://helm.sh/docs/intro/install/#from-script
			# 	curl --silent --show-error --url https://raw.githubusercontent.com/helm/helm/HEAD/scripts/get-helm-3 | sudo --login --preserve-env=DESIRED_VERSION
			# }
		}

		## Longhorn.
		{
			## https://github.com/longhorn/longhorn/blob/HEAD/chart/README.md
			## https://www.freedesktop.org/software/systemd/man/latest/systemd-fstab-generator.html
			## https://www.freedesktop.org/software/systemd/man/latest/systemd.generator.html

			Longhorn_dir='/var/lib/longhorn'

			[[ -v node ]] && {
				Longhorn_disk=$(
					lsblk --nodeps --noheadings --output NAME | while read; do
						[[ $( lsblk --noheadings --output MOUNTPOINT /dev/${REPLY} ) =~ ^$ ]] && [[ ! $( lsblk --noheadings /dev/${REPLY} ) =~ \n ]] && echo /dev/${REPLY}
					done
				)
				[[ ${Longhorn_disk} ]] && {
					sudo install --directory "${Longhorn_dir}"
					sudo mkfs.ext4 ${Longhorn_disk}
					{
						while read; do [[ ${REPLY} =~ ${Longhorn_dir} ]] && continue || echo "${REPLY}"; done
						echo "/dev/disk/by-uuid/$( source <( blkid ${Longhorn_disk} --output export ); echo ${UUID} ) ${Longhorn_dir} ext4 defaults 0 2"
					} \
					< /etc/fstab | sudo install /dev/stdin /etc/fstab
					sudo systemctl daemon-reload; sudo systemctl restart local-fs.target; sudo mount "${Longhorn_dir}" --verbose --fake
				}
			}
		}
	}

	## RKE2.
	{
		## https://docs.rke2.io/install/quickstart
		## https://docs.rke2.io/install/ha
		## https://ranchermanager.docs.rancher.com/how-to-guides/new-user-guides/kubernetes-cluster-setup/rke2-for-rancher

		## Configuration file.
		{
			## https://docs.rke2.io/install/configuration
			## https://docs.rke2.io/reference/server_config
			## https://docs.rke2.io/reference/linux_agent_config
			## https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/#known-issues
			## https://github.com/rancher/rke2-charts/tree/HEAD/charts/rke2-coredns/rke2-coredns

			sudo install -D --mode 600 /dev/stdin /etc/rancher/rke2/config.yaml <<-EOF
				${first-"server: https://${LB_FQDN_RKE2}:9345"}
				node-ip: ${IP}
				resolv-conf: /run/systemd/resolve/resolv.conf
				$(
					[[ -v control_plane ]] && {
						echo tls-san:
						for san in ${LB_FQDN_RKE2} $( hostname --fqdn ); do echo "  - ${san}"; done

						echo cni: calico

						[[ -v downstream ]] && cat <<-eof
							disable: [ rke2-ingress-nginx ]
							node-taint: [ CriticalAddonsOnly=true:NoExecute ]
						eof
					}
					[[ ${Longhorn_disk} ]] && cat <<-eof
						node-label: [ node.longhorn.io/create-default-disk=true ]
					eof
				)
				${CONTAINER_REGISTRY_MIRROR:+"system-default-registry: ${CONTAINER_REGISTRY:?}"}
			EOF
		}

		## Private registry.
		{
			## https://docs.rke2.io/install/private_registry

			[[ ${CONTAINER_REGISTRY} && ${CONTAINER_REGISTRY_USER:?} && ${CONTAINER_REGISTRY_PASSWORD:?} ]] && {
				sudo install --mode 600 -D /dev/stdin /etc/rancher/rke2/registries.yaml <<-EOF
					${CONTAINER_REGISTRY_MIRROR:+"mirrors:"}
					$(
						for registry in ${CONTAINER_REGISTRY_MIRROR}; do echo "  ${registry}: { endpoint: [ 'http://${CONTAINER_REGISTRY}' ]}"; done
					)
					configs:
					  'https://${CONTAINER_REGISTRY}':
					    auth:
					      username: ${CONTAINER_REGISTRY_USER}
					      password: ${CONTAINER_REGISTRY_PASSWORD}
				EOF
			}
		}

		## Installation script.
		{
			## https://docs.rke2.io/install/configuration#configuring-the-linux-installation-script
			## https://docs.rke2.io/upgrades/manual_upgrade#release-channels

			export INSTALL_RKE2_TYPE=${control_plane+"server"}${node+"agent"}
			curl --silent --show-error --location https://get.rke2.io | sudo --login --preserve-env=INSTALL_RKE2_TYPE,INSTALL_RKE2_VERSION
			sudo systemctl --now --no-block enable "rke2-${INSTALL_RKE2_TYPE}.service"
		}

		## Node registration.
		{
			## https://docs.rke2.io/security/token

			token_RKE2_dir="/run/vagrant/token-rke2/${LB_FQDN_RKE2}"

			[[ -v first         ]] && waitFor 'RKE2' install -D --mode 644 --target-directory "${token_RKE2_dir}" /var/lib/rancher/rke2/server/{token,agent-token}
			[[ -v control_plane ]] && sudo install -D --mode 644 /dev/stdin /etc/rancher/rke2/config.yaml.d/token.yaml <<< "token: $( < "${token_RKE2_dir}/token" )"
			[[ -v node          ]] && sudo install -D --mode 644 /dev/stdin /etc/rancher/rke2/config.yaml.d/token.yaml <<< "token: $( < "${token_RKE2_dir}/agent-token" )"
		}

		## Helm charts and manifests.
		{
			## https://docs.rke2.io/install/packaged_components
			## https://docs.rke2.io/helm#automatically-deploying-manifests-and-helm-charts

			[[ -v control_plane ]] && {
				RKE2_manifests_dir='/var/lib/rancher/rke2/server/manifests'

				## CNI.
				{
					## https://docs.rke2.io/networking/basic_network_options?CNIplugin=Calico+CNI+Plugin#select-a-cni-plugin
					## https://github.com/rancher/rke2-charts/tree/HEAD/charts/rke2-calico/rke2-calico
					## https://docs.tigera.io/calico/latest/reference/installation/api

					[[ -v downstream ]] && sudo install -D --mode 644 /dev/stdin "${RKE2_manifests_dir}/rke2-calico-config.yaml" <<-EOF
						apiVersion: helm.cattle.io/v1
						kind: HelmChartConfig
						metadata:
						  name: rke2-calico
						  namespace: kube-system
						spec:
						  valuesContent: |-
						    installation:
						      controlPlaneTolerations:
						        - key: CriticalAddonsOnly
						          effect: NoExecute
						          operator: Equal
						          value: 'true'
					EOF
				}

				## Load balancer.
				{
					## https://metallb.io/installation/#installation-with-helm
					## https://github.com/metallb/metallb/tree/main/charts/metallb
					## https://metallb.io/troubleshooting/#general-concepts-1

					MetalLB_namespace='metallb-system'

					sudo install -D --mode 644 /dev/stdin "${RKE2_manifests_dir}/metallb.yaml" <<-EOF
						apiVersion: v1
						kind: Namespace
						metadata:
						  name: ${MetalLB_namespace}
						  labels:
						    pod-security.kubernetes.io/enforce: privileged
						    pod-security.kubernetes.io/audit: privileged
						    pod-security.kubernetes.io/warn: privileged
						---
						apiVersion: helm.cattle.io/v1
						kind: HelmChart
						metadata:
						  name: metallb
						  namespace: kube-system
						spec:
						  bootstrap: true
						  repo: https://metallb.github.io/metallb
						  chart: metallb
						  version: v0.14.9
						  targetNamespace: ${MetalLB_namespace}
						  valuesContent: |-
						    controller:
						      tolerations:
						        - key: CriticalAddonsOnly
						          effect: NoExecute
						          operator: Equal
						          value: 'true'
						    speaker:
						      frr: { enabled: false }
						      tolerations:
						        - key: CriticalAddonsOnly
						          effect: NoExecute
						          operator: Equal
						          value: "true"
						$(
							[[ -v LB_IP_INGRESS ]] && cat <<-eof
								---
								apiVersion: metallb.io/v1beta1
								kind: IPAddressPool
								metadata:
								  name: ingress-controller
								  namespace: ${MetalLB_namespace}
								spec:
								  addresses: [ ${LB_IP_INGRESS}/32 ]
								  serviceAllocation:
								    serviceSelectors:
								      - matchLabels: { app.kubernetes.io/name: rke2-ingress-nginx }
								---
								apiVersion: metallb.io/v1beta1
								kind: L2Advertisement
								metadata:
								  name: ingress-controller
								  namespace: ${MetalLB_namespace}
								spec:
								  nodeSelectors:
								    - matchExpressions:
								      - key: node-role.kubernetes.io/control-plane
								        operator: DoesNotExist
							eof
						)
						---
						apiVersion: metallb.io/v1beta1
						kind: IPAddressPool
						metadata:
						  name: rke2-fixed-registration-address
						  namespace: ${MetalLB_namespace}
						spec:
						  addresses: [ ${LB_IP_RKE2}/32 ]
						  serviceAllocation:
						    serviceSelectors:
						      - matchLabels: { app.kubernetes.io/name: rke2-server }
						---
						apiVersion: metallb.io/v1beta1
						kind: L2Advertisement
						metadata:
						  name: rke2-fixed-registration-address
						  namespace: ${MetalLB_namespace}
						spec:
						  nodeSelectors:
						    - matchExpressions:
						      - key: node-role.kubernetes.io/control-plane
						        operator: Exists
					EOF
				}

				## Fixed registration address.
				{
					## https://docs.rke2.io/install/ha

					RKE2_server_namespace='kube-system'

					sudo install -D --mode 644 /dev/stdin "${RKE2_manifests_dir}/rke2-server.yaml" <<-EOF
						apiVersion: v1
						kind: Service
						metadata:
						  name: rke2-server
						  namespace: ${RKE2_server_namespace}
						  labels:
						    app.kubernetes.io/name: rke2-server
						spec:
						  selector:
						    app.kubernetes.io/name: rke2-server
						  ports:
						    - protocol: TCP
						      port: 9345
						  type: LoadBalancer
						  allocateLoadBalancerNodePorts: false
						---
						apiVersion: apps/v1
						kind: DaemonSet
						metadata:
						  name: rke2-server
						  namespace: ${RKE2_server_namespace}
						spec:
						  selector:
						    matchLabels:
						      app.kubernetes.io/name: rke2-server
						  template:
						    metadata:
						      labels:
						        app.kubernetes.io/name: rke2-server
						    spec:
						      containers:
						        - name: rke2-server
						          image: busybox:stable
						          command: [ "/bin/tail", "-f", "/dev/null" ]
						          ports:
						            - containerPort: 9345
						          readinessProbe:
						            httpGet:
						              path: /cacerts
						              port: 9345
						              scheme: HTTPS
						      terminationGracePeriodSeconds: 0
						      tolerations:
						        - effect: NoExecute
						          operator: Exists
						      nodeSelector:
						        node-role.kubernetes.io/control-plane: "true"
						      hostNetwork: true
					EOF
				}

				## Ingress controller.
				{
					## https://docs.rke2.io/networking/networking_services#nginx-ingress-controller
					## https://github.com/rancher/rke2-charts/tree/HEAD/charts/rke2-ingress-nginx/rke2-ingress-nginx
					## https://kubernetes.github.io/ingress-nginx/deploy/baremetal/#source-ip-address

					[[ -v upstream ]] && {
						RKE2_release_dir=$( waitFor 'RKE2' compgen -A directory "/var/lib/rancher/rke2/data/${INSTALL_RKE2_VERSION/+/-}" )
						v_chart=$( waitFor 'RKE2' sed 's|.+helm.cattle.io/chart-url: ".+-v?([0-9\.]+)-?.*.tgz"|\1|p' "${RKE2_release_dir}/charts/rke2-ingress-nginx.yaml" )
						v_min='4.9.100'

						if [[ $( v=($( sort --version-sort <<< "${v_min}"$'\n'"${v_chart}" )); echo "${v}" ) = "${v_min}" ]]
						then sudo rm --force "${RKE2_manifests_dir}"/{ingress-nginx.yaml,rke2-ingress-nginx.yaml.skip} && config=
						else sudo touch "${RKE2_manifests_dir}/rke2-ingress-nginx.yaml.skip"
						fi

						sudo install -D --mode 644 /dev/stdin "${RKE2_manifests_dir}/${config+"rke2-"}ingress-nginx${config+"-config"}.yaml" <<-EOF
							apiVersion: helm.cattle.io/v1
							kind: HelmChart${config+"Config"}
							metadata:
							  name: rke2-ingress-nginx
							  namespace: kube-system
							spec:
							$(
								[[ -v config ]] || cat <<-eof
									  bootstrap: false
									  repo: https://rke2-charts.rancher.io
									  chart: rke2-ingress-nginx
									  version: ${v_min}
									  targetNamespace: kube-system
								eof
							)
							  valuesContent: |-
							    controller:
							      ## https://github.com/rancher/rke2-charts/tree/HEAD/charts/rke2-ingress-nginx/rke2-ingress-nginx/4.0.301
							      watchIngressWithoutClass: true
							      ## https://github.com/rancher/rke2-charts/blob/HEAD/charts/rke2-ingress-nginx/rke2-ingress-nginx/3.3.000
							      hostPort:
							        enabled: false
							      service:
							        enabled: true
							        externalTrafficPolicy: Local
							        ## https://github.com/rancher/rke2-charts/blob/HEAD/charts/rke2-ingress-nginx/rke2-ingress-nginx/4.9.100
							        allocateLoadBalancerNodePorts: false
						EOF
					}
				}

				## Rancher server.
				{
					## https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade/install-upgrade-on-a-kubernetes-cluster
					## https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade/installation-references/helm-chart-options
					## https://github.com/rancher/rancher/tree/HEAD/chart

					[[ -v upstream && ${RANCHER_FQDN:?} ]] && {

						! [[ ${TLS_RANCHER_INGRESS_KEY} && ${TLS_RANCHER_INGRESS_CRT} ]] && {
							TLS_Rancher_dir='/run/vagrant/tls-rancher'
							CA_private_key="${TLS_Rancher_dir}/cacerts.key"
							CA_certificate="${TLS_Rancher_dir}/cacerts.pem"
							Rancher_private_key="${TLS_Rancher_dir}/tls.key"
							Rancher_certificate="${TLS_Rancher_dir}/tls.crt"
							Rancher_CSR="${TLS_Rancher_dir}/tls.csr"

							! [[ -d ${TLS_Rancher_dir} ]] && {
								install --directory "${TLS_Rancher_dir}"
								## Doesn't work on old Ubuntu.
								# openssl req \
								# 	-subj '/CN=Root Certificate Authority' \
								# 	-newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -noenc -keyout "${CA_private_key}" \
								# 	-x509 -days 3650 -out "${CA_certificate}"
								# openssl req \
								# 	-subj "/CN=Rancher" \
								# 	-addext "subjectAltName=DNS:${RANCHER_FQDN}" \
								# 	-newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -noenc -keyout "${Rancher_private_key}" \
								# 	-CA "${CA_certificate}" -CAkey "${CA_private_key}" -days 365 -out "${Rancher_certificate}"
								## https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.6
								openssl req \
									-subj '/CN=Root Certificate Authority' \
									-newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "${CA_private_key}" \
									-x509 -days 3650 -out "${CA_certificate}"
								openssl req \
									-subj "/CN=Rancher" \
									-newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "${Rancher_private_key}" \
									-out "${Rancher_CSR}"
								openssl x509 \
									-req -in "${Rancher_CSR}" -out "${Rancher_certificate}" \
									-CA "${CA_certificate}" -CAkey "${CA_private_key}" -CAcreateserial -days 365 \
									-extfile <( echo "subjectAltName=DNS:${RANCHER_FQDN}" )
							}

							TLS_CA_CRT=$( < "${CA_certificate}" )
							TLS_RANCHER_INGRESS_KEY=$( < "${Rancher_private_key}" )
							TLS_RANCHER_INGRESS_CRT=$( cat "${Rancher_certificate}" "${CA_certificate}" )
						}

						intermediate_CA=$( command sed '1,/END CERTIFICATE/d' <<< "${TLS_RANCHER_INGRESS_CRT}" )
						[[ ${intermediate_CA} =~ [[:graph:]] ]] || unset intermediate_CA

						openssl verify -show_chain \
							${TLS_CA_CRT:+-CAfile <( echo "${TLS_CA_CRT}" )} \
							${intermediate_CA:+-untrusted <( echo "${intermediate_CA}" )} \
							<( echo "${TLS_RANCHER_INGRESS_CRT}" ) 2>&1 \
						| command sed --regexp-extended 's|.*/dev/fd/[0-9]+|Rancher TLS|'
						[[ ${PIPESTATUS} = 0 ]] || exit

						sudo install -D --mode 644 /dev/stdin "${RKE2_manifests_dir}/rancher.yaml" <<-EOF
							apiVersion: v1
							kind: Namespace
							metadata:
							  name: cattle-system
							---
							apiVersion: helm.cattle.io/v1
							kind: HelmChart
							metadata:
							  name: rancher
							  namespace: kube-system
							spec:
							  bootstrap: true
							  repo: https://releases.rancher.com/server-charts/stable
							  chart: rancher
							  version: 2.7.9
							  # version: 2.10.3
							  targetNamespace: cattle-system
							  ## Doesn't work in version 2.7.9.
							  # createNamespace: true
							  valuesContent: |-
							    hostname: ${RANCHER_FQDN}
							    ingress: { tls: { source: secret }}
							    ${TLS_CA_CRT:+"privateCA: true"}
							    ${BOOTSTRAP_PASSWORD:+"bootstrapPassword: ${BOOTSTRAP_PASSWORD}"}
							    antiAffinity: required
							$(
								## https://github.com/rancher/rancher/blob/v2.8.3/chart/templates/configMap.yaml
								## https://github.com/rancher/charts/blob/dev-v2.11/charts/fleet/106.0.1%2Bup0.12.1/values.yaml
								# [[ ${FLEET_SSH_KNOWN_HOSTS} = false ]] && cat <<-eof
								# 	    fleet:
								# 	      insecureSkipHostKeyChecks: true
								# eof
							)
							---
							apiVersion: v1
							kind: Secret
							data:
							  tls.key: $( base64 --wrap 0 <<< "${TLS_RANCHER_INGRESS_KEY}" )
							  tls.crt: $( base64 --wrap 0 <<< "${TLS_RANCHER_INGRESS_CRT}" )
							metadata:
							  name: tls-rancher-ingress
							  namespace: cattle-system
							type: kubernetes.io/tls
							$(
								[[ ${TLS_CA_CRT} ]] && cat <<-eof
									---
									apiVersion: v1
									kind: Secret
									data:
									  cacerts.pem: $( base64 --wrap 0 <<< "${TLS_CA_CRT}" )
									metadata:
									  name: tls-ca
									  namespace: cattle-system
									type: Opaque
								eof
							)
						EOF
					}
				}

				## Sealed secrets controller.
				{
					## https://github.com/bitnami-labs/sealed-secrets/tree/HEAD/helm/sealed-secrets
					## https://github.com/bitnami-labs/sealed-secrets/blob/HEAD/docs/bring-your-own-certificates.md

					Sealed_secrets_namespace='kube-system'

					! [[ ${SEALED_SECRETS_KEY} && ${SEALED_SECRETS_CRT} ]] && {
						TLS_Sealed_secrets_dir='/run/vagrant/tls-sealed-secrets'
						Sealed_secrets_private_key="${TLS_Sealed_secrets_dir}/tls.key"
						Sealed_secrets_certificate="${TLS_Sealed_secrets_dir}/tls.crt"

						! [[ -d ${TLS_Sealed_secrets_dir} ]] && {
							install --directory "${TLS_Sealed_secrets_dir}"
							openssl req \
								-newkey rsa:4096 -nodes -keyout "${Sealed_secrets_private_key}" \
								-x509 -days 3650 -out "${Sealed_secrets_certificate}" \
								-config /dev/stdin <<-EOF
									[req]
									distinguished_name = Subject
									x509_extensions = X509v3 extensions
									prompt = no

									[Subject]
									O = sealed-secret
									CN = sealed-secret

									[X509v3 extensions]
									keyUsage = critical,encipherOnly
									basicConstraints = critical,CA:true
									subjectKeyIdentifier = hash
								EOF
						}

						SEALED_SECRETS_KEY=$( < "${Sealed_secrets_private_key}" )
						SEALED_SECRETS_CRT=$( < "${Sealed_secrets_certificate}" )
					}

					sudo install -D --mode 644 /dev/stdin "${RKE2_manifests_dir}/sealed-secrets.yaml" <<-EOF
						apiVersion: helm.cattle.io/v1
						kind: HelmChart
						metadata:
						  name: sealed-secrets-controller
						  namespace: ${Sealed_secrets_namespace}
						spec:
						  bootstrap: false
						  repo: https://bitnami-labs.github.io/sealed-secrets
						  chart: sealed-secrets
						  version: 2.17.2
						  targetNamespace: ${Sealed_secrets_namespace}
						  valuesContent: |-
						    keyrenewperiod: '0'
						    # tolerations:
						    #   - key: CriticalAddonsOnly
						    #     effect: NoExecute
						    #     operator: Equal
						    #     value: 'true'
						---
						apiVersion: v1
						kind: Secret
						data:
						  tls.key: $( base64 --wrap 0 <<< "${SEALED_SECRETS_KEY}" )
						  tls.crt: $( base64 --wrap 0 <<< "${SEALED_SECRETS_CRT}" )
						metadata:
						  labels:
						    sealedsecrets.bitnami.com/sealed-secrets-key: active
						  name: sealed-secrets-key
						  namespace: ${Sealed_secrets_namespace}
						type: kubernetes.io/tls
					EOF
				}

				## Fleet.
				{
					## https://fleet.rancher.io/gitrepo-add#adding-a-private-git-repository

					[[ -v upstream && ${FLEET_ROOT_GITREPO:?} ]] && {
						sudo install -D --mode 644 /dev/stdin "${RKE2_manifests_dir}/fleet.yaml" <<-EOF
							${FLEET_ROOT_GITREPO}
							$(
								if [[ ${FLEET_ROOT_SEALED_SECRET} ]]; then
									cat <<-eof
										---
										${FLEET_ROOT_SEALED_SECRET}
									eof
								else
									SSH_Fleet_dir='/run/vagrant/repo-ssh-fleet'

									while read ns n; do
										cat <<-eof
											---
											apiVersion: v1
											kind: Secret
											metadata:
											  name: ${n}
											  namespace: ${ns}
											data:
											  ssh-privatekey: $( base64 --wrap 0 < "${SSH_Fleet_dir}/ssh" )
											  ssh-publickey: $( base64 --wrap 0 < "${SSH_Fleet_dir}/ssh.pub" )
											type: kubernetes.io/ssh-auth
										eof
									done <<< "${FLEET_GITREPO_SECRETS:?}"
								fi
							)
						EOF
					}
				}

				[[ ${EXTRA_MANIFESTS} ]] && sudo install -D --mode 644 /dev/stdin "${RKE2_manifests_dir}/extra.yaml" <<< "${EXTRA_MANIFESTS}"
			}
		}
	}

	## Checks.
	{
		checkKubernetes() {
			waitFor 'Kubernetes' kubectl get --raw /api > /dev/null
		}
		checkCni() {
			waitFor 'CNI' kubectl wait --for jsonpath=status.availableReplicas --namespace calico-system Deployment/calico-kube-controllers
			waitFor 'CNI' kubectl wait --for jsonpath=status.availableReplicas --namespace calico-system Deployment/calico-typha
			waitFor 'CNI' kubectl wait --for jsonpath=status.numberAvailable --namespace calico-system DaemonSet/calico-node
		}
		checkLoadBalancer() {
			waitFor 'load balancer' kubectl wait --for jsonpath=status.availableReplicas --namespace "${MetalLB_namespace}" Deployment/metallb-controller
			waitFor 'load balancer' kubectl wait --for jsonpath=status.numberAvailable --namespace "${MetalLB_namespace}" DaemonSet/metallb-speaker
		}
		checkRegistrationAddress() {
			waitFor 'RKE2 fixed registration address' kubectl wait --for jsonpath=status.numberAvailable --namespace "${RKE2_server_namespace}" DaemonSet/rke2-server
			waitFor 'RKE2 fixed registration address' kubectl wait --for jsonpath=status.loadBalancer.ingress --namespace "${RKE2_server_namespace}" Service/rke2-server
		}
		checkIngressController() {
			waitFor 'ingress controller' kubectl wait --for jsonpath=status.numberAvailable --namespace kube-system DaemonSet/rke2-ingress-nginx-controller
			waitFor 'ingress controller' kubectl wait --for jsonpath=status.loadBalancer.ingress --namespace kube-system Service/rke2-ingress-nginx-controller
		}
		checkRancher() {
			[[ -v upstream   ]] && waitFor 'Rancher' kubectl wait --for jsonpath=status.availableReplicas --namespace cattle-system Deployment/rancher
			[[ -v downstream ]] && waitFor 'Rancher' kubectl wait --for jsonpath=status.availableReplicas --namespace cattle-system Deployment/cattle-cluster-agent
		}
		checkFleet() {
			[[ -v upstream ]] && waitFor 'Fleet' kubectl wait --for jsonpath=status.availableReplicas --namespace cattle-fleet-system Deployment/fleet-controller
			waitFor 'Fleet' kubectl wait --for jsonpath=status.availableReplicas --namespace "cattle-fleet-${upstream+"local-"}system" Deployment/fleet-agent
		}
		checkSealedSecretsController() {
			waitFor 'sealed secrets controller' kubectl wait --for jsonpath=status.availableReplicas --namespace "${Sealed_secrets_namespace}" Deployment/sealed-secrets-controller
		}
	}

	checkKubernetes

	[[ -v first ]] && { checkCni

		## Cluster registration.
		{
			## https://ranchermanager.docs.rancher.com/how-to-guides/new-user-guides/kubernetes-clusters-in-rancher-setup/register-existing-clusters#registering-a-cluster
			## https://ranchermanager.docs.rancher.com/reference-guides/cluster-configuration/rancher-server-configuration/rke2-cluster-configuration#cluster-config-file-reference
			## https://ranchermanager.docs.rancher.com/how-to-guides/new-user-guides/launch-kubernetes-with-rancher/about-rancher-agents#cattle-cluster-agent
			## https://fleet.rancher.io/ref-resources

			script_rancher_dir='/run/vagrant/script-rancher'

			[[ -v upstream ]] && { checkRancher

				kubectl patch --type merge --patch "value: https://${RANCHER_FQDN}" Setting/server-url 
				kubectl patch --type merge --patch 'value: "false"' Setting/first-login
				# kubectl patch --type merge --patch "value: $( date --utc +%Y-%m-%dT%H:%M:%S.%3NZ )" Setting/eula-agreed
				# kubectl patch --type merge --patch 'value: out' Setting/telemetry-opt
				for cluster_name in ${CLUSTER_REGISTRATION}; do
					waitFor 'Fleet' \
						kubectl apply --filename /dev/stdin <<-EOF
							apiVersion: provisioning.cattle.io/v1
							kind: Cluster
							metadata:
							  namespace: fleet-default
							  name: ${cluster_name}
							spec:
							  clusterAgentDeploymentCustomization:
							    appendTolerations:
							      - key: CriticalAddonsOnly
							        effect: NoExecute
							        operator: Equal
							        value: 'true'
							  fleetAgentDeploymentCustomization:
							    appendTolerations:
							      - key: CriticalAddonsOnly
							        effect: NoExecute
							        operator: Equal
							        value: 'true'
						EOF
					cluster_namespace=$( 
						stdout_req= waitFor "'${cluster_name}' registration" \
							kubectl get --output jsonpath="{ .items[?( @.spec.displayName==${cluster_name@Q} )].metadata.name }" Cluster.management.cattle.io
					)
					cluster_registration_command=$(
						stdout_req= waitFor "'${cluster_name}' registration" \
							kubectl get --output jsonpath='{ .status.insecureCommand }' --namespace "${cluster_namespace}" ClusterRegistrationToken.management.cattle.io/default-token
					)
					install -D /dev/stdin "${script_rancher_dir}/${cluster_name}.sh" <<< "${cluster_registration_command}"
				done
			}

			[[ -v downstream && ${CLUSTER_REGISTRATION} ]] && { sudo --login < "${script_rancher_dir}/${CLUSTER_REGISTRATION}.sh"; checkRancher; }
		}

		## Fleet.
		{
			## https://ranchermanager.docs.rancher.com/integrations-in-rancher/fleet/overview#accessing-fleet-in-the-rancher-ui
			## https://fleet.rancher.io/gitrepo-add#proper-namespace

			[[ -v upstream ]] && { checkLoadBalancer; checkIngressController; checkFleet; checkSealedSecretsController

				GitRepo_namespace=$( sed 's|.*namespace: (.*)|\1|p' <<< "${FLEET_ROOT_GITREPO}" )
				GitRepo_name=$( sed 's|.*name: (.*)|\1|p' <<< "${FLEET_ROOT_GITREPO}" )
				GitRepo_secret=$( sed 's|.*clientSecretName: (.*)|\1|p' <<< "${FLEET_ROOT_GITREPO}" )

				## Disable SSH host key checking.
				{
					## https://fleet.rancher.io/gitrepo-add#known-hosts

					[[ ${FLEET_SSH_KNOWN_HOSTS} = false ]] && {
						removeSecretKnownHosts() {
							kubectl patch --type json --patch-file /dev/stdin --namespace "${1}" "Secret/${2}" <<-EOF
								[
									{ "op": "replace", "path": "/data/known_hosts", "value": },
									{ "op": "replace", "path": "/immutable", "value": true }
								]
							EOF
						}
						try=1 waitFor "$( [[ ${FLEET_ROOT_SEALED_SECRET} ]] && echo sealed secrets controller || echo RKE2 manifests )" \
							removeSecretKnownHosts "${GitRepo_namespace}" "${GitRepo_secret}"
						eval sealed_secrets=($(
							waitFor 'Fleet' \
								kubectl wait --for jsonpath=status.resources --namespace "${GitRepo_namespace}" "GitRepo/${GitRepo_name}" > /dev/null
							kubectl get --output jsonpath='{ range .status.resources[*] }{ .namespace } { .name } { .kind }{"\n"}{ end }' --namespace "${GitRepo_namespace}" "GitRepo/${GitRepo_name}" \
							| while read ns n k; do [[ ${k} = SealedSecret ]] && echo "'${ns} ${n}'"; done
						))
						eval secrets=($(
							for ss in "${sealed_secrets[@]}"; do read ns n <<< "${ss}"
								waitFor 'Fleet' \
									kubectl get --output jsonpath='{ .spec.template.metadata.namespace } { .spec.template.metadata.name } { .spec.template.type }{"\n"}' --namespace "${ns}" "SealedSecret/${n}" \
								| while read ns n t; do [[ ${t} = kubernetes.io/ssh-auth ]] && echo "'${ns} ${n}'"; done
							done
						))
						for s in "${secrets[@]}"; do read ns n <<< "${s}"
							try=1 waitFor 'sealed secrets controller' removeSecretKnownHosts "${ns}" "${n}"
						done
					}
				}

				## Prevent creation of downstream cluster resources.
				{
					eval repos=($(
						waitFor 'Fleet' \
							kubectl wait --for jsonpath=status.resources --namespace "${GitRepo_namespace}" "GitRepo/${GitRepo_name}" > /dev/null
						kubectl get --output jsonpath='{ range .status.resources[*] }{ .namespace } { .name } { .kind }{"\n"}{ end }' --namespace "${GitRepo_namespace}" "GitRepo/${GitRepo_name}" \
						| while read ns n k; do [[ ${k} = GitRepo ]] && echo "'${ns} ${n}'"; done
					))
					for r in "${!repos[@]}"; do read ns n <<< "${repos[$r]}"
						# [[ ${n} == @(nginx) ]] && continue
						waitFor 'RKE2 manifests' \
							kubectl patch --type merge --patch 'spec: { paused: true }' --namespace "${ns}" "GitRepo/${n}"
					done
				}
			}
		}

		[[ -v downstream ]] && { checkFleet; checkLoadBalancer; }; checkRegistrationAddress
	}
}

echo 'Bootstrap completed.'


## To do:
##   - cattle-cluster-agent limits should be defined
##     https://ranchermanager.docs.rancher.com/how-to-guides/new-user-guides/launch-kubernetes-with-rancher/about-rancher-agents#requests
##
##   - Longhorn:
##     - install nfs-common etc
##
##   - parse YAML without sed, maybe even construct it with yq:
##     - curl --location --url https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 | sudo install --mode 755 /dev/stdin /usr/local/bin/yq
##
##   - add external authentication

