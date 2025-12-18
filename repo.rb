fleet_repo_path = File.expand_path( 'run/repo-ssh-fleet', __dir__ )

FLEET_ROOT_GITREPO = File.read( "#{fleet_repo_path}/fleet-configuration/local/fleet-cd-repo.yaml" )
# FLEET_ROOT_SEALED_SECRET = File.read( "#{fleet_repo_path}/fleet-configuration/local/git-fleet-ssh-local.yaml" )

-> {
	docs = Dir[ "#{fleet_repo_path}/fleet-configuration/{local,gitrepos}/*.yaml" ].flat_map { YAML.load_stream( File.read( _1 ))}
	repos = docs
		.map { _1.dig('spec', 'repo') }
		.compact
		.map { _1.match( %r{git@([^:/]+):(\d+)?(.+)|https?://([^/]+)/(.+)} )}

	FLEET_GITREPO_ADDRS = repos.map { _1[1] }.compact.uniq.join(' ')
	FLEET_GITREPO_PORTS = repos.map { _1[2] }.compact.uniq.join(' ')
	FLEET_GITREPO_PATHS = repos.map { _1[3] }.compact.uniq.join(' ')

	FLEET_ROOT_SEALED_SECRET || FLEET_GITREPO_SECRETS = docs
		.map { ns = _1['metadata']['namespace']; n = _1['spec']['clientSecretName']; "#{ns} #{n}" unless n.to_s.empty? }
		.compact.uniq
		.join("\n")
}.call

NFS_ADDR = YAML.load_file( "#{fleet_repo_path}/fleet-configuration/bundles/longhorn/values/longhorn-default-values.yaml" )['defaultBackupStore']['backupTarget'][/nfs:\/\/(.*):/, 1]

LB_IP_APP_TOOLS = YAML.load_file( "#{fleet_repo_path}/fleet-configuration/bundles/nginx/config/overlays/app-tools/ip-address-pool.yaml" )['spec']['addresses'][0].split('/').first
LB_IP_APP_DEPLOY = YAML.load_file( "#{fleet_repo_path}/fleet-configuration/bundles/nginx/config/overlays/app-deploy/ip-address-pool.yaml" )['spec']['addresses'][0].split('/').first

LONGHORN_ADDR_APP_TOOLS = YAML.load_file( "#{fleet_repo_path}/fleet-configuration/bundles/longhorn/values/longhorn-app-tools-values.yaml" )['ingress']['host']
GRAFANA_ADDR_APP_TOOLS = YAML.load_file( "#{fleet_repo_path}/fleet-configuration/bundles/monitoring/values/monitoring-app-tools-values.yaml" )['grafana']['ingress']['hosts'][0]

LONGHORN_ADDR_APP_DEPLOY = YAML.load_file( "#{fleet_repo_path}/fleet-configuration/bundles/longhorn/values/longhorn-app-deploy-values.yaml" )['ingress']['host']
GRAFANA_ADDR_APP_DEPLOY = YAML.load_file( "#{fleet_repo_path}/fleet-configuration/bundles/monitoring/values/monitoring-app-deploy-values.yaml" )['grafana']['ingress']['hosts'][0]

