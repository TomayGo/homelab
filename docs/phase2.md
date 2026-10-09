# Phase 2 実施記録（2026-10-09完了）

計画と方針は`docs/phase2-plan.md`にある。ここには、有効にしたときの記録だけを書く。

## 有効化

- ユーザーがCloudflare R2にバケット`homelab-backup`（Standard）を作った。Account APIトークン（Object Read & Write、このバケットだけ）も発行した
- ユーザーがpve-1で`scripts/enable-r2-backup.sh`を実行した。認証情報はチャットを通していない
- 生成されたファイルを確認した。5つの`r2-backup.enc.yaml`は、値がすべて暗号化されている。そのあとコミットした（`156c84c`）
- Argo CDのsync順：kube-prometheus-stack → adguard-home → openwebui → pricetracker → cloudnative-pg → netbox

## 起きたこと

- **Clusterにプラグインを足すと、primaryが切り替えなしで再起動した**。grafana-dbは約4分止まった（11:44〜11:48 UTC）
  - 古いPodは、サイドカーがないのにWALをアーカイブしようとして失敗した。そのあいだ、終了処理が進まなかった
  - netbox-dbは短時間で戻った
- sync後、2つのClusterがOutOfSyncのまま残った
  - CNPGが`plugins[].enabled: true`を既定値で補ったため
  - Gitにも`enabled: true`を書いてそろえた
- `ObjectStore`のendpointURLには、Cloudflareのアカウントを示すIDが平文で入っている。アカウントIDは認証情報ではない（キーがなければ使えない）。そのため、そのままにした

## 確認

| 確認項目 | 結果 |
|---|---|
| WALの継続アーカイブ | grafana-db、netbox-dbとも`ContinuousArchiving=True` |
| CNPGの初回ベースバックアップ（Backup `*-initial`） | 2つとも`completed` |
| PVCの初回バックアップ（CronJobから手動のJob） | 6つとも成功。agh-primary 184MiB、agh-replica 184MiB、prometheus 1.55GiB、openwebui 4.2MiB、netbox media 73B、pricetracker 2KiB（事前の見積もりどおり） |
| CNPGのリストア試験 | 別名のCluster`grafana-db-restoretest`を`bootstrap.recovery`で作った。テーブル数87、`migration_log` 713件、`kv_store` 11件が元と一致した。確認後に削除した |
| PVCのリストア試験 | agh-primaryの最新のアーカイブをR2から読み、zstdで展開し、tarで最後まで読めた。`AdGuardHome.yaml`、`querylog.json`（3.1GB）、`stats.db`、`sessions.db`が入っていた |

- PVCのアーカイブを手で読むときは、Secret `r2-backup`のほかに、環境変数`RCLONE_CONFIG_R2_TYPE=s3`と`RCLONE_CONFIG_R2_PROVIDER=Cloudflare`も要る。この2つはSecretに入っておらず、CronJobの`env`で渡している

## スケジュール

| 対象 | 時刻（JST） | 残す量 |
|---|---|---|
| PVC（6つ） | 毎日3:10〜3:58 | 2世代 |
| CNPGのベースバックアップ | 毎週日曜4:00 | 30日（WALで任意の時点に戻せる） |
| CNPGのWAL | 常時 | 30日 |

## Phase 2の完了条件

- [x] CNPGのバックアップがR2に取れていて、別名のClusterに戻せる
- [x] PVCのバックアップがR2に取れていて、展開できる
