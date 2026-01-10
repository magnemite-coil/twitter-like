-- Tweet テーブルの外部キー制約を追加
-- 実行タイミング: mito:ensure-table-exists 実行後
-- 冪等性: 既存の制約がある場合はスキップ

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.table_constraints
    WHERE constraint_name = 'fk_tweet_user_id'
      AND table_name = 'tweet'
  ) THEN
    ALTER TABLE tweet ADD CONSTRAINT fk_tweet_user_id
      FOREIGN KEY (user_id) REFERENCES "user"(id) ON DELETE CASCADE;
    RAISE NOTICE 'Constraint fk_tweet_user_id created.';
  ELSE
    RAISE NOTICE 'Constraint fk_tweet_user_id already exists, skipping.';
  END IF;
END $$;
