# マイグレーション管理ガイド

Mitoが自動生成しないスキーマ変更（FK制約、インデックス）を管理するためのディレクトリです。

## ファイル構成

| ファイル | 内容 | 依存 |
|---------|------|------|
| 001-add-tweet-fk-constraint.sql | tweetテーブルのFK制約 | tweetテーブル存在後 |
| 002-add-tweet-indexes.sql | tweetテーブルのインデックス | tweetテーブル存在後 |
| 003-add-user-not-null-constraints.sql | userテーブルのNOT NULL制約 | userテーブル存在後 |
| 004-update-tweet-indexes.sql | Phase 2: インデックス最適化 | 002適用後 |

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

**004-update-tweet-indexes.sql の適用（特殊）:**

`CREATE INDEX CONCURRENTLY` / `DROP INDEX CONCURRENTLY` はトランザクションブロック外で実行が必要です。

```bash
# psqlで接続して個別に実行
psql -d twitter_like

# 1. 新インデックス作成
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tweet_user_id_id ON tweet (user_id, id DESC);

# 2. 作成確認
\d tweet

# 3. 旧インデックス削除（新インデックス存在確認後）
DROP INDEX CONCURRENTLY IF EXISTS idx_tweet_user_id_created_at_id;
```

### テスト環境

```bash
psql -d twitter_like_test -f db/migrations/001-add-tweet-fk-constraint.sql
psql -d twitter_like_test -f db/migrations/002-add-tweet-indexes.sql
psql -d twitter_like_test -f db/migrations/003-add-user-not-null-constraints.sql
# 004はテスト環境でも同様に個別実行
```

## 注意事項

- マイグレーションは番号順に適用すること
- 適用済みかどうかは `\d tweet` で確認可能
- 将来的には `cl-migratum` 等のマイグレーション管理ツールの導入を検討
