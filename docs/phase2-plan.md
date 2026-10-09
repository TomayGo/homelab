# Phase 2 計画（下書き、ブランチ`phase2-prep`）

外部S3の契約先が決まったら、このファイルの`<…>`を埋めて`main`にマージする。

## 前提の確認結果（未確認事項#8）

- Barman Cloud Plugin v0.15.1（chart `cnpg/plugin-barman-cloud` 0.8.1）
- CNPGは1.26以上が必要。現在は1.30.0なので満たしている
- **cert-managerが必須**。プラグインとCNPG operatorの間のmTLS証明書を発行する。現在は未導入なので、`jetstack/cert-manager` v1.21.2を先に入れる
- プラグインは、CNPG operatorと同じnamespace（`cnpg-system`）に入れる必要がある
- 対象のClusterは2つある。`monitoring/grafana-db`と、2026-10-09に追加した`netbox/netbox-db`

## 手順

1. このブランチの`k8s/root/cert-manager.yaml`と`k8s/root/plugin-barman-cloud.yaml`を`main`に入れ、cert-manager → plugin-barman-cloudの順にsyncする
2. S3のバケットと、そのバケット専用のアクセスキーを作る
3. 認証情報をSOPSで暗号化する。ObjectStoreはnamespaceごとに必要なので、`monitoring`と`netbox`の両方に置く
   - `k8s/apps/cloudnative-pg/manifests/s3-credentials.enc.yaml`（monitoring）
   - `k8s/apps/netbox/manifests/s3-credentials.enc.yaml`（netbox）
4. 下のObjectStore、`spec.plugins`、ScheduledBackupを各manifestsに追加し、syncする
5. 最初のバックアップが成功し、WALが溜まることを確認する
6. リストアを試験する（後述）

## マニフェスト

```yaml
# Secret（SOPS で暗号化する）
apiVersion: v1
kind: Secret
metadata:
  name: s3-credentials
  namespace: monitoring          # netbox 側にも同じものを置く
stringData:
  ACCESS_KEY_ID: <…>
  ACCESS_SECRET_KEY: <…>
---
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: s3-backup
  namespace: monitoring          # netbox 側にも同じものを置く
spec:
  retentionPolicy: "30d"         # 保持期間（要決定）
  configuration:
    destinationPath: s3://<bucket>/cnpg/
    endpointURL: <https://<account>.r2.cloudflarestorage.com など>
    s3Credentials:
      accessKeyId:
        name: s3-credentials
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: s3-credentials
        key: ACCESS_SECRET_KEY
    wal:
      compression: gzip
    data:
      compression: gzip
```

Clusterに追加する設定（`grafana-db`、`netbox-db`の両方）：

```yaml
spec:
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: s3-backup
```

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: grafana-db-daily         # netbox-db-daily も同様
  namespace: monitoring
spec:
  schedule: "0 0 3 * * *"        # 秒 分 時 … の6フィールド。毎日3:00
  backupOwnerReference: self
  cluster:
    name: grafana-db
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

- `serverName`はClusterの名前が既定値なので、2つのClusterで同じ`destinationPath`を共有しても混ざらない
- Clusterに`spec.plugins`を足すと、`archive_command`が変わってPostgreSQLが再起動する（`primaryUpdateMethod: restart`）。夜間など、Grafanaが一瞬止まってもよい時間に行う

## リストア試験

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: grafana-db-restore-test
  namespace: monitoring
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie
  storage:
    storageClass: ceph-rbd
    size: 5Gi
  bootstrap:
    recovery:
      source: origin
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: s3-backup
          serverName: grafana-db
```

このClusterは、Argo CDの管理外として`kubectl apply`で作る。Grafanaのテーブルの件数が元と一致することを確認したら削除する。
