# マイグレーション管理ガイド

Mitoが自動生成しないスキーマ変更（FK制約、インデックス）を管理するためのディレクトリです。

## ファイル構成

| ファイル | 内容 | 依存 |
|---------|------|------|
| 001-add-tweet-fk-constraint.sql | tweetテーブルのFK制約 | tweetテーブル存在後 |
| 002-add-tweet-indexes.sql | tweetテーブルのインデックス | tweetテーブル存在後 |
| 003-add-user-not-null-constraints.sql | userテーブルのNOT NULL制約 | userテーブル存在後 |

## 適用方法

### 前提条件

1. Mitoでテーブルが作成済みであること
2. PostgreSQLに接続可能であること

### 開発環境

```bash
psql -d twitter_like -f db/migrations/001-add-tweet-fk-constraint.sql
psql -d twitter_like -f db/migrations/002-add-tweet-indexes.sql
psql -d twitter_like -f db/migrations/003-add-user-not-null-constraints.sql
```

### テスト環境

```bash
psql -d twitter_like_test -f db/migrations/001-add-tweet-fk-constraint.sql
psql -d twitter_like_test -f db/migrations/002-add-tweet-indexes.sql
psql -d twitter_like_test -f db/migrations/003-add-user-not-null-constraints.sql
```

## 注意事項

- マイグレーションは番号順に適用すること
- 適用済みかどうかは `\d tweet` で確認可能
- 将来的には `cl-migratum` 等のマイグレーション管理ツールの導入を検討
