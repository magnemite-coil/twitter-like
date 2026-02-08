.PHONY: test test-config test-db test-health test-setup test-teardown test-clean test-crypto test-session test-request test-cors test-security test-csp-report test-auth-validation test-auth-service test-coverage test-coverage-session test-rate-limit test-rate-limit-redis

CACHE_DIR := $(PWD)/var/cache
QL_LOCAL_PROJECTS := $(PWD)/vendor

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
		mkdir -p $(CACHE_DIR) $(QL_LOCAL_PROJECTS) && \
		XDG_CACHE_HOME=$(CACHE_DIR) QL_LOCAL_PROJECTS=$(QL_LOCAL_PROJECTS) sbcl --eval '(ql:quickload :cl-dotenv)' \
		     --eval "(pushnew (truename \".\") asdf:*central-registry* :test #'equal)" \
		     --eval '(cl-dotenv:load-env ".env.test")' \
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
		mkdir -p $(CACHE_DIR) $(QL_LOCAL_PROJECTS) && \
		XDG_CACHE_HOME=$(CACHE_DIR) QL_LOCAL_PROJECTS=$(QL_LOCAL_PROJECTS) sbcl --eval '(ql:quickload :cl-dotenv)' \
		     --eval "(pushnew (truename \".\") asdf:*central-registry* :test #'equal)" \
		     --eval '(cl-dotenv:load-env ".env.test")' \
		     --eval '(ql:quickload :twitter-like/tests)' \
		     --eval '(rove:run-suite (rove:find-suite :twitter-like-test.config))' \
		     --quit; \
	else \
		echo "Error: .env.test file not found"; \
		exit 1; \
	fi

# データベーステスト
test-db: test-setup
	@echo "Running database tests..."
	@if [ -f .env.test ]; then \
		mkdir -p $(CACHE_DIR) $(QL_LOCAL_PROJECTS) && \
		XDG_CACHE_HOME=$(CACHE_DIR) QL_LOCAL_PROJECTS=$(QL_LOCAL_PROJECTS) sbcl --eval '(ql:quickload :cl-dotenv)' \
		     --eval "(pushnew (truename \".\") asdf:*central-registry* :test #'equal)" \
		     --eval '(cl-dotenv:load-env ".env.test")' \
		     --eval '(ql:quickload :twitter-like/tests)' \
		     --eval '(rove:run-suite (rove:find-suite :twitter-like-test.db))' \
		     --quit; \
	else \
		echo "Error: .env.test file not found"; \
		exit 1; \
	fi

# ヘルスチェックテスト
test-health: test-setup
	@echo "Running health check tests..."
	@if [ -f .env.test ]; then \
		mkdir -p $(CACHE_DIR) $(QL_LOCAL_PROJECTS) && \
		XDG_CACHE_HOME=$(CACHE_DIR) QL_LOCAL_PROJECTS=$(QL_LOCAL_PROJECTS) sbcl --eval '(ql:quickload :cl-dotenv)' \
		     --eval "(pushnew (truename \".\") asdf:*central-registry* :test #'equal)" \
		     --eval '(cl-dotenv:load-env ".env.test")' \
		     --eval '(ql:quickload :twitter-like/tests)' \
		     --eval '(rove:run-suite (rove:find-suite :twitter-like-test.health))' \
		     --quit; \
	else \
		echo "Error: .env.test file not found"; \
		exit 1; \
	fi

# クリーンテスト（データベースを再作成してテスト実行）
test-clean: test-teardown test-setup test
	@echo "✓ Clean test completed"

# 暗号ユーティリティテスト（Redis不要）
test-crypto:
	@echo "Running crypto unit tests..."
	@if [ -f .env.test ]; then \
		mkdir -p $(CACHE_DIR) $(QL_LOCAL_PROJECTS) && \
		XDG_CACHE_HOME=$(CACHE_DIR) QL_LOCAL_PROJECTS=$(QL_LOCAL_PROJECTS) sbcl \
		     --eval '(ql:quickload :cl-dotenv)' \
		     --eval "(pushnew (truename \".\") asdf:*central-registry* :test #'equal)" \
		     --eval '(cl-dotenv:load-env ".env.test")' \
		     --eval '(ql:quickload :twitter-like/tests)' \
		     --eval '(rove:run-suite (rove:find-suite :twitter-like-test.crypto))' \
		     --quit; \
	else \
		echo "Error: .env.test file not found"; \
		exit 1; \
	fi

# セッションテスト（Redis必要）
test-session:
	@echo "Running session unit tests..."
	@if [ -f .env.test ]; then \
		mkdir -p $(CACHE_DIR) $(QL_LOCAL_PROJECTS) && \
		XDG_CACHE_HOME=$(CACHE_DIR) QL_LOCAL_PROJECTS=$(QL_LOCAL_PROJECTS) sbcl \
		     --eval '(ql:quickload :cl-dotenv)' \
		     --eval "(pushnew (truename \".\") asdf:*central-registry* :test #'equal)" \
		     --eval '(cl-dotenv:load-env ".env.test")' \
		     --eval '(ql:quickload :twitter-like/tests)' \
		     --eval '(rove:run-suite (rove:find-suite :twitter-like-test.session))' \
		     --quit; \
	else \
		echo "Error: .env.test file not found"; \
		exit 1; \
	fi

# リクエストユーティリティテスト（Redis不要）
test-request:
	@echo "Running request unit tests..."
	@if [ -f .env.test ]; then \
		mkdir -p $(CACHE_DIR) $(QL_LOCAL_PROJECTS) && \
		XDG_CACHE_HOME=$(CACHE_DIR) QL_LOCAL_PROJECTS=$(QL_LOCAL_PROJECTS) sbcl \
		     --eval '(ql:quickload :cl-dotenv)' \
		     --eval "(pushnew (truename \".\") asdf:*central-registry* :test #'equal)" \
		     --eval '(cl-dotenv:load-env ".env.test")' \
		     --eval '(ql:quickload :twitter-like/tests)' \
		     --eval '(rove:run-suite (rove:find-suite :twitter-like-test.request))' \
		     --quit; \
	else \
		echo "Error: .env.test file not found"; \
		exit 1; \
	fi

# CORSミドルウェアテスト（Redis不要）
test-cors:
	@echo "Running CORS middleware unit tests..."
	@if [ -f .env.test ]; then \
		mkdir -p $(CACHE_DIR) $(QL_LOCAL_PROJECTS) && \
		XDG_CACHE_HOME=$(CACHE_DIR) QL_LOCAL_PROJECTS=$(QL_LOCAL_PROJECTS) sbcl \
		     --eval '(ql:quickload :cl-dotenv)' \
		     --eval "(pushnew (truename \".\") asdf:*central-registry* :test #'equal)" \
		     --eval '(cl-dotenv:load-env ".env.test")' \
		     --eval '(ql:quickload :twitter-like/tests)' \
		     --eval '(rove:run-suite (rove:find-suite :twitter-like-test.cors))' \
		     --quit; \
	else \
		echo "Error: .env.test file not found"; \
		exit 1; \
	fi

# セキュリティミドルウェアテスト（Redis/DB不要）
test-security:
	@echo "Running security middleware unit tests..."
	@if [ -f .env.test ]; then \
		mkdir -p $(CACHE_DIR) $(QL_LOCAL_PROJECTS) && \
		XDG_CACHE_HOME=$(CACHE_DIR) QL_LOCAL_PROJECTS=$(QL_LOCAL_PROJECTS) sbcl \
		     --eval '(ql:quickload :cl-dotenv)' \
		     --eval "(pushnew (truename \".\") asdf:*central-registry* :test #'equal)" \
		     --eval '(cl-dotenv:load-env ".env.test")' \
		     --eval '(ql:quickload :twitter-like/tests)' \
		     --eval '(rove:run-suite (rove:find-suite :twitter-like-test.security))' \
		     --quit; \
	else \
		echo "Error: .env.test file not found"; \
		exit 1; \
	fi

# CSPレポートハンドラーテスト（Redis/DB不要）
test-csp-report:
	@echo "Running CSP report handler unit tests..."
	@if [ -f .env.test ]; then \
		mkdir -p $(CACHE_DIR) $(QL_LOCAL_PROJECTS) && \
		XDG_CACHE_HOME=$(CACHE_DIR) QL_LOCAL_PROJECTS=$(QL_LOCAL_PROJECTS) sbcl \
		     --eval '(ql:quickload :cl-dotenv)' \
		     --eval "(pushnew (truename \".\") asdf:*central-registry* :test #'equal)" \
		     --eval '(cl-dotenv:load-env ".env.test")' \
		     --eval '(ql:quickload :twitter-like/tests)' \
		     --eval '(rove:run-suite (rove:find-suite :twitter-like-test.csp-report))' \
		     --quit; \
	else \
		echo "Error: .env.test file not found"; \
		exit 1; \
	fi

# 認証バリデーションテスト（純粋関数、Redis/DB不要）
test-auth-validation:
	@echo "Running auth validation unit tests..."
	@if [ -f .env.test ]; then \
		mkdir -p $(CACHE_DIR) $(QL_LOCAL_PROJECTS) && \
		XDG_CACHE_HOME=$(CACHE_DIR) QL_LOCAL_PROJECTS=$(QL_LOCAL_PROJECTS) sbcl \
		     --eval '(ql:quickload :cl-dotenv)' \
		     --eval "(pushnew (truename \".\") asdf:*central-registry* :test #'equal)" \
		     --eval '(cl-dotenv:load-env ".env.test")' \
		     --eval '(ql:quickload :twitter-like/tests)' \
		     --eval '(rove:run-suite (rove:find-suite :twitter-like-test.auth-validation))' \
		     --quit; \
	else \
		echo "Error: .env.test file not found"; \
		exit 1; \
	fi

# 認証サービステスト（Redis/DB依存）
test-auth-service: test-setup
	@echo "Running auth service unit tests..."
	@if [ -f .env.test ]; then \
		mkdir -p $(CACHE_DIR) $(QL_LOCAL_PROJECTS) && \
		XDG_CACHE_HOME=$(CACHE_DIR) QL_LOCAL_PROJECTS=$(QL_LOCAL_PROJECTS) sbcl \
		     --eval '(ql:quickload :cl-dotenv)' \
		     --eval "(pushnew (truename \".\") asdf:*central-registry* :test #'equal)" \
		     --eval '(cl-dotenv:load-env ".env.test")' \
		     --eval '(ql:quickload :twitter-like/tests)' \
		     --eval '(rove:run-suite (rove:find-suite :twitter-like-test.auth-service))' \
		     --quit; \
	else \
		echo "Error: .env.test file not found"; \
		exit 1; \
	fi

# カバレッジ測定（全テスト）
# 注意: sb-coverはコンパイル時にカバレッジ情報を収集するため、
# FASLキャッシュをクリアしてから実行する必要がある
test-coverage: test-setup
	@echo "Running tests with coverage measurement..."
	@echo "Clearing FASL cache for accurate coverage..."
	@rm -rf $(CACHE_DIR)/common-lisp/sbcl-*/**/twitter-like* 2>/dev/null || true
	@mkdir -p coverage $(CACHE_DIR) $(QL_LOCAL_PROJECTS)
	@if [ -f .env.test ]; then \
		XDG_CACHE_HOME=$(CACHE_DIR) QL_LOCAL_PROJECTS=$(QL_LOCAL_PROJECTS) sbcl \
		     --eval '(require :sb-cover)' \
		     --eval '(declaim (optimize sb-cover:store-coverage-data))' \
		     --eval '(ql:quickload :cl-dotenv)' \
		     --eval "(pushnew (truename \".\") asdf:*central-registry* :test #'equal)" \
		     --eval '(cl-dotenv:load-env ".env.test")' \
		     --eval '(ql:quickload :twitter-like/tests)' \
		     --eval '(asdf:test-system :twitter-like)' \
		     --eval '(sb-cover:report "coverage/")' \
		     --quit && \
		echo "✓ Coverage report generated in coverage/" && \
		echo "  Open coverage/cover-index.html to view results"; \
	else \
		echo "Error: .env.test file not found"; \
		exit 1; \
	fi

# セッションモジュールのカバレッジ測定
# 注意: sb-coverはコンパイル時にカバレッジ情報を埋め込むため、
# twitter-likeプロジェクトのFASLキャッシュをクリアして再コンパイルする
test-coverage-session:
	@echo "Running session tests with coverage measurement..."
	@echo "Clearing twitter-like FASL cache..."
	@find $(CACHE_DIR)/common-lisp -path "*twitter-like*" -name "*.fasl" -delete 2>/dev/null || true
	@mkdir -p coverage $(CACHE_DIR) $(QL_LOCAL_PROJECTS)
	@if [ -f .env.test ]; then \
		XDG_CACHE_HOME=$(CACHE_DIR) QL_LOCAL_PROJECTS=$(QL_LOCAL_PROJECTS) sbcl \
		     --eval '(require :sb-cover)' \
		     --eval '(declaim (optimize sb-cover:store-coverage-data))' \
		     --eval '(ql:quickload :cl-dotenv)' \
		     --eval "(pushnew (truename \".\") asdf:*central-registry* :test #'equal)" \
		     --eval '(cl-dotenv:load-env ".env.test")' \
		     --eval '(ql:quickload :twitter-like/tests)' \
		     --eval '(rove:run-suite (rove:find-suite :twitter-like-test.session))' \
		     --eval '(sb-cover:report "coverage/")' \
		     --quit && \
		echo "✓ Coverage report generated in coverage/" && \
		echo "  Open coverage/cover-index.html to view results"; \
	else \
		echo "Error: .env.test file not found"; \
		exit 1; \
	fi

# レート制限テスト（純粋関数のみ、Redis不要）
# 既存パターン test-crypto に準拠（.env.test読み込みあり）
test-rate-limit:
	@echo "Running rate-limit pure function tests..."
	@if [ -f .env.test ]; then \
		mkdir -p $(CACHE_DIR) $(QL_LOCAL_PROJECTS) && \
		XDG_CACHE_HOME=$(CACHE_DIR) QL_LOCAL_PROJECTS=$(QL_LOCAL_PROJECTS) sbcl \
		     --eval '(ql:quickload :cl-dotenv)' \
		     --eval "(pushnew (truename \".\") asdf:*central-registry* :test #'equal)" \
		     --eval '(cl-dotenv:load-env ".env.test")' \
		     --eval '(ql:quickload :twitter-like/tests)' \
		     --eval '(rove:run-suite (rove:find-suite :twitter-like-test.rate-limit))' \
		     --quit; \
	else \
		echo "Error: .env.test file not found"; \
		exit 1; \
	fi

# レート制限Redis統合テスト（Redis必要）
# 既存パターン test-session に準拠
test-rate-limit-redis:
	@echo "Running rate-limit Redis integration tests..."
	@if [ -f .env.test ]; then \
		mkdir -p $(CACHE_DIR) $(QL_LOCAL_PROJECTS) && \
		XDG_CACHE_HOME=$(CACHE_DIR) QL_LOCAL_PROJECTS=$(QL_LOCAL_PROJECTS) sbcl \
		     --eval '(ql:quickload :cl-dotenv)' \
		     --eval "(pushnew (truename \".\") asdf:*central-registry* :test #'equal)" \
		     --eval '(cl-dotenv:load-env ".env.test")' \
		     --eval '(ql:quickload :twitter-like/tests)' \
		     --eval '(rove:run-suite (rove:find-suite :twitter-like-test.rate-limit-redis))' \
		     --quit; \
	else \
		echo "Error: .env.test file not found"; \
		exit 1; \
	fi
