# Woo 本番起動手順（systemd テンプレート）

## 概要
- `bin/start-woo.sh` を使って Woo（vendored fast-http/woo）を起動する。
- Quicklisp は `QL_LOCAL_PROJECTS=vendor` と central-registry 追加をスクリプト内で設定済み。
- `APP_ENV` デフォルトは `production`、`APP_PORT` デフォルトは `8080`。

## 事前準備
1. `.env` に本番用設定を入れる（DB/Redis/CSRF/SESSION_SECRET など）。
2. 実行ユーザがリポジトリ配下に書き込みできること（`var/cache` を使用）。
3. SBCL がインストール済みであること。

## systemd ユニット例
`/etc/systemd/system/twitter-like.service`

```
[Unit]
Description=Twitter-like (Woo)
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/opt/twitter-like
Environment=APP_ENV=production
Environment=APP_PORT=8080
Environment=XDG_CACHE_HOME=/opt/twitter-like/var/cache
ExecStart=/opt/twitter-like/bin/start-woo.sh
Restart=on-failure
RestartSec=5
StandardOutput=append:/opt/twitter-like/var/log/woo.log
StandardError=append:/opt/twitter-like/var/log/woo.log

[Install]
WantedBy=multi-user.target
```

### ポイント
- vendored fast-http/woo を必ず読むため、サービス起動は `bin/start-woo.sh` で統一する。
- `XDG_CACHE_HOME` を明示すると FASL の書き込み先がリポジトリ配下に固定される。
- ログはシンプルにファイル追記（必要なら journalctl 併用）。

## 起動・停止
```
sudo systemctl daemon-reload
sudo systemctl enable twitter-like
sudo systemctl start twitter-like
sudo systemctl status twitter-like
# 停止
sudo systemctl stop twitter-like
```

## 手動起動（デバッグ）
```
APP_ENV=production APP_PORT=8080 bin/start-woo.sh
```
