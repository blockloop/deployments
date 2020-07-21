local promtail = (import '../../components/promtail.libsonnet') + {
  _config+:: {
    name: 'promtail',
    namespace: 'promtail',
    version: 'v2.24.0',
    image: 'docker.io/grafana/loki:master-815c475',
    tenant: 'dev',
    promtail_secrets_name: 'promtail',
    observatorium_log_url: '',
  },
};

promtail.manifests
