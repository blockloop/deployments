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
    tls_ca_file: error 'must provide tls ca_file',
    tls_cert_file: error 'must provide tls cert_file',
    tls_key_file: error 'must provide tls key_file',
    version: error 'must provide version',

    commonLabels:: {
      'app.kubernetes.io/name': 'promtail',
      'app.kubernetes.io/instance': 'promtail',
      'app.kubernetes.io/version': promtail._config.version,
    },

    promtail_config+:: {
      // https://github.com/grafana/loki/blob/master/docs/clients/promtail/configuration.md#client_config
      clients: [{
        url: error 'TODO get url from observatorium',
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

  configMap::
    configMap.new($._config.promtail_configmap_name) +
    configMap.mixin.metadata.withNamespace($._config.namespace) +
    configMap.mixin.metadata.withLabels($._config.commonLabels) +
    configMap.withData({
      'config.yaml': std.manifestYamlDoc($._config),
    }),

  rbac:: {
    local policyRule = k.rbac.v1beta1.policyRule,
    local clusterRole = k.rbac.v1beta1.clusterRole,
    local clusterRoleBinding = k.rbac.v1beta1.clusterRoleBinding,
    local subject = k.rbac.v1beta1.subject,
    local serviceAccount = k.core.v1.serviceAccount,
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

  local container = k.core.v1.container,
  promtail_container::
    container.new('promtail', $._images.promtail) +
    container.withPorts(k.core.v1.containerPort.new(name='http-metrics', port=80)) +
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
    container.withVolumeMounts({
      name: 'secrets',
      mountPath: '/etc/promtail/secrets',
      readOnly: true,
    }) +
    container.withVolumeMounts({
      name: 'config',
      mountPath: '/etc/promtail/config',
      readOnly: false,
    }) +
    container.withVolumeMounts({
      name: 'varlog',
      mountPath: '/var/log',
      readOnly: true,
    }) +
    container.withVolumeMounts({
      name: 'varlibdockercontainers',
      mountPath: '/var/lib/docker/containers',
      readOnly: true,
    }),

  local ds = k.apps.v1.daemonSet,
  daemonSet::
    ds.new($._config.promtail_pod_name, [$.promtail_container]) +
    ds.mixin.spec.template.spec.withServiceAccount($._config.promtail_cluster_role_name) +
    ds.mixin.spec.template.spec.withVolumes({ emptyDir: {}, name: 'shared' }) +
    ds.mixin.spec.template.spec.withVolumes(k.core.v1.volume.fromSecret('secrets', $._config.promtail_secrets_name)) +
    ds.mixin.spec.template.spec.withVolumes(k.core.v1.volume.fromConfigMap('config', $._config.promtail_configmap_name)) +
    ds.mixin.spec.template.spec.withVolumes(k.core.v1.volume.fromHostPath('varlog', '/var/log')) +
    ds.mixin.spec.template.spec.withVolumes(k.core.v1.volume.fromHostPath('varlibdockercontainers', $._config.container_root_path + '/containers')),

  manifests+:: {
    '10-promtail-config-map.json': $.configMap,
  } + {
    ['15-rbac_' + f + '.json']: $.rbac[f]
    for f in std.objectFields($.rbac)
  } + {
    '20-daemonset.json': $.daemonSet,
  },
}
