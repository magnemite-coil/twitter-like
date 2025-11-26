(defpackage twitter-like
  (:use :cl)
  (:import-from :twitter-like.config
                :load-config
                :get-config)
  (:import-from :twitter-like.db
                :connect-db
                :disconnect-db)
  (:import-from :twitter-like.middleware.session
                :connect-redis
                :disconnect-redis)
  (:import-from :twitter-like.web
                :*app*
                :build-app)
  (:export :start
           :stop))

(in-package :twitter-like)

(defvar *server* nil
  "サーバーインスタンスを保持する変数")

(defun start (&key (port nil))
  "アプリケーションを起動"
  (handler-case
      (progn
        ;; 重複起動チェック
        (when *server*
          (error "Server is already running. Please call (stop) first."))

        (format t "~%========================================~%")
        (format t "Starting Twitter-like Application~%")
        (format t "========================================~%~%")

        ;; 1. 設定読み込み（内部でvalidate-configを呼ぶ）
        (twitter-like.config:load-config)

        ;; 2. データベース接続
        (twitter-like.db:connect-db)

        ;; 3. Redis接続
        (twitter-like.middleware.session:connect-redis)

        ;; 4. アプリケーション構築（設定読み込み後に実行）
        (twitter-like.web:build-app)

        ;; 5. サーバー起動
        (let ((actual-port (or port (twitter-like.config:get-config "app-port"))))
          (setf *server* (clack:clackup twitter-like.web:*app*
                                        :port actual-port
                                        :server :woo))

          (format t "~%========================================~%")
          (format t "✓ Server started on http://localhost:~A~%" actual-port)
          (format t "  Environment: ~A~%" (twitter-like.config:get-config "app-env"))
          (format t "========================================~%~%")

          *server*))

    ;; エラーハンドリング
    (error (e)
      (format t "~%❌ Failed to start application: ~A~%~%" e)
      ;; クリーンアップ
      (handler-case (twitter-like.middleware.session:disconnect-redis)
        (error () nil))
      (handler-case (twitter-like.db:disconnect-db)
        (error () nil))
      (setf *server* nil)
      (error "Application startup failed: ~A" e))))

(defun stop ()
  "アプリケーションを停止"
  (format t "~%========================================~%")
  (format t "Stopping Twitter-like Application~%")
  (format t "========================================~%~%")

  ;; 1. サーバー停止
  (when *server*
    (handler-case
        (progn
          (clack:stop *server*)
          (format t "✓ Server stopped~%"))
      (error (e)
        (format t "⚠ Error stopping server: ~A~%" e)))
    (setf *server* nil))

  ;; 2. Redis切断
  (handler-case
      (twitter-like.middleware.session:disconnect-redis)
    (error (e)
      (format t "⚠ Error disconnecting Redis: ~A~%" e)))

  ;; 3. データベース切断
  (handler-case
      (twitter-like.db:disconnect-db)
    (error (e)
      (format t "⚠ Error disconnecting database: ~A~%" e)))

  (format t "~%========================================~%")
  (format t "✓ Application stopped~%")
  (format t "========================================~%~%"))
