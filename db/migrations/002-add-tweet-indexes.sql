-- Tweet テーブルのインデックスを追加
-- 実行タイミング: mito:ensure-table-exists 実行後

-- ユーザーのツイート一覧取得用
CREATE INDEX IF NOT EXISTS idx_tweet_user_id ON tweet (user_id);

-- タイムライン表示用（新しい順でソート）
CREATE INDEX IF NOT EXISTS idx_tweet_created_at ON tweet (created_at DESC);

-- 複合インデックス（ユーザーのツイートを新しい順で取得）
-- created_at DESC, id DESC で並べ替えるため、idも含める
CREATE INDEX IF NOT EXISTS idx_tweet_user_id_created_at_id ON tweet (user_id, created_at DESC, id DESC);
