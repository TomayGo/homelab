# netbox

- chart: `netbox/netbox` 8.3.91（repo `https://charts.netbox.oss.netboxlabs.com/`）、release名 `netbox`、namespace `netbox`
- NetBox v4.7.2。2026-10-09 に CT903（NetBox v4.3.2、PostgreSQL 15）から `pg_dump -Fc` → `pg_restore --no-owner --role=netbox` で移行し、起動時に 4.3→4.7 のマイグレーションが走った
- DB: CNPG `netbox-db`（2 instances）。chart側は `externalDatabase` で `netbox-db-rw` と Secret `netbox-db-app` を参照
- Redis: chart同梱の valkey（`bitnami/valkey:latest`）は使わず、`manifests/valkey.yaml` の `valkey/valkey` をバージョン固定
- media の PVC は RWO。web は `Recreate`、worker は podAffinity で web と同じノードに置く
- 公開: tailnet の `netbox.ayu-mamba.ts.net`（`manifests/service-tailnet.yaml`）
- Secret: `manifests/netbox-config.enc.yaml`（secret_key は CT903 から引き継ぎ、api_token_peppers は新規）、`manifests/netbox-superuser.enc.yaml`（admin は既存なので起動時の作成はスキップされる）

Phase 1 以降は Argo CD の Application `netbox`（`k8s/root/netbox.yaml`）で管理する。Secret は `manifests/secret-generator.yaml`（KSOPS）で復号される。
