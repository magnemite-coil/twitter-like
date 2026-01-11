-- Phase 2: ORDER BY を id DESC に統一するためのインデックス変更
-- 実行タイミング: psql で個別に実行（トランザクション外で実行が必要）
-- 理由: CREATE INDEX CONCURRENTLY / DROP INDEX CONCURRENTLY はトランザクションブロック内では実行不可

-- 1. 新インデックス作成（オンライン、ロックなし）
-- カーソルベースページネーション用（user_id, id DESC）
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tweet_user_id_id
ON tweet (user_id, id DESC);

-- 2. 旧インデックス削除（新インデックス作成成功後に実行）
-- 注意: 新インデックスが正常に作成されたことを確認してから実行すること
DROP INDEX CONCURRENTLY IF EXISTS idx_tweet_user_id_created_at_id;

-- 確認コマンド:
-- \d tweet
-- 期待される結果: idx_tweet_user_id_id が存在し、idx_tweet_user_id_created_at_id が削除されていること
