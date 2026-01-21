.PHONY: test test-config test-db test-health test-setup test-teardown test-clean test-crypto test-session test-request test-cors test-security test-csp-report

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
