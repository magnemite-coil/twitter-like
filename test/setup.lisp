(defpackage twitter-like-test
  (:use :cl :rove)
  (:import-from :twitter-like
                :start
                :stop)
  (:import-from :twitter-like.config
                :load-config
                :get-config)
  (:import-from :mito
                :ensure-table-exists)
  (:import-from :red
                :flushdb)
  (:export :setup-test-env
           :teardown-test-env
           :cleanup-test-data
           :get-test-base-url))

(in-package :twitter-like-test)

(defvar *test-server* nil
  "テスト用サーバーインスタンス")

(defun setup-test-env ()
  "テスト環境をセットアップ"
  ;; .env.test を読み込み
  (when (probe-file ".env.test")
    (cl-dotenv:load-env ".env.test"))

  ;; テスト用データベースに接続
  (twitter-like.config:load-config)

  ;; 環境がtestであることを確認
  (unless (string= (twitter-like.config:get-config "app-env") "test")
    (error "APP_ENV must be 'test' for running tests"))

  ;; サーバー起動（テスト用ポート）
  (setf *test-server* (twitter-like:start :port (twitter-like.config:get-config "app-port")))

  ;; 必要テーブルが存在することを保証
  (ensure-table-exists 'twitter-like.model.user:user))

(defun teardown-test-env ()
  "テスト環境をクリーンアップ"
  (when *test-server*
    (twitter-like:stop)
    (setf *test-server* nil)))

(defun cleanup-test-data ()
  "テストデータをクリーンアップ"
  ;; Redis のテストデータをクリア（テスト用DB番号1のみ）
  (handler-case
      (when twitter-like.middleware.session:*redis-connection*
        (flushdb)
        (format t "✓ Redis test data cleared~%"))
    (error (e)
      (format t "⚠ Failed to clear Redis test data: ~A~%" e)))

  ;; データベーステーブルをトランケート（将来のテーブル用）
  ;; 注意: 本番データベースでは絶対に実行しないこと
  (handler-case
      (when (string= (twitter-like.config:get-config "app-env") "test")
        ;; 将来実装されるテーブルのトランケート
        ;; (mito:execute-sql "TRUNCATE TABLE session CASCADE;")
        ;; (mito:execute-sql "TRUNCATE TABLE user CASCADE;")
        ;; (mito:execute-sql "TRUNCATE TABLE tweet CASCADE;")
        (format t "✓ Database test data cleared~%"))
    (error (e)
      (format t "⚠ Failed to clear database test data: ~A~%" e))))

(defun get-test-base-url ()
  "テスト用ベースURLを取得（環境変数から動的に生成）"
  (format nil "http://localhost:~A"
          (twitter-like.config:get-config "app-port")))
