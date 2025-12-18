## Input parameters.
(
	$root = File.expand_path(__dir__)
	load "#{$root}/init.rb"
	load "#{$root}/repo.rb"
	load "#{$root}/secrets-local.rb"                                # are not used anywhere else (non-sensitive data)
	"#{$root}/secrets-prod.rb".then { load _1 if File.exist?(_1) }  # are used in production (sensitive data)

	## https://en.wikipedia.org/wiki/List_of_tz_database_time_zones
	$tz = 'Europe/Amsterdam'

	## https://en.wikipedia.org/wiki/Classless_Inter-Domain_Routing
	## https://en.wikipedia.org/wiki/Reserved_IP_addresses
	## https://www.virtualbox.org/ticket/21454
	-> {
		cidr_block = '0.0.16.0/23'
		$network_prefix = (
			ip, $prefix_length = cidr_block.split('/')
			ip  .split('.')
				.map( &:to_i )
				.each_with_index
				.take_while { $prefix_length.to_i >= ( _2 + 1 ) * 8 }
				.map( &:first )
				.join('.')
		)
	}.call

	## https://en.wikipedia.org/wiki/Name_server
	$svc_ip = "#{$network_prefix}.16.254"

	## https://en.wikipedia.org/wiki/List_of_Internet_top-level_domains
	## https://datatracker.ietf.org/doc/html/rfc2606#section-2
	## https://hstspreload.org/#submission-form
	$dns_tld = 'test'

	## https://en.wikipedia.org/wiki/Domain_Name_System#Resource_records
	(
		# https://git-scm.com/book/en/v2/Git-on-the-Server-Setting-Up-the-Server
		$gitrepo_dns_rr = FLEET_GITREPO_ADDRS.split.map {{ 'fqdn' => _1, 'ip' => $svc_ip }}

		$extra_dns_rr = {
			## https://en.wikipedia.org/wiki/Network_File_System
			'nfs_server' => { 'fqdn' => NFS_ADDR, 'ip' => $svc_ip },

			'app' => { 'fqdn' => "*.app.#{$dns_tld}", 'ip' => LB_IP_APP_DEPLOY },
			'rancher' => { 'fqdn' => "rancher.app.#{$dns_tld}", 'ip' => "#{$network_prefix}.16.200" },
			'longhorn_app_tools' => { 'fqdn' => LONGHORN_ADDR_APP_TOOLS, 'ip' => LB_IP_APP_TOOLS },
			'monitoring_app_tools' => { 'fqdn' => GRAFANA_ADDR_APP_TOOLS, 'ip' => LB_IP_APP_TOOLS },
			'longhorn_app_deploy' => { 'fqdn' => LONGHORN_ADDR_APP_DEPLOY, 'ip' => LB_IP_APP_DEPLOY },
			'monitoring_app_deploy' => { 'fqdn' => GRAFANA_ADDR_APP_DEPLOY, 'ip' => LB_IP_APP_DEPLOY },

			# 'container_registry' => { 'fqdn' => CONTAINER_REGISTRY, 'ip' => '' }
		}
	)

	## Virtual machines.
	(
		-> {
			hostname_prefix = 'apprancher'

			(1..3).each do |i|
				$vms["local CP#{i}"] = {
					'node_type' => "#{ 'first ' if i == 1 }upstream control plane",
					'rke2_version' => 'v1.24.10+rke2r1',
					'ip' => "#{$network_prefix}.16.10#{i}",
					'fqdn' => "#{hostname_prefix}#{ format('%02d', i) }.#{$dns_tld}",
					'lb_ip_rke2' => "#{$network_prefix}.16.100",
					'lb_fqdn_rke2' => "#{hostname_prefix}.#{$dns_tld}",
					'lb_ip_ingress' => $extra_dns_rr['rancher']['ip'],
					'rancher_fqdn' => $extra_dns_rr['rancher']['fqdn'],
					'tls_rancher_ingress_key' => TLS_RANCHER_INGRESS_KEY,
					'tls_rancher_ingress_crt' => TLS_RANCHER_INGRESS_CRT,
					'tls_ca_crt' => TLS_CA_CRT,
					'bootstrap_password' => BOOTSTRAP_PASSWORD,
					'cluster_registration' => -> { $vms.values
						.select { _1['node_type'].include?('downstream control plane') }
						.map { _1['cluster_registration'] }
						.compact.uniq.join(' ')
					},
					'nfs_rke2' => '/etcd/rancher',
					'sealed_secrets_key' => SEALED_SECRETS_KEY,
					'sealed_secrets_crt' => SEALED_SECRETS_CRT,
					'fleet_root_gitrepo' => FLEET_ROOT_GITREPO,
					'fleet_root_sealed_secret' => FLEET_ROOT_SEALED_SECRET,
					'fleet_gitrepo_secrets' => FLEET_GITREPO_SECRETS,
					'fleet_known_hosts' => ! FLEET_ROOT_SEALED_SECRET || FLEET_GITREPO_ADDRS.empty?,
					'extra_manifests' => EXTRA_MANIFESTS_RANCHER
				}
			end
		}.call

		-> {
			cluster = 'app-tools'
			hostname_prefix = 'apptool'
			rke2_version = 'v1.25.16+rke2r1'

			(1..3).each do |i|
				$vms["#{cluster} CP#{i}"] = {
					'node_type' => "#{ 'first ' if i == 1 }downstream control plane",
					'rke2_version' => rke2_version,
					'ip' => "#{$network_prefix}.16.11#{i}",
					'fqdn' => "#{hostname_prefix}mast#{ format('%02d', i) }.#{$dns_tld}",
					'lb_ip_rke2' => "#{$network_prefix}.16.110",
					'lb_fqdn_rke2' => "#{hostname_prefix}mast.#{$dns_tld}",
					'cluster_registration' => "#{ cluster if i == 1 }",
					'nfs_rke2' => "/etcd/#{cluster}",
					'sealed_secrets_key' => SEALED_SECRETS_KEY,
					'sealed_secrets_crt' => SEALED_SECRETS_CRT,
					'extra_manifests' => EXTRA_MANIFESTS_APP_TOOLS
				}
			end
			(1..2).each do |i|
				$vms["#{cluster} N#{i}"] = {
					'node_type' => 'downstream node',
					'rke2_version' => rke2_version,
					'ip' => "#{$network_prefix}.16.12#{i}",
					'fqdn' => "#{hostname_prefix}work#{ format('%02d', i) }.#{$dns_tld}",
					'lb_fqdn_rke2' => "#{hostname_prefix}mast.#{$dns_tld}",
					'nfs_longhorn' => "#{ "/longhorn/#{cluster}" if i <= 2 }"
				}
			end
		}.call

		-> {
			cluster = 'app-build'
			hostname_prefix = 'appbuild'
			rke2_version = 'v1.26.15+rke2r1'

			(1..3).each do |i|
				$vms["#{cluster} CP#{i}"] = {
					'node_type' => "#{ 'first ' if i == 1 }downstream control plane",
					'rke2_version' => rke2_version,
					'ip' => "#{$network_prefix}.16.13#{i}",
					'fqdn' => "#{hostname_prefix}mast#{ format('%02d', i) }.#{$dns_tld}",
					'lb_ip_rke2' => "#{$network_prefix}.16.130",
					'lb_fqdn_rke2' => "#{hostname_prefix}mast.#{$dns_tld}",
					'cluster_registration' => "#{ cluster if i == 1 }",
					'nfs_rke2' => "/etcd/#{cluster}",
					'sealed_secrets_key' => SEALED_SECRETS_KEY,
					'sealed_secrets_crt' => SEALED_SECRETS_CRT,
					'extra_manifests' => EXTRA_MANIFESTS_APP_BUILD
				}
			end
			(1..2).each do |i|
				$vms["#{cluster} N#{i}"] = {
					'node_type' => 'downstream node',
					'rke2_version' => rke2_version,
					'ip' => "#{$network_prefix}.16.14#{i}",
					'fqdn' => "#{hostname_prefix}work#{ format('%02d', i) }.#{$dns_tld}",
					'lb_fqdn_rke2' => "#{hostname_prefix}mast.#{$dns_tld}",
					'nfs_longhorn' => "#{ "/longhorn/#{cluster}" if i <= 3 }"
				}
			end
		}.call

		-> {
			cluster = 'app-deploy'
			hostname_prefix = 'appdepl'
			rke2_version = 'v1.26.15+rke2r1'

			(1..3).each do |i|
				$vms["#{cluster} CP#{i}"] = {
					'node_type' => "#{ 'first ' if i == 1 }downstream control plane",
					'rke2_version' => rke2_version,
					'ip' => "#{$network_prefix}.16.15#{i}",
					'fqdn' => "#{hostname_prefix}mast#{ format('%02d', i) }.#{$dns_tld}",
					'lb_ip_rke2' => "#{$network_prefix}.16.150",
					'lb_fqdn_rke2' => "#{hostname_prefix}mast.#{$dns_tld}",
					'cluster_registration' => "#{ cluster if i == 1 }",
					'nfs_rke2' => "/etcd/#{cluster}",
					'sealed_secrets_key' => SEALED_SECRETS_KEY,
					'sealed_secrets_crt' => SEALED_SECRETS_CRT,
					'extra_manifests' => EXTRA_MANIFESTS_APP_DEPLOY
				}
			end
			(1..2).each do |i|
				$vms["#{cluster} N#{i}"] = {
					'node_type' => 'downstream node',
					'rke2_version' => rke2_version,
					'ip' => "#{$network_prefix}.16.16#{i}",
					'fqdn' => "#{hostname_prefix}work#{ format('%02d', i) }.#{$dns_tld}",
					'lb_fqdn_rke2' => "#{hostname_prefix}mast.#{$dns_tld}",
					'nfs_longhorn' => "#{ "/longhorn/#{cluster}" if i <= 3 }"
				}
			end
		}.call
	)

	[ $vms ].each do |k|
		k.each_value { |v| v.each { v[_1] = _2.call if _2.respond_to?(:call) }}
	end

	## DNS server for querying real resource records (optional).
	# DNS_FORWARDER = ''

	## https://docs.rke2.io/install/private_registry#mirrors
	## https://docs.rke2.io/reference/server_config#agentruntime (system-default-registry)
	# CONTAINER_REGISTRY_MIRROR = 'docker.io'
)

Vagrant.require_version '>= 2.4.3'

Vagrant.configure('2') do |config|
	config.vm.synced_folder $root, '/vagrant', disabled: true

	config.vm.provision 'Routing', run: 'once', type: 'shell', path: 'routing.sh', env: {
		'LOCAL_IPS' => "#{LB_IP_APP_TOOLS} #{LB_IP_APP_DEPLOY}",
	}

	config.vm.define 'Infrastructure' do |config|
		config.vm.box = 'boxomatic/alpine-3.22'
  		config.vm.box_version = '20250719.0.1'

		config.vm.provider('virtualbox') { _1.memory = 192; _1.cpus = 1; _1.customize [ 'modifyvm', :id, '--groups', '/' ]}
		config.vm.network 'private_network', ip: $svc_ip, netmask: $prefix_length, virtualbox__intnet: true
		config.vm.synced_folder $root, '/run/vagrant'

		config.vm.provision 'DNS', run: 'once', type: 'shell', path: 'dns.sh', env: {
			'DNS_TLD' => $dns_tld,

			## https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html#lbAE (--server)
			'DNS_FORWARDER' => DNS_FORWARDER,

			## https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html#lbAE (--address)
			'DNS_RESOURCE_RECORDS' => (
				$vms.each_value.with_object([]) {
					_2 << "address=/#{_1['lb_fqdn_rke2']}/#{_1['lb_ip_rke2']}" if _1['lb_fqdn_rke2'] && _1['lb_ip_rke2']
					_2 << "address=/#{_1['fqdn']}/#{_1['ip']}"
				}.uniq +
				$gitrepo_dns_rr.each_with_object([]) {
					_2 << "address=/#{_1['fqdn']}/#{_1['ip']}"
				} +
				$extra_dns_rr.each_value.with_object([]) {
					_2 << "address=/#{_1['fqdn']}/#{_1['ip']}"
				}
			).join("\n")
		}.reject { _2.nil? }
		config.vm.provision 'NFS', run: 'once', type: 'shell', path: 'nfs-backup.sh', env: {
			## https://nfs.sourceforge.net/nfs-howto/ar01s03.html
			'NFS_EXPORTS' => (
				$vms.each_value.with_object([]) {
					_2 << "#{_1['nfs_rke2']} #{_1['ip']}(rw,sync,no_subtree_check,no_root_squash)" if _1['node_type']&.include?('control plane')
					_2 << "#{_1['nfs_longhorn']} #{_1['ip']}(rw,sync,no_subtree_check,no_root_squash)" if _1['node_type']&.include?('node')
				}.join("\n")
			)
		}
		config.vm.provision 'Git', run: 'once', type: 'shell', path: 'git.sh', env: {
			'FLEET_GITREPO_PATHS' => FLEET_GITREPO_PATHS,
			'FLEET_GITREPO_PORTS' => FLEET_GITREPO_PORTS,

			'FLEET_ROOT_SEALED_SECRET' => FLEET_ROOT_SEALED_SECRET,
			'SEALED_SECRETS_KEY' => SEALED_SECRETS_KEY,

			## Secrets to generate in case the sealed secrets private key can't decrypt the sealed secret. (optional)
			## Syntax:
			##   <namespace> <secret name>
			##   <namespace> <secret name>
			##  ...
			'FLEET_GITREPO_SECRETS' => FLEET_GITREPO_SECRETS
		}.reject { _2.nil? }

		config.vm.post_up_message = <<~EOF
			Accessing the domain names
				Option 1 (recommended)
					FoxyProxy ▸ Options ▸ Proxies ▸ Add ▸ { Hostname: localhost, Port: 8080 } ▸ Save

					vagrant ssh Infrastructure -- '-o DynamicForward localhost:8080'

				Option 2 (only if virtualbox__intnet: false)
					Windows
						OpenVPN Connect ▸ ☰ ▸ Settings ▸ ADVANCED SETTINGS ▸ Allow using local DNS resolvers ▸ ☑    # must be enabled if the VPN is active

						PowerShell:
							Add-DnsClientNrptRule -Namespace "#{$dns_tld}" -NameServers "#{$svc_ip}"    # administrator access rights required
							Get-DnsClientServerAddress    # the local resolver on 127.0.0.1 must be among ServerAddresses

					macOS
						Shell:
							sudo tee /etc/resolve.d/#{$dns_tld} > /dev/null <<-eof 
								name #{$dns_tld}
								nameserver #{$svc_ip}
								port 53
							eof
							scutil --dns

				Option 3 (only if virtualbox__intnet: false)
					Add resource records manually in /etc/hosts or C:\\Windows\\System32\\drivers\\etc\\hosts.

				Links:
				  - https://learn.microsoft.com/en-us/powershell/module/dnsclient
				  - https://getfoxyproxy.org/downloads/#proxypanel

			After suspending the environment for a significant period of time, when resuming it, the CNI addon in each cluster will not work without restarting it:
				kubectl rollout restart --namespace calico-system Deployment,DaemonSet
		EOF
	end

	def vm(config, name:, params:)
		config.vm.define name, autostart: name.match?(/(CP|N)1$/) do |config|
			config.vm.provider('virtualbox') { _1.memory = 5120; _1.cpus = 4 } if name.match?(/^local/)
			config.vm.provider('virtualbox') { _1.memory = 5120; _1.cpus = 4 } if name.match?(/^app.*CP/)
			config.vm.provider('virtualbox') { _1.memory = 5120; _1.cpus = 5 } if name.match?(/^app.*N/)

			config.vm.box = 'bento/ubuntu-20.04'; config.vm.box_version = '202407.23.0'
			config.vm.disk :disk, size: '1TB', name: 'longhorn' if !! params['nfs_longhorn']
			config.vm.synced_folder "#{$root}/run", '/run/vagrant'

			config.vm.hostname = params['fqdn']
			config.vm.network 'private_network', ip: params['ip'], netmask: $prefix_length, virtualbox__intnet: true

			config.vm.provision 'DNS', run: 'once', type: 'shell', path: 'dns.sh', env: {
				'DNS_IP' => $svc_ip,
				'DNS_TLD' => $dns_tld
			}
			config.vm.provision 'Backup', run: 'once', type: 'shell', path: 'nfs-backup.sh', env: {
				'NFS_ADDR' => $extra_dns_rr['nfs_server']['fqdn'],

				## Remote filesystem (fs_spec).
				## https://man7.org/linux/man-pages/man5/fstab.5.html
				'NFS_PATH' => params['nfs_rke2']
			}
			config.vm.provision 'Bootstrap', run: 'once', type: 'shell', path: 'boostrap.sh', env: {
				'TZ' => $tz,

				## https://docs.rke2.io/upgrades/manual_upgrade
				'INSTALL_RKE2_VERSION' => params['rke2_version'],

				## RKE2/kubelet node-ip, Kubernetes InternalIP.
				## https://docs.rke2.io/reference/server_config#agentnetworking
				## https://docs.rke2.io/reference/linux_agent_config#networking
				## https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/
				## https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/node-v1/#NodeStatus
				'IP' => params['ip'],

				## RKE2 fixed registration address.
				## https://docs.rke2.io/install/ha
				'LB_IP_RKE2' => params['lb_ip_rke2'],
				'LB_FQDN_RKE2' => params['lb_fqdn_rke2'],

				## Rancher ingress controller load balancer IP.
				'LB_IP_INGRESS' => params['lb_ip_ingress'],

				## Syntax: [ first ] <cluster type> <role>
				##   - 'first' is only for the first control plane
				##   - cluster type 'upstream' is for Rancher server, 'downstream' is for downstream user cluster nodes
				##   - role is 'control plane' or 'node'
				## https://docs.rke2.io/install/ha#2-launch-the-first-server-node
				## https://ranchermanager.docs.rancher.com/v2.7/reference-guides/rancher-manager-architecture
				## https://kubernetes.io/docs/concepts/overview/components/#core-components
				'NODE_TYPE' => params['node_type'],

				## https://docs.rke2.io/install/private_registry (optional)
				'CONTAINER_REGISTRY' => CONTAINER_REGISTRY,
				'CONTAINER_REGISTRY_USER' => CONTAINER_REGISTRY_USER,
				'CONTAINER_REGISTRY_PASSWORD' => CONTAINER_REGISTRY_PASSWORD,
				'CONTAINER_REGISTRY_MIRROR' => CONTAINER_REGISTRY_MIRROR,

				## Rancher hostname.
				## https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade/install-upgrade-on-a-kubernetes-cluster#5-install-rancher-with-helm-and-your-chosen-certificate-option
				'RANCHER_FQDN' => params['rancher_fqdn'],

				## https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade/resources/add-tls-secrets (optional)
				'TLS_RANCHER_INGRESS_KEY' => params['tls_rancher_ingress_key'],
				'TLS_RANCHER_INGRESS_CRT' => params['tls_rancher_ingress_crt'],
				'TLS_CA_CRT' => params['tls_ca_crt'],

				## https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade/resources/bootstrap-password (optional)
				'BOOTSTRAP_PASSWORD' => params['bootstrap_password'],

				## Syntax: [ <cluster name> ... ]
				##   - any number of downstream clusters for the upstream control plane
				##   - no more than one cluster name for the downstream control plane that it represents in Rancher server
				'CLUSTER_REGISTRATION' => params['cluster_registration'],

				## https://github.com/bitnami-labs/sealed-secrets/?tab=readme-ov-file#public-key--certificate (optional)
				'SEALED_SECRETS_KEY' => params['sealed_secrets_key'],
				'SEALED_SECRETS_CRT' => params['sealed_secrets_crt'],

				## https://fleet.rancher.io/gitrepo-add
				'FLEET_ROOT_GITREPO' => params['fleet_root_gitrepo'],
				'FLEET_ROOT_SEALED_SECRET' => params['fleet_root_sealed_secret'],  # optional
				'FLEET_GITREPO_SECRETS' => params['fleet_gitrepo_secrets'],        # optional
				'FLEET_SSH_KNOWN_HOSTS' => params['fleet_known_hosts'],            # optional

				## Extra manifests to install in the cluster. (optional)
				'EXTRA_MANIFESTS' => params['extra_manifests']
			}.reject { _2.nil? }
		end
	end

	$vms.each { vm( config, name: _1, params: _2 )}
end

