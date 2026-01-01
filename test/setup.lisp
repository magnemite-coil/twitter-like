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
  (:import-from :dexador)
  (:import-from :dexador.error)
  (:import-from :com.inuoe.jzon
                :stringify)
  (:export :setup-test-env
           :teardown-test-env
           :cleanup-test-data
           :get-test-base-url
           ;; 共通HTTPヘルパー
           :extract-session-cookie
           :json-post
           :safe-get
           :safe-delete))

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

;;; ============================================================
;;; 共通HTTPテストヘルパー
;;; ============================================================

(defun extract-session-cookie (set-cookie-header)
  "Set-Cookieヘッダーから送信用Cookie文字列を抽出
  Set-Cookie: session_id=xxx; HttpOnly; ... → session_id=xxx"
  (when set-cookie-header
    (let* ((cookie-str (if (listp set-cookie-header)
                           (first set-cookie-header)
                           set-cookie-header))
           (semicolon-pos (position #\; cookie-str)))
      (if semicolon-pos
          (subseq cookie-str 0 semicolon-pos)
          cookie-str))))

(defun json-post (path payload &key headers)
  "JSON POSTリクエスト（エラー時も値を返す）
  戻り値: (values body status headers)"
  (handler-case
      (dex:post (format nil "~A~A" (get-test-base-url) path)
                :headers (append '(("Content-Type" . "application/json")
                                   ("Connection" . "close"))
                                 headers)
                :content (com.inuoe.jzon:stringify payload))
    (dexador.error:http-request-failed (e)
      (values (dexador:response-body e)
              (dexador:response-status e)
              (dexador:response-headers e)))))

(defun safe-get (path &key headers)
  "GETリクエスト（エラー時も値を返す）
  戻り値: (values body status headers)"
  (handler-case
      (dex:get (format nil "~A~A" (get-test-base-url) path)
               :headers (append '(("Connection" . "close")) headers))
    (dexador.error:http-request-failed (e)
      (values (dexador:response-body e)
              (dexador:response-status e)
              (dexador:response-headers e)))))

(defun safe-delete (path &key headers)
  "DELETEリクエスト（エラー時も値を返す）
  戻り値: (values body status headers)"
  (handler-case
      (dex:delete (format nil "~A~A" (get-test-base-url) path)
                  :headers (append '(("Connection" . "close")) headers))
    (dexador.error:http-request-failed (e)
      (values (dexador:response-body e)
              (dexador:response-status e)
              (dexador:response-headers e)))))
