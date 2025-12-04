(defpackage twitter-like.middleware.session
  (:use :cl)
  (:import-from :redis
                :connect
                :disconnect
                :redis-connection)
  (:export :connect-redis
           :disconnect-redis
           :ensure-redis-connected
           :*redis-connection*
           ;; セッション管理機能
           :get-unix-time
           :create-session
           :get-session-user-id
           :get-csrf-token
           :delete-session
           :touch-session
           :session-idle-expired-p
           :session-absolute-expired-p
           :rotate-session
           :production-p
           :build-session-cookie
           :build-session-clear-cookie))

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
    (redis:disconnect)
    (setf *redis-connection* nil)
    (format t "✓ Redis disconnected~%")))

(defun ensure-redis-connected ()
  "Redis接続を確認、未接続なら接続"
  (unless *redis-connection*
    (connect-redis)))

;;; ============================================================
;;; セッション管理機能（設計書6章に対応）
;;; ============================================================

(defconstant +session-ttl+ 604800
  "セッション絶対タイムアウト: 7日間（秒）")

(defconstant +session-idle-timeout+ 1800
  "セッションアイドルタイムアウト: 30分（秒）")

(defun get-unix-time ()
  "Unix timestamp（1970年1月1日からの秒数）を取得"
  (- (get-universal-time) 2208988800))

(defun production-p ()
  "本番環境かどうかを判定"
  (string= (twitter-like.config:get-config "app-env") "production"))

(defun create-session (user-id)
  "新しいセッションを作成してセッションIDを返す
  Redis Hashに user_id, created_at, last_accessed_at, csrf_token を保存
  TTLは7日間"
  (let* ((session-id (twitter-like.util.crypto:generate-session-id))
         (csrf-token (twitter-like.util.crypto:generate-csrf-token))
         (now (write-to-string (get-unix-time)))
         (key (format nil "session:~A" session-id)))
    (red:hset key "user_id" (write-to-string user-id))
    (red:hset key "created_at" now)
    (red:hset key "last_accessed_at" now)
    (red:hset key "csrf_token" csrf-token)
    (red:expire key +session-ttl+)
    session-id))

(defun get-session-user-id (session-id)
  "セッションIDからuser_idを取得（存在しない場合はnil）"
  (when session-id
    (let* ((key (format nil "session:~A" session-id))
           (user-id-str (red:hget key "user_id")))
      (when user-id-str
        (parse-integer user-id-str :junk-allowed t)))))

(defun get-csrf-token (session-id)
  "セッションからCSRFトークンを取得"
  (when session-id
    (let ((key (format nil "session:~A" session-id)))
      (red:hget key "csrf_token"))))

(defun delete-session (session-id)
  "セッションを削除"
  (when session-id
    (let ((key (format nil "session:~A" session-id)))
      (red:del key))))

(defun touch-session (session-id)
  "セッションのlast_accessed_atを更新（アイドルタイムアウト用）
  注意: TTLはリセットしない（絶対タイムアウトを維持するため）"
  (when session-id
    (let ((key (format nil "session:~A" session-id))
          (now (write-to-string (get-unix-time))))
      (red:hset key "last_accessed_at" now))))

(defun session-idle-expired-p (session-id &optional (idle-timeout +session-idle-timeout+))
  "アイドルタイムアウトをチェック（デフォルト30分）"
  (when session-id
    (let* ((key (format nil "session:~A" session-id))
           (last-accessed (red:hget key "last_accessed_at"))
           (now (get-unix-time)))
      (when last-accessed
        (> (- now (parse-integer last-accessed)) idle-timeout)))))

(defun session-absolute-expired-p (session-id &optional (absolute-timeout +session-ttl+))
  "絶対タイムアウトをチェック（デフォルト7日間）
  注意: 通常はRedis TTLで自動削除されるが、念のためチェック"
  (when session-id
    (let* ((key (format nil "session:~A" session-id))
           (created-at (red:hget key "created_at"))
           (now (get-unix-time)))
      (when created-at
        (> (- now (parse-integer created-at)) absolute-timeout)))))

(defun rotate-session (old-session-id user-id)
  "セキュリティイベント時にセッションIDをローテーション
  古いセッションを削除し、新しいセッションを作成して返す"
  (when old-session-id
    (delete-session old-session-id))
  (create-session user-id))

(defun build-session-cookie (session-id)
  "セッションCookieを構築
  開発環境ではSecure属性を省略"
  (let ((secure-flag (if (production-p) "; Secure" "")))
    (format nil "session_id=~A; HttpOnly~A; SameSite=Lax; Path=/; Max-Age=~A"
            session-id secure-flag +session-ttl+)))

(defun build-session-clear-cookie ()
  "セッションCookie削除用の値を構築"
  (let ((secure-flag (if (production-p) "; Secure" "")))
    (format nil "session_id=; HttpOnly~A; SameSite=Lax; Path=/; Max-Age=0"
            secure-flag)))
