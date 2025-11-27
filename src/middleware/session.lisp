(defpackage twitter-like.middleware.session
  (:use :cl)
  (:import-from :redis
                :connect
                :disconnect
                :redis-connection)
  (:export :connect-redis
           :disconnect-redis
           :ensure-redis-connected
           :*redis-connection*))

(in-package :twitter-like.middleware.session)

(defvar *redis-connection* nil
  "Redis接続を保持する変数")

(defun connect-redis (&key (max-retries 3) (retry-delay 2))
  "Redisサーバーに接続（リトライ機構付き）"
  (let ((redis-host (twitter-like.config:get-config "redis-host"))
        (redis-port (twitter-like.config:get-config "redis-port"))
        (redis-db (twitter-like.config:get-config "redis-db"))
        (redis-password (twitter-like.config:get-config "redis-password")))

    (loop for retry from 1 to max-retries
          do (handler-case
                 (progn
                   ;; 基本接続
                   (setf *redis-connection* (redis:connect :host redis-host :port redis-port))

                   ;; パスワード認証（必要な場合）
                   (when (and redis-password (not (string= redis-password "")))
                     (red:auth redis-password))

                   ;; データベース選択
                   (when (and redis-db (> redis-db 0))
                     (red:select redis-db))

                   (format t "✓ Redis connected: ~A:~A (DB ~A)~%"
                           redis-host redis-port redis-db)
                   (return *redis-connection*))
               (error (e)
                 (format t "⚠ Redis connection failed (attempt ~A/~A): ~A~%"
                         retry max-retries e)
                 (when *redis-connection*
                   (handler-case (redis:disconnect *redis-connection*) (error () nil))
                   (setf *redis-connection* nil))
                 (when (< retry max-retries)
                   (format t "  Retrying in ~A seconds...~%" retry-delay)
                   (sleep retry-delay))))
          finally (error "Failed to connect to Redis after ~A attempts" max-retries))))

(defun disconnect-redis ()
  "Redis接続を切断"
  (when *redis-connection*
    (redis:disconnect *redis-connection*)
    (setf *redis-connection* nil)
    (format t "✓ Redis disconnected~%")))

(defun ensure-redis-connected ()
  "Redis接続を確認、未接続なら接続"
  (unless *redis-connection*
    (connect-redis)))
