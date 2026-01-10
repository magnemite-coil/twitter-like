;;; src/util/request.lisp
;;; リクエスト処理の共通ユーティリティ

(defpackage twitter-like.util.request
  (:use :cl)
  (:import-from :com.inuoe.jzon
                :parse)
  (:import-from :twitter-like.util.logger
                :log-info
                :log-warn)
  (:export :get-env
           :parse-json-body
           :parse-cookie-string
           :get-session-id-from-cookie
           :get-csrf-header
           :get-client-ip
           :get-content-type
           :validate-content-type
           :get-query-param
           ;; Phase 2: cursor pagination
           :clamp-pagination-count
           :clamp-count
           :parse-cursor-param
           :get-query-param-cursor
           :+max-bigint+))

(in-package :twitter-like.util.request)

(defun get-env ()
  "ningleのコンテキストからリクエスト環境を取得"
  (lack.request:request-env (ningle:context :request)))

(defconstant +max-body-size+ (* 1 1024 1024)
  "リクエストボディの最大サイズ: 1MB（DoS対策）")

(defun parse-json-body ()
  "リクエストボディをJSONとしてパース
   セキュリティ: Content-Length が +max-body-size+ を超える場合は拒否"
  (handler-case
      (let ((env (get-env)))
        (let* ((content-length-raw (getf env :content-length))
               (content-length (if (stringp content-length-raw)
                                   (parse-integer content-length-raw :junk-allowed t)
                                   content-length-raw))
               (body-stream (getf env :raw-body)))
          ;; Content-Length 上限チェック（DoS対策）
          (when (and content-length (> content-length +max-body-size+))
            (log-warn "Request body too large"
                      :context (list :|content_length| content-length
                                     :|max_size| +max-body-size+))
            (return-from parse-json-body nil))
          (when (and content-length body-stream (> content-length 0))
            (let ((body-bytes (make-array content-length :element-type '(unsigned-byte 8))))
              (read-sequence body-bytes body-stream)
              (let ((body-string (babel:octets-to-string body-bytes :encoding :utf-8)))
                (com.inuoe.jzon:parse body-string))))))
    (error (e)
      (log-warn "Failed to parse JSON body"
                :context (list :|error| (princ-to-string e)))
      nil)))

(defun trust-proxy-p ()
  "プロキシを信頼するかどうかを環境変数から判定
   TRUST_PROXY=true または TRUST_PROXY=1 の場合のみ true を返す"
  (let ((trust-proxy (uiop:getenv "TRUST_PROXY")))
    (and trust-proxy
         (or (string-equal trust-proxy "true")
             (string-equal trust-proxy "1")))))

(defun parse-x-forwarded-for (xff-header)
  "X-Forwarded-Forヘッダーから最初のIPアドレスを抽出
   形式: 'client, proxy1, proxy2' の場合、最初のclientを返す"
  (when (and xff-header (stringp xff-header) (> (length xff-header) 0))
    (let ((first-ip (str:trim (first (str:split "," xff-header)))))
      (when (> (length first-ip) 0)
        first-ip))))

(defun get-client-ip ()
  "クライアントIPアドレスを取得
   セキュリティ: X-Forwarded-Forは信頼できるプロキシ経由時のみ使用
   - TRUST_PROXY=true/1 の場合: X-Forwarded-Forの最初のIPを使用
   - それ以外: remote-addrを使用（プロキシ偽装攻撃対策）"
  (let ((env (get-env)))
    (if (trust-proxy-p)
        ;; 信頼できるプロキシ経由: X-Forwarded-Forを使用
        (or (parse-x-forwarded-for (getf env :http-x-forwarded-for))
            (getf env :remote-addr)
            "unknown")
        ;; プロキシを信頼しない: remote-addrのみ使用
        (or (getf env :remote-addr)
            "unknown"))))

(defun parse-cookie-string (cookie-string)
  "Cookie文字列をパースしてセッションIDを抽出
   RFC 6265準拠: セミコロン区切り（空白の有無に関わらず対応）"
  (when (and cookie-string (stringp cookie-string) (> (length cookie-string) 0))
    (loop for pair in (str:split ";" cookie-string)
          for trimmed-pair = (str:trim pair)
          for eq-pos = (position #\= trimmed-pair)
          when eq-pos
          do (let ((name (subseq trimmed-pair 0 eq-pos))
                   (value (subseq trimmed-pair (1+ eq-pos))))
               (when (string= name "session_id")
                 (return value))))))

(defun get-session-id-from-cookie ()
  "CookieからセッションIDを取得

   Clack/Lack標準に従い、以下の順序でCookieを探索:
   1. :headers ハッシュテーブルの 'cookie' キー（Clack標準）
   2. lack.request:request-cookies（Lackミドルウェア経由）"
  (let* ((env (get-env))
         (headers (getf env :headers))
         (raw-cookie (when (hash-table-p headers)
                       (gethash "cookie" headers)))
         (cookie-string (cond
                          ((stringp raw-cookie) raw-cookie)
                          ((and (listp raw-cookie) (stringp (first raw-cookie)))
                           (first raw-cookie))
                          (t raw-cookie))))
    (or (parse-cookie-string cookie-string)
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

(defun get-content-type ()
  "リクエストヘッダーからContent-Typeを取得
  Clack/Lack では :content-type は env に直接設定される"
  (let ((env (get-env)))
    (getf env :content-type)))

(defun validate-content-type ()
  "Content-Typeがapplication/jsonであることを検証（OWASP準拠）
  戻り値: (values valid-p error-status error-message)"
  (let ((content-type (get-content-type)))
    (if (and content-type
             (search "application/json" content-type))
        (values t nil nil)
        (values nil 415 "Unsupported Media Type"))))

(defun get-query-param (name &key (default nil) (type :string))
  "クエリパラメータを取得（lack.request利用でURLデコード対応）"
  (let* ((request (ningle:context :request))
         (query-params (when request
                         (handler-case
                             (lack.request:request-query-parameters request)
                           (error () nil))))
         (value (when query-params
                  (cdr (assoc name query-params :test #'string=)))))
    (if value
        (case type
          (:integer
           (handler-case
               (let ((parsed (parse-integer value :junk-allowed nil)))
                 (if parsed parsed default))
             (error () default)))
          (t value))
        default)))

;;; ============================================================
;;; Phase 2: カーソルベースページネーション
;;; ============================================================

(defconstant +max-bigint+ 9223372036854775807
  "PostgreSQL bigint の上限値")

(defun clamp-pagination-count (value &key (min 1) (max 100) (default 20))
  "ページネーションのcount/limitを有効範囲に制限"
  (cond
    ((null value) default)
    ((not (integerp value)) default)
    ((< value min) default)
    ((> value max) default)
    (t value)))

(defun clamp-count (value)
  "countを有効範囲に制限（clamp-pagination-countのエイリアス）
   DEPRECATED: clamp-pagination-count を直接使用すること"
  (clamp-pagination-count value))

(defun parse-cursor-param (name)
  "カーソルパラメータをパースし、(values value valid-p) を返す"
  (let ((raw (get-query-param name :type :string)))
    (cond
      ((null raw) (values nil t))
      ((zerop (length raw)) (values nil nil))
      ((every #'digit-char-p raw)
       (let ((value (parse-integer raw)))
         (if (<= value +max-bigint+)
             (values value t)
             (values nil nil))))
      (t (values nil nil)))))

(defun get-query-param-cursor ()
  "カーソルベースのページネーションパラメータを取得
   戻り値: (values max-id since-id count offset mode error-message)"
  (multiple-value-bind (max-id max-id-valid) (parse-cursor-param "max_id")
    (multiple-value-bind (since-id since-id-valid) (parse-cursor-param "since_id")
      (unless max-id-valid
        (return-from get-query-param-cursor
          (values nil nil nil nil :error "Invalid max_id: must be an integer")))
      (unless since-id-valid
        (return-from get-query-param-cursor
          (values nil nil nil nil :error "Invalid since_id: must be an integer")))

      (multiple-value-bind (raw-count count-valid) (parse-cursor-param "count")
        (unless count-valid
          (return-from get-query-param-cursor
            (values nil nil nil nil :error "Invalid count: must be an integer")))

        (multiple-value-bind (limit limit-valid) (parse-cursor-param "limit")
          (unless limit-valid
            (return-from get-query-param-cursor
              (values nil nil nil nil :error "Invalid limit: must be an integer")))

          (multiple-value-bind (offset offset-valid) (parse-cursor-param "offset")
            (unless offset-valid
              (return-from get-query-param-cursor
                (values nil nil nil nil :error "Invalid offset: must be an integer")))

            (let ((mode (cond
                          ((or max-id since-id) :cursor)
                          ((and raw-count (not limit) (not offset)) :cursor)
                          (t :offset))))
              (when (and raw-count (or limit offset) (not max-id) (not since-id))
                (log-info "Mixed parameters: count with limit/offset"
                          :context (list :|count| raw-count :|limit| limit :|offset| offset)))
              (when (and (eq mode :cursor) (or limit offset))
                (log-info "Deprecated: limit/offset with cursor params"
                          :context (list :|limit| limit :|offset| offset)))
              (let ((count (clamp-pagination-count (or raw-count limit))))
                (values max-id since-id count offset mode nil)))))))))
