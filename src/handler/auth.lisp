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
  (:import-from :twitter-like.middleware.session
                :create-session
                :get-session-user-id
                :get-csrf-token
                :delete-session
                :touch-session
                :session-idle-expired-p
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
  (:export :handle-register
           :handle-login
           :handle-logout
           :handle-me
           :register-auth-routes))

(in-package :twitter-like.handler.auth)

;;; ============================================================
;;; ユーティリティ関数
;;; ============================================================

(defun parse-json-body (env)
  "リクエストボディをJSONとしてパース"
  (handler-case
      (let* ((content-length (getf env :content-length))
             (body-stream (getf env :raw-body)))
        (when (and content-length body-stream (> content-length 0))
          (let ((body-bytes (make-array content-length :element-type '(unsigned-byte 8))))
            (read-sequence body-bytes body-stream)
            (let ((body-string (babel:octets-to-string body-bytes :encoding :utf-8)))
              (com.inuoe.jzon:parse body-string)))))
    (error (e)
      (log-warn (format nil "Failed to parse JSON body: ~A" e))
      nil)))

(defun get-client-ip (env)
  "クライアントIPアドレスを取得（X-Forwarded-For対応）"
  (or (getf env :http-x-forwarded-for)
      (getf env :remote-addr)
      "unknown"))

(defun get-session-id-from-cookie (env)
  "CookieからセッションIDを取得"
  (let* ((cookie-header (getf env :http-cookie))
         (cookies (when cookie-header
                    (loop for pair in (str:split "; " cookie-header)
                          for (name . value) = (let ((pos (position #\= pair)))
                                                  (when pos
                                                    (cons (subseq pair 0 pos)
                                                          (subseq pair (1+ pos)))))
                          when (and name (string= name "session_id"))
                          return value))))
    cookies))

(defun response-with-cookie (status data cookie-value &key extra-headers)
  "Cookieを含むレスポンスを生成"
  (let* ((json-string (com.inuoe.jzon:stringify data))
         (headers (append (list :content-type "application/json; charset=utf-8"
                                :set-cookie cookie-value)
                          extra-headers)))
    (list status headers (list json-string))))

;;; ============================================================
;;; POST /api/auth/register
;;; ============================================================

(defun handle-register (env)
  "ユーザー登録ハンドラー"
  (let* ((client-ip (get-client-ip env))
         (body (parse-json-body env)))

    ;; レート制限チェック
    (multiple-value-bind (allowed remaining)
        (check-rate-limit :register client-ip
                          :limit 3
                          :window 3600)
      (unless allowed
        (log-warn "Rate limit exceeded for registration"
                  :context (list :|ip| client-ip))
        (return-from handle-register
          (response-error 429 "Too many registration attempts. Please try again later."))))

    ;; リクエストボディの検証
    (unless body
      (return-from handle-register
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
              (response-with-cookie 201
                                    (list (cons "user" (user-to-public-json user)))
                                    cookie))
            ;; 失敗
            (let ((error-id (log-error "Registration failed"
                                        :context (list :|username| username
                                                       :|error| error-message))))
              (twitter-like.service.auth::increment-rate-limit :register client-ip :window 3600)
              (response-error 400 error-message :error-id error-id)))))))

;;; ============================================================
;;; POST /api/auth/login
;;; ============================================================

(defun handle-login (env)
  "ログインハンドラー"
  (let* ((client-ip (get-client-ip env))
         (body (parse-json-body env))
         (existing-session-id (get-session-id-from-cookie env)))

    ;; リクエストボディの検証
    (unless body
      (return-from handle-login
        (response-error 400 "Invalid request body")))

    (let ((username (gethash "username" body))
          (password (gethash "password" body)))

      ;; ユーザー名の基本検証
      (unless (and username (stringp username) (> (length username) 0))
        (return-from handle-login
          (response-error 400 "Username is required")))

      ;; IPベースレート制限チェック
      (multiple-value-bind (allowed remaining)
          (check-rate-limit :login client-ip)
        (unless allowed
          (log-warn "Rate limit exceeded for login"
                    :context (list :|ip| client-ip :|username| username))
          (return-from handle-login
            (response-error 429 "Too many login attempts. Please try again later."))))

      ;; アカウントロックアウトチェック
      (multiple-value-bind (locked remaining-seconds)
          (check-account-lockout username)
        (when locked
          (log-warn "Account locked out"
                    :context (list :|username| username
                                   :|remaining_seconds| remaining-seconds))
          (return-from handle-login
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
              (response-with-cookie 200
                                    (list (cons "user" (user-to-public-json user)))
                                    cookie))
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
              (let ((error-id (log-warn "Login failed"
                                        :context (list :|username| username))))
                (response-error 401 error-message :error-id error-id))))))))

;;; ============================================================
;;; POST /api/auth/logout
;;; ============================================================

(defun handle-logout (env)
  "ログアウトハンドラー"
  (let ((session-id (get-session-id-from-cookie env)))

    ;; セッションの検証
    (unless session-id
      (return-from handle-logout
        (response-error 401 "Unauthorized")))

    (let ((user-id (get-session-user-id session-id)))
      (unless user-id
        (return-from handle-logout
          (response-error 401 "Unauthorized")))

      ;; セッションのタイムアウトチェック
      (when (session-idle-expired-p session-id)
        (delete-session session-id)
        (return-from handle-logout
          (response-error 401 "Session expired")))

      ;; CSRF検証
      (let* ((submitted-token (getf env :http-x-csrf-token))
             (stored-token (get-csrf-token session-id)))
        (unless (and submitted-token stored-token
                     (constant-time-string= submitted-token stored-token))
          (let ((error-id (log-warn "Invalid CSRF token on logout"
                                    :context (list :|user_id| user-id
                                                   :|session| (mask-session-id session-id)))))
            (return-from handle-logout
              (response-error 403 "Invalid CSRF token" :error-id error-id)))))

      ;; セッション削除
      (delete-session session-id)
      (log-info "User logged out"
                :context (list :|user_id| user-id
                               :|session| (mask-session-id session-id)))

      ;; Cookie削除
      (response-with-cookie 200
                            (list (cons "message" "Logged out successfully"))
                            (build-session-clear-cookie)))))

;;; ============================================================
;;; GET /api/auth/me
;;; ============================================================

(defun handle-me (env)
  "現在のユーザー情報取得ハンドラー"
  (let ((session-id (get-session-id-from-cookie env)))

    ;; セッションの検証
    (unless session-id
      (return-from handle-me
        (response-error 401 "Unauthorized")))

    (let ((user-id (get-session-user-id session-id)))
      (unless user-id
        (return-from handle-me
          (response-error 401 "Unauthorized")))

      ;; セッションのタイムアウトチェック
      (when (session-idle-expired-p session-id)
        (delete-session session-id)
        (return-from handle-me
          (response-error 401 "Session expired")))

      ;; セッションのアクセス時刻を更新
      (touch-session session-id)

      ;; ユーザー情報取得
      (let ((user (find-user-by-id user-id)))
        (unless user
          (delete-session session-id)
          (return-from handle-me
            (response-error 401 "Unauthorized")))

        ;; CSRFトークンをヘッダーに含めて返す
        (let* ((csrf-token (get-csrf-token session-id))
               (json-string (com.inuoe.jzon:stringify
                             (list (cons "user" (user-to-private-json user))))))
          (list 200
                (list :content-type "application/json; charset=utf-8"
                      :x-csrf-token csrf-token)
                (list json-string)))))))

;;; ============================================================
;;; ルート登録
;;; ============================================================

(defun register-auth-routes (app)
  "認証ルートをアプリケーションに登録"
  (setf (ningle:route app "/api/auth/register" :method :post)
        (lambda (params)
          (declare (ignore params))
          (lambda (env) (handle-register env))))
  (setf (ningle:route app "/api/auth/login" :method :post)
        (lambda (params)
          (declare (ignore params))
          (lambda (env) (handle-login env))))
  (setf (ningle:route app "/api/auth/logout" :method :post)
        (lambda (params)
          (declare (ignore params))
          (lambda (env) (handle-logout env))))
  (setf (ningle:route app "/api/auth/me" :method :get)
        (lambda (params)
          (declare (ignore params))
          (lambda (env) (handle-me env))))
  app)
