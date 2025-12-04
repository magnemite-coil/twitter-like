(defpackage twitter-like.config
  (:use :cl)
  (:export :load-config
           :get-config
           :*config*))

(in-package :twitter-like.config)

(defvar *config* (make-hash-table :test 'equal)
  "アプリケーション設定を保持するハッシュテーブル")

(defun required-env-var (var-name)
  "必須環境変数を取得（nilまたは空文字列の場合はエラー）"
  (let ((value (uiop:getenv var-name)))
    (if (and value (not (string= value "")))
        value
        (error "Required environment variable ~A is not set or is empty" var-name))))

(defun validate-secret-key (key-name min-length)
  "秘密鍵の長さとフォーマットを検証"
  (let ((key (get-config key-name)))
    (unless key
      (error "Missing required secret key: ~A" key-name))

    ;; 空文字列チェック
    (when (zerop (length key))
      (error "Secret key is empty: ~A" key-name))

    ;; 16進数文字列の検証
    (unless (every (lambda (c) (digit-char-p c 16)) key)
      (error "Secret key must be hexadecimal: ~A (got: ~A)" key-name key))

    ;; 長さの検証（16進数なので文字数 = ビット数/4）
    (when (< (length key) min-length)
      (error "Secret key ~A is too short (min: ~A chars, got: ~A)"
             key-name min-length (length key))))
  t)

(defun validate-config ()
  "必須設定が揃っているか検証"
  ;; 必須環境変数チェック（load-config内で早期エラーとして実装済み）
  ;; ここでは秘密鍵の形式検証のみ実施

  ;; 秘密鍵の検証（256ビット = 64文字の16進数）
  (validate-secret-key "session-secret" 64)
  (validate-secret-key "csrf-secret" 64)

  (format t "✓ Configuration validated~%")
  t)

(defun load-config ()
  "環境変数を読み込んで設定ハッシュテーブルに格納"
  ;; .env*.test/.env のロード
  ;; APP_ENVがtestなら .env.test を優先し、それ以外は .env を読む
  (let ((app-env (or (uiop:getenv "APP_ENV") "development")))
    (handler-case
        (cond
          ((and (string= app-env "test") (probe-file ".env.test"))
           (cl-dotenv:load-env ".env.test")
           (format t "✓ .env.test file loaded~%"))
          ((probe-file ".env")
           (cl-dotenv:load-env ".env")
           (format t "✓ .env file loaded~%")))
      (error (e)
        (format t "⚠ Failed to load env file: ~A~%" e)
        (format t "  Falling back to environment variables~%"))))

  ;; 基本設定（デフォルト値あり）
  (setf (gethash "app-env" *config*) (or (uiop:getenv "APP_ENV") "development"))
  (setf (gethash "app-port" *config*) (parse-integer (or (uiop:getenv "APP_PORT") "8080")))
  (setf (gethash "db-host" *config*) (or (uiop:getenv "DB_HOST") "localhost"))
  (setf (gethash "db-port" *config*) (parse-integer (or (uiop:getenv "DB_PORT") "5432")))
  (setf (gethash "db-name" *config*) (or (uiop:getenv "DB_NAME") "twitter_like"))
  (setf (gethash "db-user" *config*) (or (uiop:getenv "DB_USER") "postgres"))
  (setf (gethash "log-level" *config*) (or (uiop:getenv "LOG_LEVEL") "info"))
  (setf (gethash "log-file" *config*) (or (uiop:getenv "LOG_FILE") "var/log/app.log"))

  ;; 必須環境変数（nilと空文字列を許容しない）
  ;; DB_PASSWORDは開発環境では空を許可（本番環境では必須）
  (setf (gethash "db-password" *config*) (or (uiop:getenv "DB_PASSWORD") ""))
  (setf (gethash "session-secret" *config*) (required-env-var "SESSION_SECRET"))
  (setf (gethash "csrf-secret" *config*) (required-env-var "CSRF_SECRET"))

  ;; オプション環境変数（nilを許容）
  (setf (gethash "redis-host" *config*) (or (uiop:getenv "REDIS_HOST") "localhost"))
  (setf (gethash "redis-port" *config*) (parse-integer (or (uiop:getenv "REDIS_PORT") "6379")))
  (setf (gethash "redis-db" *config*) (parse-integer (or (uiop:getenv "REDIS_DB") "0")))
  (setf (gethash "redis-password" *config*) (uiop:getenv "REDIS_PASSWORD"))
  (setf (gethash "cors-allowed-origins" *config*) (uiop:getenv "CORS_ALLOWED_ORIGINS"))

  (format t "✓ Configuration loaded (APP_ENV=~A)~%" (gethash "app-env" *config*))

  ;; 設定検証（起動時に必須設定をチェック）
  (validate-config)

  *config*)

(defun get-config (key)
  "設定値を取得"
  (gethash key *config*))

(defun reload-config ()
  "設定を再読み込み（開発環境のみ）"
  (when (string= (get-config "app-env") "development")
    (clrhash *config*)
    (load-config)))
