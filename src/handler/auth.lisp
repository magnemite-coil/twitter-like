(defpackage twitter-like.handler.auth
  (:use :cl)
  (:import-from :com.inuoe.jzon
                :parse
                :stringify)
  (:import-from :lack.request
                :make-request
                :request-body-parameters
                :request-cookies)
  (:import-from :twitter-like.util.response
                :response-success
                :response-error)
  (:import-from :twitter-like.util.logger
                :log-info
                :log-warn
                :log-error)
  (:import-from :twitter-like.util.crypto
                :constant-time-string=
                :mask-session-id)
  (:import-from :twitter-like.util.request
                :get-env
                :parse-json-body
                :get-session-id-from-cookie
                :get-csrf-header
                :get-client-ip
                :validate-content-type)
  (:import-from :twitter-like.middleware.session
                :create-session
                :get-session-user-id
                :get-csrf-token
                :delete-session
                :touch-session
                :session-idle-expired-p
                :session-absolute-expired-p
                :rotate-session
                :build-session-cookie
                :build-session-clear-cookie)
  (:import-from :twitter-like.model.user
                :find-user-by-id
                :user-to-public-json
                :user-to-private-json)
  (:import-from :twitter-like.service.auth
                :register-user
                :authenticate-user
                :check-rate-limit
                :check-login-rate-limit
                :decrement-login-rate-limit
                :check-register-rate-limit
                :check-account-lockout
                :record-login-failure
                :clear-login-failures
                ;; Rate limit constants
                :+login-rate-limit+
                :+login-rate-window+
                :+register-rate-limit+
                :+register-rate-window+)
  (:import-from :twitter-like.util.rate-limit
                :build-ratelimit-headers)
  (:import-from :twitter-like.util.time
                :get-unix-time)
  (:export :register-handler
           :login-handler
           :logout-handler
           :me-handler
           :register-auth-routes))

(in-package :twitter-like.handler.auth)

;;; ============================================================
;;; ハンドラー固有のユーティリティ関数
;;; ============================================================

(defun response-with-cookie (status data cookie-value &key extra-headers)
  "Cookieを含むレスポンスを生成"
  (let* ((json-string (com.inuoe.jzon:stringify data))
         (content-length (length (babel:string-to-octets json-string :encoding :utf-8)))
         (headers (append (list :content-type "application/json; charset=utf-8"
                                ;; Woo/Clackはヘッダー値に文字列を要求
                                :content-length (twitter-like.util.response::content-length-value content-length)
                                :connection "close"
                                :set-cookie cookie-value)
                          extra-headers)))
    (list status headers (list json-string))))

;;; ============================================================
;;; POST /api/auth/register
;;; ============================================================

(defun register-handler (params)
  "ユーザー登録ハンドラー"
  (declare (ignore params))

  ;; Content-Type検証（OWASP準拠 - 認証チェックより先に実施）
  (multiple-value-bind (valid-p error-status error-message) (validate-content-type)
    (unless valid-p
      (return-from register-handler
        (response-error error-status error-message))))

  (let ((client-ip (get-client-ip)))
    (multiple-value-bind (body parse-error-reason) (parse-json-body)

      ;; レート制限チェック（:always モード: チェック時に自動カウント）
    (multiple-value-bind (allowed remaining reset-time)
        (check-register-rate-limit client-ip)
      (unless allowed
        (log-warn "Rate limit exceeded for registration"
                  :context (list :|ip| client-ip))
        ;; IETF RateLimit構造化ヘッダー + X-RateLimit-*（後方互換）
        (let* ((now (get-unix-time))
               (effective-reset-time (or reset-time (+ now +register-rate-window+)))
               (base-response (response-error 429 "Too many registration attempts. Please try again later."))
               (base-headers (second base-response))
               (rate-headers (build-ratelimit-headers +register-rate-limit+
                                                      (or remaining 0)
                                                      effective-reset-time
                                                      +register-rate-window+
                                                      now))
               (merged-headers (append base-headers rate-headers)))
          (return-from register-handler
            (list 429 merged-headers (third base-response))))))

    ;; リクエストボディの検証
    (unless body
      (return-from register-handler
        (if (eq parse-error-reason :too-large)
            (response-error 413 "Request body too large")
            (response-error 400 "Invalid request body"))))

    (let ((username (gethash "username" body))
          (password (gethash "password" body)))

      ;; ユーザー登録
      (multiple-value-bind (user error-message error-type internal-detail)
          (register-user username password)
        (if user
            ;; 成功: セッション作成してログイン状態に
            (let* ((user-id (mito:object-id user))
                   (session-id (create-session user-id))
                   (cookie (build-session-cookie session-id)))
              (log-info "User registered"
                        :context (list :|username| username
                                       :|user_id| user-id
                                       :|session| (mask-session-id session-id)))
              ;; 注: :always モードのため、check-register-rate-limit でカウント済み
              (let ((response-data (make-hash-table :test 'equal)))
                (setf (gethash "user" response-data) (user-to-public-json user))
                (response-with-cookie 201 response-data cookie)))
            ;; 失敗 - エラー種別に応じてステータスコードとログレベルを分類
            ;; 注: :always モードのため、check-register-rate-limit でカウント済み
            (case error-type
              (:validation
               ;; クライアント起因（バリデーションエラー）: log-warn、400、error_idなし
               (log-warn "Registration validation failed"
                         :context (list :|username| username
                                        :|error| error-message))
               (response-error 400 error-message))
              (:internal
               ;; サーバー起因エラー: log-error（詳細含む）、500、汎用メッセージ、error_idあり
               (let ((error-id (log-error "Registration failed"
                                           :context (list :|username| username
                                                          :|error| internal-detail))))
                 (response-error 500 "An internal error occurred" :error-id error-id)))
              (t
               ;; 予期しないエラー種別: 500として処理
               (let ((error-id (log-error "Registration failed with unknown error type"
                                           :context (list :|username| username
                                                          :|error| error-message))))
                 (response-error 500 "An internal error occurred" :error-id error-id))))))))))

;;; ============================================================
;;; POST /api/auth/login
;;; ============================================================

(defun login-handler (params)
  "ログインハンドラー"
  (declare (ignore params))

  ;; Content-Type検証（OWASP準拠 - 認証チェックより先に実施）
  (multiple-value-bind (valid-p error-status error-message) (validate-content-type)
    (unless valid-p
      (return-from login-handler
        (response-error error-status error-message))))

  (let* ((client-ip (get-client-ip))
         (existing-session-id (get-session-id-from-cookie)))
    (multiple-value-bind (body parse-error-reason) (parse-json-body)

      ;; リクエストボディの検証
      (unless body
        (return-from login-handler
          (if (eq parse-error-reason :too-large)
              (response-error 413 "Request body too large")
              (response-error 400 "Invalid request body"))))

    (let ((username (gethash "username" body))
          (password (gethash "password" body)))

      ;; ユーザー名の基本検証
      (unless (and username (stringp username) (> (length username) 0))
        (return-from login-handler
          (response-error 400 "Username is required")))

      ;; IPベースレート制限チェック（:optimistic モード: 試行時にカウント）
      (multiple-value-bind (allowed remaining reset-time member-id)
          (check-login-rate-limit client-ip)
        (unless allowed
          (log-warn "Rate limit exceeded for login"
                    :context (list :|ip| client-ip :|username| username))
          ;; IETF RateLimit構造化ヘッダー + X-RateLimit-*（後方互換）
          (let* ((now (get-unix-time))
                 (effective-reset-time (or reset-time (+ now +login-rate-window+)))
                 (base-response (response-error 429 "Too many login attempts. Please try again later."))
                 (base-headers (second base-response))
                 (rate-headers (build-ratelimit-headers +login-rate-limit+
                                                        (or remaining 0)
                                                        effective-reset-time
                                                        +login-rate-window+
                                                        now))
                 (merged-headers (append base-headers rate-headers)))
            (return-from login-handler
              (list 429 merged-headers (third base-response)))))

        ;; アカウントロックアウトチェック
      (multiple-value-bind (locked remaining-seconds)
          (check-account-lockout username)
        (when locked
          (log-warn "Account locked out"
                    :context (list :|username| username
                                   :|remaining_seconds| remaining-seconds))
          (return-from login-handler
            (response-error 429 (format nil "Account is locked. Please try again in ~A minutes."
                                        (ceiling remaining-seconds 60))))))

      ;; 認証
      (multiple-value-bind (user error-message)
          (authenticate-user username password)
        (if user
            ;; 認証成功
            (let* ((user-id (mito:object-id user))
                   ;; セッションローテーション（セッション固定攻撃対策）
                   (session-id (rotate-session existing-session-id user-id))
                   (cookie (build-session-cookie session-id)))
              ;; :optimistic モード成功時: カウントをデクリメント
              (when member-id
                (decrement-login-rate-limit client-ip member-id))
              ;; ログイン失敗カウントをクリア
              (clear-login-failures username)
              (log-info "User logged in"
                        :context (list :|username| username
                                       :|user_id| user-id
                                       :|session| (mask-session-id session-id)))
              (let ((response-data (make-hash-table :test 'equal)))
                (setf (gethash "user" response-data) (user-to-public-json user))
                (response-with-cookie 200 response-data cookie)))
            ;; 認証失敗: :optimistic モードでは既にカウント済みなので追加カウント不要
            (progn
              ;; ログイン失敗を記録
              (multiple-value-bind (locked count)
                  (record-login-failure username)
                (when locked
                  (log-warn "Account locked after failed attempts"
                            :context (list :|username| username :|attempts| count))))
              ;; クライアント起因エラー: log-warn、error_idなし
              (log-warn "Login failed"
                        :context (list :|username| username))
              (response-error 401 error-message)))))))))

;;; ============================================================
;;; POST /api/auth/logout
;;; ============================================================

(defun logout-handler (params)
  "ログアウトハンドラー"
  (declare (ignore params))
  (let ((session-id (get-session-id-from-cookie)))

    ;; セッションの検証
    (unless session-id
      (return-from logout-handler
        (response-error 401 "Unauthorized")))

    (let ((user-id (get-session-user-id session-id)))
      (unless user-id
        (return-from logout-handler
          (response-error 401 "Unauthorized")))

      ;; セッションのタイムアウトチェック（絶対 + アイドル）
      (when (session-absolute-expired-p session-id)
        (delete-session session-id)
        (return-from logout-handler
          (response-error 401 "Session expired")))
      (when (session-idle-expired-p session-id)
        (delete-session session-id)
        (return-from logout-handler
          (response-error 401 "Session expired")))

      ;; CSRF検証
      (let* ((submitted-token (get-csrf-header))
             (stored-token (get-csrf-token session-id)))
        (unless (and submitted-token stored-token
                     (constant-time-string= submitted-token stored-token))
          ;; クライアント起因エラー: log-warn、error_idなし
          (log-warn "Invalid CSRF token on logout"
                    :context (list :|user_id| user-id
                                   :|session| (mask-session-id session-id)))
          (return-from logout-handler
            (response-error 403 "Invalid CSRF token"))))

      ;; セッション削除
      (delete-session session-id)
      (log-info "User logged out"
                :context (list :|user_id| user-id
                               :|session| (mask-session-id session-id)))

      ;; Cookie削除
      (let ((response-data (make-hash-table :test 'equal)))
        (setf (gethash "message" response-data) "Logged out successfully")
        (response-with-cookie 200 response-data (build-session-clear-cookie))))))

;;; ============================================================
;;; GET /api/auth/me
;;; ============================================================

(defun me-handler (params)
  "現在のユーザー情報取得ハンドラー"
  (declare (ignore params))
  (let ((session-id (get-session-id-from-cookie)))

    ;; セッションの検証
    (unless session-id
      ;; セキュリティ: ヘッダー名のみをログ出力（Cookie/Authorization等の機密値は除外）
      (log-warn "Session cookie missing on /api/auth/me"
                :context (let* ((hdrs (getf (get-env) :headers))
                                (header-names (when (hash-table-p hdrs)
                                                (loop for k being the hash-keys of hdrs
                                                      collect k))))
                           (list :|header_names| header-names)))
      (return-from me-handler
        (response-error 401 "Unauthorized")))

    (let ((user-id (get-session-user-id session-id)))
      (unless user-id
        (log-warn "Session not found for cookie on /api/auth/me"
                  :context (list :|session| (mask-session-id session-id)))
        (return-from me-handler
          (response-error 401 "Unauthorized")))

      ;; セッションのタイムアウトチェック（絶対 + アイドル）
      (when (session-absolute-expired-p session-id)
        (delete-session session-id)
        (return-from me-handler
          (response-error 401 "Session expired")))
      (when (session-idle-expired-p session-id)
        (delete-session session-id)
        (return-from me-handler
          (response-error 401 "Session expired")))

      ;; セッションのアクセス時刻を更新
      (touch-session session-id)

      ;; ユーザー情報取得
      (let ((user (find-user-by-id user-id)))
        (unless user
          (delete-session session-id)
          (return-from me-handler
            (response-error 401 "Unauthorized")))

        ;; CSRFトークンをヘッダーに含めて返す
          (let* ((csrf-token (get-csrf-token session-id))
                 (response-data (make-hash-table :test 'equal)))
          (setf (gethash "user" response-data) (user-to-private-json user))
          (let* ((json-string (com.inuoe.jzon:stringify response-data))
                 (content-length (length (babel:string-to-octets json-string :encoding :utf-8))))
            (list 200
                  (list :content-type "application/json; charset=utf-8"
                        ;; Woo/Clackはヘッダー値を文字列として扱う
                        :content-length (twitter-like.util.response::content-length-value content-length)
                        :connection "close"
                        :x-csrf-token csrf-token)
                  (list json-string))))))))

;;; ============================================================
;;; ルート登録
;;; ============================================================

(defun register-auth-routes (app)
  "認証ルートをアプリケーションに登録"
  (setf (ningle:route app "/api/auth/register" :method :post) #'register-handler)
  (setf (ningle:route app "/api/auth/login" :method :post) #'login-handler)
  (setf (ningle:route app "/api/auth/logout" :method :post) #'logout-handler)
  (setf (ningle:route app "/api/auth/me" :method :get) #'me-handler)
  app)
