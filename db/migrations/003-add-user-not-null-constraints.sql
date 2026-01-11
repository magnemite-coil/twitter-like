-- 003-add-user-not-null-constraints.sql
-- userテーブルのusername, passwordカラムにNOT NULL制約を追加
--
-- 背景: Mitoモデル定義で :not-null t を追加したが、
-- Mito:ensure-table-exists は既存カラムの制約を変更しない
--
-- 前提条件:
-- - userテーブルが存在すること
-- - username, password カラムに NULL 値が存在しないこと
--
-- 確認方法:
-- SELECT COUNT(*) FROM "user" WHERE username IS NULL OR password IS NULL;
-- → 0件であることを確認してから実行

-- NOT NULL制約を追加（冪等性を考慮し、既に設定されている場合はスキップ）
DO $$
BEGIN
    -- username カラムの NOT NULL 制約
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'user'
        AND column_name = 'username'
        AND is_nullable = 'YES'
    ) THEN
        ALTER TABLE "user" ALTER COLUMN username SET NOT NULL;
        RAISE NOTICE 'Added NOT NULL constraint to user.username';
    ELSE
        RAISE NOTICE 'user.username already has NOT NULL constraint';
    END IF;

    -- password カラムの NOT NULL 制約
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'user'
        AND column_name = 'password'
        AND is_nullable = 'YES'
    ) THEN
        ALTER TABLE "user" ALTER COLUMN password SET NOT NULL;
        RAISE NOTICE 'Added NOT NULL constraint to user.password';
    ELSE
        RAISE NOTICE 'user.password already has NOT NULL constraint';
    END IF;
END $$;
