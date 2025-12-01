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
  (:export :register-handler
           :login-handler
           :logout-handler
           :me-handler
           :register-auth-routes))

(in-package :twitter-like.handler.auth)

;;; ============================================================
;;; ユーティリティ関数
;;; ============================================================

(defun get-env ()
  "ningleのコンテキストからリクエスト環境を取得"
  (lack.request:request-env (ningle:context :request)))

(defun parse-json-body ()
  "リクエストボディをJSONとしてパース"
  (handler-case
      (let ((env (get-env)))
        (let* ((content-length-raw (getf env :content-length))
               (content-length (if (stringp content-length-raw)
                                   (parse-integer content-length-raw :junk-allowed t)
                                   content-length-raw))
               (body-stream (getf env :raw-body)))
          (when (and content-length body-stream (> content-length 0))
            (let ((body-bytes (make-array content-length :element-type '(unsigned-byte 8))))
              (read-sequence body-bytes body-stream)
              (let ((body-string (babel:octets-to-string body-bytes :encoding :utf-8)))
                (com.inuoe.jzon:parse body-string))))))
    (error (e)
      (log-warn (format nil "Failed to parse JSON body: ~A" e))
      nil)))

(defun get-client-ip ()
  "クライアントIPアドレスを取得（X-Forwarded-For対応）"
  (let ((env (get-env)))
    (or (getf env :http-x-forwarded-for)
        (getf env :remote-addr)
        "unknown")))

(defun parse-cookie-string (cookie-string)
  "Cookie文字列をパースしてセッションIDを抽出"
  (when (and cookie-string (stringp cookie-string) (> (length cookie-string) 0))
    (loop for pair in (str:split "; " cookie-string)
          for eq-pos = (position #\= pair)
          when eq-pos
          do (let ((name (subseq pair 0 eq-pos))
                   (value (subseq pair (1+ eq-pos))))
               (when (string= name "session_id")
                 (return value))))))

(defun get-session-id-from-cookie ()
  "CookieからセッションIDを取得

   Clack/Lack標準に従い、以下の順序でCookieを探索:
   1. :headers ハッシュテーブルの 'cookie' キー（Clack標準）
   2. lack.request:request-cookies（Lackミドルウェア経由）"
  (let* ((env (get-env))
         (headers (getf env :headers))
         ;; Clack標準: headersハッシュテーブルから小文字キーで取得
         (cookie-string (when (hash-table-p headers)
                          (gethash "cookie" headers))))
    ;; headersから取得できた場合はパース
    (or (parse-cookie-string cookie-string)
        ;; フォールバック: lack.request:request-cookies を使用
        (let* ((request (ningle:context :request))
               (cookies (when request
                          (handler-case
                              (lack.request:request-cookies request)
                            (error () nil)))))
          (when (consp cookies)
            (cdr (assoc "session_id" cookies :test #'string=)))))))

(defun get-csrf-header ()
  "リクエストヘッダーからCSRFトークンを取得
   Clack標準に従い、:headersハッシュテーブルから小文字キーで取得"
  (let* ((env (get-env))
         (headers (getf env :headers)))
    (when (hash-table-p headers)
      (gethash "x-csrf-token" headers))))

(defun response-with-cookie (status data cookie-value &key extra-headers)
  "Cookieを含むレスポンスを生成"
  (let* ((json-string (com.inuoe.jzon:stringify data))
         (content-length (length (babel:string-to-octets json-string :encoding :utf-8)))
         (headers (append (list :content-type "application/json; charset=utf-8"
                                ;; Woo/Clackはヘッダー値に文字列を要求
                                :content-length (write-to-string content-length)
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
            ;; 失敗
            (let ((error-id (log-error "Registration failed"
                                        :context (list :|username| username
                                                       :|error| error-message))))
              (twitter-like.service.auth::increment-rate-limit :register client-ip :window 3600)
              (response-error 400 error-message :error-id error-id)))))))

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
              (let ((error-id (log-warn "Login failed"
                                        :context (list :|username| username))))
                (response-error 401 error-message :error-id error-id))))))))

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

      ;; セッションのタイムアウトチェック
      (when (session-idle-expired-p session-id)
        (delete-session session-id)
        (return-from logout-handler
          (response-error 401 "Session expired")))

      ;; CSRF検証
      (let* ((submitted-token (get-csrf-header))
             (stored-token (get-csrf-token session-id)))
        (unless (and submitted-token stored-token
                     (constant-time-string= submitted-token stored-token))
          (let ((error-id (log-warn "Invalid CSRF token on logout"
                                    :context (list :|user_id| user-id
                                                   :|session| (mask-session-id session-id)))))
            (return-from logout-handler
              (response-error 403 "Invalid CSRF token" :error-id error-id)))))

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
      (return-from me-handler
        (response-error 401 "Unauthorized")))

    (let ((user-id (get-session-user-id session-id)))
      (unless user-id
        (return-from me-handler
          (response-error 401 "Unauthorized")))

      ;; セッションのタイムアウトチェック
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
                        :content-length (write-to-string content-length)
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
