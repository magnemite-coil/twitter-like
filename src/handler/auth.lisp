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
                :get-client-ip)
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
                :check-account-lockout
                :record-login-failure
                :clear-login-failures)
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
  (let* ((client-ip (get-client-ip))
         (body (parse-json-body)))

    ;; レート制限チェック
    (multiple-value-bind (allowed remaining)
        (check-rate-limit :register client-ip
                          :limit 3
                          :window 3600)
      (declare (ignore remaining))
      (unless allowed
        (log-warn "Rate limit exceeded for registration"
                  :context (list :|ip| client-ip))
        (return-from register-handler
          (response-error 429 "Too many registration attempts. Please try again later."))))

    ;; リクエストボディの検証
    (unless body
      (return-from register-handler
        (response-error 400 "Invalid request body")))

    (let ((username (gethash "username" body))
          (password (gethash "password" body)))

      ;; ユーザー登録
      (multiple-value-bind (user error-message)
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
              ;; レート制限カウントを増加（成功時も）
              (twitter-like.service.auth::increment-rate-limit :register client-ip :window 3600)
              (let ((response-data (make-hash-table :test 'equal)))
                (setf (gethash "user" response-data) (user-to-public-json user))
                (response-with-cookie 201 response-data cookie)))
            ;; 失敗 - エラー種別に応じてログレベルを分類
            (progn
              (twitter-like.service.auth::increment-rate-limit :register client-ip :window 3600)
              (cond
                ;; クライアント起因（バリデーションエラー）: log-warn、error_idなし
                ((or (search "Username" error-message)
                     (search "Password" error-message)
                     (search "already exists" error-message))
                 (log-warn "Registration validation failed"
                           :context (list :|username| username
                                          :|error| error-message))
                 (response-error 400 error-message))
                ;; サーバー起因エラー: log-error、error_idあり
                (t
                 (let ((error-id (log-error "Registration failed"
                                             :context (list :|username| username
                                                            :|error| error-message))))
                   (response-error 400 error-message :error-id error-id))))))))))

;;; ============================================================
;;; POST /api/auth/login
;;; ============================================================

(defun login-handler (params)
  "ログインハンドラー"
  (declare (ignore params))
  (let* ((client-ip (get-client-ip))
         (body (parse-json-body))
         (existing-session-id (get-session-id-from-cookie)))

    ;; リクエストボディの検証
    (unless body
      (return-from login-handler
        (response-error 400 "Invalid request body")))

    (let ((username (gethash "username" body))
          (password (gethash "password" body)))

      ;; ユーザー名の基本検証
      (unless (and username (stringp username) (> (length username) 0))
        (return-from login-handler
          (response-error 400 "Username is required")))

      ;; IPベースレート制限チェック
      (multiple-value-bind (allowed remaining)
          (check-rate-limit :login client-ip)
        (declare (ignore remaining))
        (unless allowed
          (log-warn "Rate limit exceeded for login"
                    :context (list :|ip| client-ip :|username| username))
          (return-from login-handler
            (response-error 429 "Too many login attempts. Please try again later."))))

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
              ;; ログイン失敗カウントをクリア
              (clear-login-failures username)
              (log-info "User logged in"
                        :context (list :|username| username
                                       :|user_id| user-id
                                       :|session| (mask-session-id session-id)))
              (let ((response-data (make-hash-table :test 'equal)))
                (setf (gethash "user" response-data) (user-to-public-json user))
                (response-with-cookie 200 response-data cookie)))
            ;; 認証失敗
            (progn
              ;; レート制限カウント増加
              (twitter-like.service.auth::increment-rate-limit :login client-ip)
              ;; ログイン失敗を記録
              (multiple-value-bind (locked count)
                  (record-login-failure username)
                (when locked
                  (log-warn "Account locked after failed attempts"
                            :context (list :|username| username :|attempts| count))))
              ;; クライアント起因エラー: log-warn、error_idなし
              (log-warn "Login failed"
                        :context (list :|username| username))
              (response-error 401 error-message)))))))

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
      (log-warn "Session cookie missing on /api/auth/me"
                :context (let* ((hdrs (getf (get-env) :headers))
                                (pairs (when (hash-table-p hdrs)
                                         (loop for k being the hash-keys of hdrs
                                               collect (cons k (gethash k hdrs))))))
                           (list :|headers| pairs)))
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
