.PHONY: test test-config test-db test-health test-setup test-teardown test-clean

# テスト用データベースセットアップ
test-setup:
	@echo "Setting up test database..."
	createdb twitter_like_test || true
	@echo "✓ Test database ready"

# テスト用データベース削除
test-teardown:
	@echo "Tearing down test database..."
	dropdb twitter_like_test || true
	@echo "✓ Test database removed"

# 全テスト実行
test: test-setup
	@echo "Running all tests..."
	@if [ -f .env.test ]; then \
		sbcl --eval '(cl-dotenv:load-env :file ".env.test")' \
		     --eval '(ql:quickload :twitter-like/tests)' \
		     --eval '(asdf:test-system :twitter-like)' \
		     --quit; \
	else \
		echo "Error: .env.test file not found"; \
		exit 1; \
	fi

# 設定テスト
test-config:
	@echo "Running config tests..."
	@if [ -f .env.test ]; then \
		sbcl --eval '(cl-dotenv:load-env :file ".env.test")' \
		     --eval '(ql:quickload :twitter-like/tests)' \
		     --eval '(rove:run :twitter-like-test.config)' \
		     --quit; \
	else \
		echo "Error: .env.test file not found"; \
		exit 1; \
	fi

# データベーステスト
test-db: test-setup
	@echo "Running database tests..."
	@if [ -f .env.test ]; then \
		sbcl --eval '(cl-dotenv:load-env :file ".env.test")' \
		     --eval '(ql:quickload :twitter-like/tests)' \
		     --eval '(rove:run :twitter-like-test.db)' \
		     --quit; \
	else \
		echo "Error: .env.test file not found"; \
		exit 1; \
	fi

# ヘルスチェックテスト
test-health: test-setup
	@echo "Running health check tests..."
	@if [ -f .env.test ]; then \
		sbcl --eval '(cl-dotenv:load-env :file ".env.test")' \
		     --eval '(ql:quickload :twitter-like/tests)' \
		     --eval '(rove:run :twitter-like-test.health)' \
		     --quit; \
	else \
		echo "Error: .env.test file not found"; \
		exit 1; \
	fi

# クリーンテスト（データベースを再作成してテスト実行）
test-clean: test-teardown test-setup test
	@echo "✓ Clean test completed"
