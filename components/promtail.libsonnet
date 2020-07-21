local k = (import 'ksonnet/ksonnet.beta.4/k.libsonnet');
local config = (import 'promtail_scrapeconfig.libsonnet');

config {
  _config:: {
    container_root_path: '/var/lib/docker',
    external_labels: {},
    image: error 'must provide image',
    name: 'promtail',
    namespace: error 'must provide namespace',
    tenant: error 'must provide tenant id',
    version: error 'must provide version',
    observatorium_log_url: error 'must provide observatorium_log_url',

    commonLabels:: {
      'app.kubernetes.io/name': 'promtail',
      'app.kubernetes.io/instance': 'promtail',
      'app.kubernetes.io/version': $._config.version,
    },

    promtail_config+:: {
      // https://github.com/grafana/loki/blob/master/docs/clients/promtail/configuration.md#client_config
      clients: [{
        url: $._config.observatorium_log_url,
        tenant_id: $._config.tenant,
        external_labels: $._config.external_labels,
        tls_config: {
          ca_file: '/etc/promtail/secrets/ca.pem',
          cert_file: '/etc/promtail/secrets/cert.pem',
          key_file: '/etc/promtail/secrets/cert.key',
        },
      }],
      pipeline_stages: [{
        docker: {},
      }],
    },
    promtail_cluster_role_name: 'promtail',
    promtail_configmap_name: 'promtail',
    promtail_secrets_name: error 'Must provide the existing secrets name with ca.pem, cert.pem, and cert.key',
    promtail_pod_name: 'promtail',
    promtail_config_file_path: '/etc/promtail/config/config.yaml',
  },

  local configMap = k.core.v1.configMap,
  local daemonSet = k.apps.v1.daemonSet,
  local volume = k.apps.v1.daemonSet.mixin.spec.template.spec.volumesType,
  local container = daemonSet.mixin.spec.template.spec.containersType,
  local containerPort = container.portsType,

  local clusterRole = k.rbac.v1.clusterRole,
  local policyRule = clusterRole.rulesType,
  local clusterRoleBinding = k.rbac.v1beta1.clusterRoleBinding,
  local subject = clusterRoleBinding.subjectsType,
  local serviceAccount = k.core.v1.serviceAccount,

  configMap::
    configMap.new($._config.promtail_configmap_name) +
    configMap.mixin.metadata.withNamespace($._config.namespace) +
    configMap.mixin.metadata.withLabels($._config.commonLabels) +
    configMap.withData({
      'config.yaml': std.manifestYamlDoc($._config),
    }),

  rbac:: {
    local rules = [
      policyRule.new() +
      policyRule.withApiGroups(['']) +
      policyRule.withResources(['nodes', 'nodes/proxy', 'services', 'endpoints', 'pods']) +
      policyRule.withVerbs(['get', 'list', 'watch']),
    ],

    service_account:
      serviceAccount.new($._config.promtail_cluster_role_name),

    cluster_role:
      clusterRole.new() +
      clusterRole.mixin.metadata.withName($._config.promtail_cluster_role_name) +
      clusterRole.withRules(rules),

    cluster_role_binding:
      clusterRoleBinding.new() +
      clusterRoleBinding.mixin.metadata.withName($._config.promtail_cluster_role_name) +
      clusterRoleBinding.mixin.roleRef.withApiGroup('rbac.authorization.k8s.io') +
      clusterRoleBinding.mixin.roleRef.withKind('ClusterRole') +
      clusterRoleBinding.mixin.roleRef.withName($._config.promtail_cluster_role_name) +
      clusterRoleBinding.withSubjects([
        subject.new() +
        subject.withKind('ServiceAccount') +
        subject.withName($._config.promtail_cluster_role_name) +
        subject.withNamespace($._config.namespace),
      ]),
  },

  promtail_container::
    container.new('promtail', $._images.promtail) +
    container.withPorts(containerPort.newNamed(name='http-metrics', containerPort=80)) +
    container.withArgsMixin([
      '-config.file=' + $._config.promtail_config_file_path,
    ]) +
    container.withEnv([
      container.envType.fromFieldPath('HOSTNAME', 'spec.nodeName'),
    ]) +
    container.mixin.readinessProbe.httpGet.withPath('/ready') +
    container.mixin.readinessProbe.httpGet.withPort(80) +
    container.mixin.readinessProbe.withInitialDelaySeconds(10) +
    container.mixin.readinessProbe.withTimeoutSeconds(1) +
    container.withVolumeMounts({
      name: 'shared',
      mountPath: '/var/shared',
      readOnly: false,
    }) +
    container.withVolumeMounts([
      {
        name: 'secrets',
        mountPath: '/etc/promtail/secrets',
        readOnly: true,
      },
      {
        name: 'config',
        mountPath: '/etc/promtail/config',
        readOnly: false,
      },
      {
        name: 'varlog',
        mountPath: '/var/log',
        readOnly: true,
      },
      {
        name: 'varlibdockercontainers',
        mountPath: '/var/lib/docker/containers',
        readOnly: true,
      },
    ]),

  daemonSet::
    daemonSet.new() +
    daemonSet.mixin.metadata.withName($._config.promtail_pod_name) +
    daemonSet.mixin.spec.template.spec.withContainers([$.promtail_container]) +
    daemonSet.mixin.spec.template.spec.withServiceAccount($._config.promtail_cluster_role_name) +
    daemonSet.mixin.spec.template.spec.withVolumes({ emptyDir: {}, name: 'shared' }) +
    daemonSet.mixin.spec.template.spec.withVolumes([
      volume.fromSecret('secrets', $._config.promtail_secrets_name),
      volume.fromConfigMap('config', $._config.promtail_configmap_name),
      volume.fromHostPath('varlog', '/var/log'),
      volume.fromHostPath('varlibdockercontainers', $._config.container_root_path + '/containers'),
    ]),

  manifests+:: {
    'promtail-10-config-map.json': $.configMap,
  } + {
    ['promtail-15-rbac_' + f + '.json']: $.rbac[f]
    for f in std.objectFields($.rbac)
  } + {
    'promtail-20-daemonset.json': $.daemonSet,
  },
}
