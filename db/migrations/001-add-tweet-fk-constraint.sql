-- Tweet テーブルの外部キー制約を追加
-- 実行タイミング: mito:ensure-table-exists 実行後

ALTER TABLE tweet ADD CONSTRAINT fk_tweet_user_id
  FOREIGN KEY (user_id) REFERENCES "user"(id) ON DELETE CASCADE;
