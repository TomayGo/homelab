# Phase 2：R2へのバックアップ（計画。2026-10-09に有効化した。実施記録は`docs/phase2.md`）

## 方針（2026-10-09決定）

- 保存先はCloudflare R2。無料枠（10GB）に収める
- 対象は、CNPG（`grafana-db`、`netbox-db`）とアプリのPVC。手順書の「CNPGのみ」から広げた
- 圧縮はzstd -19。圧縮率を実測して決めた（下記）

## 構成

### CNPG（Barman Cloud Plugin）

- cert-manager v1.21.2（プラグインの前提）とplugin-barman-cloud 0.8.1（v0.15.1）は、Argo CDのApplicationとして導入済み。どちらもSynced/Healthy
- ObjectStore `r2`をnamespaceごとに作る（monitoring、netbox）。`destinationPath: s3://<bucket>/cnpg/`。Clusterごとに`serverName`（Cluster名）で分かれる
- 圧縮
  - WALはzstd
  - ベースバックアップはbzip2（プラグインのdata圧縮は、bzip2、gzip、lz4、snappyだけでzstdがない）
- ベースバックアップは週1回（日曜4:00）。`retentionPolicy: 30d`（WALで30日分のPITR）
- 定義は`k8s/apps/{cloudnative-pg,netbox}/backup-pending/backup-r2.yaml`。有効化スクリプトが値を埋めて`manifests/`に移す

### PVC（tar → zstd -19 → R2）

- ツールイメージは`ghcr.io/tomaygo/backup-tools`（`images/backup-tools/`。alpine 3.24.2 + zstd、GNU tar、sqlite3、rclone）。GitHub Actionsでビルドする
- 各namespaceにCronJobを置いた。**今は`suspend: true`**
- PVCはRWOなので、`podAffinity`で、PVCを使っているPodと同じノードで動かす
- SQLiteは、`sqlite3 .backup`で取り直して`.sqlite-backup/`に入れる（動いているDBをそのままtarしない）
- 2世代を残す（ファイル名はUTC時刻）

| CronJob | 時刻 | 対象 | 除外 | 実行ユーザー |
|---|---|---|---|---|
| dns/pvc-backup-agh-primary | 3:10 | conf、work | filters、lost+found | root |
| dns/pvc-backup-agh-replica | 3:20 | conf、work | filters、lost+found | root |
| monitoring/pvc-backup-prometheus | 3:30 | prometheus-0のブロック | wal、chunks_head | 1000:2000 |
| ai/pvc-backup-openwebui | 3:50 | data（SQLite 2つは取り直す） | cache | root |
| pricetracker/pvc-backup | 3:55 | data（SQLite） | - | 65532 |
| netbox/pvc-backup-media | 3:58 | media | - | 1000 |

## 圧縮の比較（実測）

| 方式 | AGHのクエリログ | Prometheusのブロック |
|---|---|---|
| gzip -6 | 7.4倍 | 1.8倍 |
| zstd -3 | 9.7倍 | 2.2倍 |
| **zstd -19** | **15.9倍** | **3.3〜3.6倍** |
| xz -9 | 16.1倍 | 3.5倍 |
| restic `--compression max` | 10.9倍 | 2.3倍 |

- resticは差分を取れるが、圧縮が弱く、1世代目だけで約4.2GBになる。このため、zstd -19で丸ごと取って2世代残す方式にした

## 試運転（DRY_RUN、R2には送らない）の結果

2026-10-09に、CronJobの定義に`DRY_RUN=1`を足した一時的なJobで、6つすべてを実行した。どのJobも対象のPodと同じノードで起動し、ghcrからのイメージ取得とPVCのマウントも成功した。

| バックアップ | 元のサイズ | 圧縮後 | 所要時間 |
|---|---|---|---|
| dns/agh-primary | 約2.95GB | 182MiB | 575秒 |
| dns/agh-replica | 約2.95GB | 182MiB | 650秒 |
| monitoring/prometheus | 約5.4GB | 1,498MiB | 404秒 |
| ai/openwebui | 約38MB（cache除く） | 4MiB | 4秒 |
| pricetracker/data | 20KB | 1MiB未満 | 1秒 |
| netbox/media | ほぼ空 | 1MiB未満 | 0秒 |

- 1世代あたり、現在は約1.9GB
- AGHのクエリログは90日保持で1台約6GB、Prometheusは15日保持で約7.3GBになるので、定常時は約2.8GBの見込み
- 2世代で約5.6GB。CNPG（0.5GB以下）と合わせて約6GBで、無料枠（10GB）に約4GBの余裕がある
- dns/agh-replica（3:20から約11分）とmonitoring/prometheus（3:30から）は同じノード（talos-cp-2）なので、少し重なる。CPUのlimitは各2コア

## 有効にする手順（ユーザー）

1. Cloudflare R2でバケットを作り、そのバケットだけに書き込めるAPIトークン（S3互換のAccess Key ID / Secret）を発行する
2. pve-1で、次のスクリプトを実行する
   - 入力はアカウントID、バケット名、Access Key ID、Secret（Secretは画面に表示されない）
   - 5つのnamespaceのSecret `r2-backup`（SOPS）、ObjectStoreとScheduledBackup、Clusterへのプラグインの追加、CronJobの停止解除をまとめて書き換える

   ```sh
   cd /root/homelab && scripts/enable-r2-backup.sh
   ```

3. `git diff`を確認してコミット・pushし、Argo CDで次の順にsyncする
   1. adguard-home、kube-prometheus-stack、openwebui、pricetracker、netbox（Secretと、CronJobの停止解除）
   2. cloudnative-pg、netbox（ObjectStore、ScheduledBackup、Clusterのプラグイン）
   - **Clusterにプラグインを足すと、PostgreSQLが再起動する**。Grafana、NetBoxが一瞬止まる
4. 確認する
   - `kubectl -n monitoring get cluster grafana-db -o jsonpath='{.status.conditions}'`で、ContinuousArchivingがTrueになること
   - `kubectl create job --from=cronjob/<名前> -n <ns> <job名>`でPVCのバックアップを1回走らせ、R2にファイルができること
   - 最初のベースバックアップは、`kubectl cnpg backup`か、ScheduledBackupに`immediate: true`を足して取る
5. リストア試験（手順書2-3）：別名のClusterを`bootstrap.recovery`で作る（下記）

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
          barmanObjectName: r2
          serverName: grafana-db
```

このClusterはArgo CDの管理外として`kubectl apply`で作り、Grafanaのテーブルの件数が元と一致することを確認したら削除する。PVCのバックアップも、1つは一時Podで展開して中身を確かめる（`docs/recovery.md`）。
