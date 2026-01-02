;;; src/handler/tweet.lisp

(defpackage twitter-like.handler.tweet
  (:use :cl)
  (:import-from :com.inuoe.jzon
                :parse
                :stringify)
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
                :parse-json-body
                :get-session-id-from-cookie
                :get-csrf-header
                :validate-content-type
                :get-query-param)
  (:import-from :twitter-like.middleware.session
                :get-session-user-id
                :get-csrf-token
                :session-idle-expired-p
                :session-absolute-expired-p
                :touch-session
                :delete-session)
  (:import-from :twitter-like.model.tweet
                :tweet-to-json)
  (:import-from :twitter-like.service.tweet
                :create-tweet
                :delete-tweet
                :get-tweet-by-id
                :get-tweets-by-user
                :get-user-by-username
                :check-and-increment-rate-limit
                :+tweet-rate-limit+
                :+tweet-rate-window+
                :get-unix-time)
  (:export :create-tweet-handler
           :get-tweet-handler
           :delete-tweet-handler
           :get-user-tweets-handler
           :register-tweet-routes))

(in-package :twitter-like.handler.tweet)

;;; ============================================================
;;; ハンドラー固有のユーティリティ関数
;;; ============================================================

(defun require-auth ()
  "認証を要求し、user-idを返す。未認証の場合はnilを返す
  セキュリティ基準: アイドルタイムアウト + 絶対タイムアウトの両方をチェック"
  (let ((session-id (get-session-id-from-cookie)))
    (unless session-id
      (return-from require-auth (values nil nil "Unauthorized")))
    (let ((user-id (get-session-user-id session-id)))
      (unless user-id
        (return-from require-auth (values nil nil "Unauthorized")))
      ;; 絶対タイムアウトチェック（セッション作成からの経過時間）
      (when (session-absolute-expired-p session-id)
        (delete-session session-id)
        (return-from require-auth (values nil nil "Session expired")))
      ;; アイドルタイムアウトチェック（最終アクセスからの経過時間）
      (when (session-idle-expired-p session-id)
        (delete-session session-id)
        (return-from require-auth (values nil nil "Session expired")))
      (touch-session session-id)
      (values user-id session-id nil))))

(defun require-csrf (session-id)
  "CSRF検証を行う。失敗時はnilを返す"
  (let* ((submitted-token (get-csrf-header))
         (stored-token (get-csrf-token session-id)))
    (and submitted-token stored-token
         (constant-time-string= submitted-token stored-token))))

;;; ============================================================
;;; POST /api/tweets - ツイート投稿
;;; ============================================================

(defun create-tweet-handler (params)
  "ツイート投稿ハンドラー"
  (declare (ignore params))

  ;; Content-Type検証（OWASP準拠 - 認証チェックより先に実施）
  (multiple-value-bind (valid-p error-status error-message) (validate-content-type)
    (unless valid-p
      (return-from create-tweet-handler
        (response-error error-status error-message))))

  ;; 認証チェック
  (multiple-value-bind (user-id session-id error-message) (require-auth)
    (unless user-id
      (return-from create-tweet-handler
        (response-error 401 error-message)))

    ;; CSRF検証（クライアント起因エラーはlog-warn、error_idなし）
    (unless (require-csrf session-id)
      (log-warn "Invalid CSRF token on tweet create"
                :context (list :|user_id| user-id))
      (return-from create-tweet-handler
        (response-error 403 "Invalid CSRF token")))

    ;; レート制限チェック＋インクリメント（原子的操作）
    (multiple-value-bind (allowed remaining reset-time)
        (check-and-increment-rate-limit user-id)
      (declare (ignore remaining))
      (unless allowed
        (log-warn "Tweet rate limit exceeded"
                  :context (list :|user_id| user-id))
        ;; handler層でレスポンス生成
        ;; reset-time が nil の場合は現在時刻 + ウィンドウ幅をフォールバックとして使用
        (let* ((base-response (response-error 429 "Too many tweets. Please try again later."))
               (base-headers (second base-response))
               (now (get-unix-time))
               (effective-reset-time (or reset-time (+ now +tweet-rate-window+)))
               (retry-after (max 0 (- effective-reset-time now)))
               (extra-headers (list :retry-after (write-to-string retry-after)
                                    :x-ratelimit-limit (write-to-string +tweet-rate-limit+)
                                    :x-ratelimit-remaining "0"
                                    :x-ratelimit-reset (write-to-string effective-reset-time)))
               (merged-headers (append base-headers extra-headers)))
          (return-from create-tweet-handler
            (list 429 merged-headers (third base-response))))))

    ;; リクエストボディのパース
    (let ((body (parse-json-body)))
      (unless body
        (return-from create-tweet-handler
          (response-error 400 "Invalid request body")))

      (let ((content (gethash "content" body)))
        ;; ツイート作成
        (multiple-value-bind (tweet error-message error-type error-id)
            (create-tweet user-id content)
          (if tweet
              (progn
                (log-info "Tweet created"
                          :context (list :|user_id| user-id
                                         :|tweet_id| (mito:object-id tweet)))
                (let ((response-data (make-hash-table :test 'equal)))
                  (setf (gethash "tweet" response-data)
                        (tweet-to-json tweet :include-user t))
                  (response-success response-data :status 201)))
              ;; エラー分類に応じてステータスコードとログレベルを決定
              (case error-type
                (:validation
                 (log-warn "Tweet validation failed"
                           :context (list :|user_id| user-id
                                          :|error| error-message))
                 (response-error 400 error-message))
                (:internal
                 (response-error 500 error-message :error-id error-id))
                (t
                 (log-warn "Tweet creation rejected"
                           :context (list :|user_id| user-id
                                          :|error| error-message))
                 (response-error 400 error-message)))))))))

;;; ============================================================
;;; GET /api/tweets/:id - ツイート取得
;;; ============================================================

(defun get-tweet-handler (params)
  "ツイート取得ハンドラー"
  (let* ((id-str (cdr (assoc :id params)))
         (tweet-id (when id-str
                     (handler-case (parse-integer id-str :junk-allowed nil)
                       (error () nil)))))

    (unless tweet-id
      (return-from get-tweet-handler
        (response-error 400 "Invalid tweet ID")))

    (let ((tweet (get-tweet-by-id tweet-id)))
      (unless tweet
        (return-from get-tweet-handler
          (response-error 404 "Tweet not found")))

      (let ((response-data (make-hash-table :test 'equal)))
        (setf (gethash "tweet" response-data)
              (tweet-to-json tweet :include-user t))
        (response-success response-data)))))

;;; ============================================================
;;; DELETE /api/tweets/:id - ツイート削除
;;; ============================================================

(defun delete-tweet-handler (params)
  "ツイート削除ハンドラー"
  (let* ((id-str (cdr (assoc :id params)))
         (tweet-id (when id-str
                     (handler-case (parse-integer id-str :junk-allowed nil)
                       (error () nil)))))

    (unless tweet-id
      (return-from delete-tweet-handler
        (response-error 400 "Invalid tweet ID")))

    ;; 認証チェック
    (multiple-value-bind (user-id session-id error-message) (require-auth)
      (unless user-id
        (return-from delete-tweet-handler
          (response-error 401 error-message)))

      ;; CSRF検証
      (unless (require-csrf session-id)
        (log-warn "Invalid CSRF token on tweet delete"
                  :context (list :|user_id| user-id
                                 :|tweet_id| tweet-id))
        (return-from delete-tweet-handler
          (response-error 403 "Invalid CSRF token")))

      ;; ツイート削除
      (multiple-value-bind (success-p error-message error-type error-id)
          (delete-tweet tweet-id user-id)
        (if success-p
            (progn
              (log-info "Tweet deleted"
                        :context (list :|user_id| user-id
                                       :|tweet_id| tweet-id))
              (let ((response-data (make-hash-table :test 'equal)))
                (setf (gethash "message" response-data) "Tweet deleted successfully")
                (response-success response-data)))
            ;; エラー分類に応じてステータスコードとログレベルを決定
            (case error-type
              (:not-found
               (log-warn "Tweet not found on delete"
                         :context (list :|user_id| user-id
                                        :|tweet_id| tweet-id))
               (response-error 404 error-message))
              (:forbidden
               (log-warn "Unauthorized tweet delete attempt"
                         :context (list :|user_id| user-id
                                        :|tweet_id| tweet-id))
               (response-error 403 error-message))
              (:internal
               (response-error 500 error-message :error-id error-id))
              (t
               (let ((error-id (log-error "Unexpected error on tweet delete"
                                          :context (list :|user_id| user-id
                                                         :|tweet_id| tweet-id
                                                         :|error| error-message))))
                 (response-error 500 "An internal error occurred" :error-id error-id)))))))))

;;; ============================================================
;;; GET /api/users/:username/tweets - ユーザーのツイート一覧
;;; ============================================================

(defun get-user-tweets-handler (params)
  "ユーザーのツイート一覧取得ハンドラー"
  (let ((username (cdr (assoc :username params))))

    (unless username
      (return-from get-user-tweets-handler
        (response-error 400 "Username is required")))

    ;; ユーザー存在確認（service経由で呼び出し）
    (let ((user (get-user-by-username username)))
      (unless user
        (return-from get-user-tweets-handler
          (response-error 404 "User not found")))

      ;; ページネーションパラメータ
      (let* ((raw-limit (get-query-param "limit" :default 20 :type :integer))
             (limit (if (and raw-limit (>= raw-limit 1) (<= raw-limit 100))
                        raw-limit
                        20))
             (raw-offset (get-query-param "offset" :default 0 :type :integer))
             (offset (max (or raw-offset 0) 0))
             (user-id (mito:object-id user))
             ;; has_more判定: limit+1件を取得し、limit件より多ければ次ページがある
             (tweets (get-tweets-by-user user-id :limit (1+ limit) :offset offset))
             (has-more (> (length tweets) limit))
             ;; 実際に返すのはlimit件まで
             (tweets-to-return (if has-more (butlast tweets) tweets)))

        (let ((response-data (make-hash-table :test 'equal))
              (pagination (make-hash-table :test 'equal)))
          (setf (gethash "tweets" response-data)
                (mapcar (lambda (tweet) (tweet-to-json tweet :include-user t))
                        tweets-to-return))
          (setf (gethash "limit" pagination) limit)
          (setf (gethash "offset" pagination) offset)
          (setf (gethash "has_more" pagination) has-more)
          (setf (gethash "pagination" response-data) pagination)
          (response-success response-data))))))

;;; ============================================================
;;; ルート登録
;;; ============================================================

(defun register-tweet-routes (app)
  "ツイートルートをアプリケーションに登録"
  (setf (ningle:route app "/api/tweets" :method :post) #'create-tweet-handler)
  (setf (ningle:route app "/api/tweets/:id" :method :get) #'get-tweet-handler)
  (setf (ningle:route app "/api/tweets/:id" :method :delete) #'delete-tweet-handler)
  (setf (ningle:route app "/api/users/:username/tweets" :method :get) #'get-user-tweets-handler)
  app)
