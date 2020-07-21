local promtail = (import '../../components/promtail.libsonnet') + {
  _config+:: {
    name: 'promtail',
    namespace: 'promtail',
    version: '1.5.0',
    image: 'docker.io/grafana/promtail:1.5.0',
    tenant: 'dev',
    promtail_secrets_name: 'promtail',
    observatorium_log_url: 'http://localhost:3030',
  },
};

promtail.manifests
