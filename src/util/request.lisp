;;; src/util/request.lisp
;;; リクエスト処理の共通ユーティリティ

(defpackage twitter-like.util.request
  (:use :cl)
  (:import-from :com.inuoe.jzon
                :parse)
  (:import-from :twitter-like.util.logger
                :log-warn)
  (:export :get-env
           :parse-json-body
           :parse-cookie-string
           :get-session-id-from-cookie
           :get-csrf-header
           :get-client-ip
           :get-content-type
           :validate-content-type
           :get-query-param))

(in-package :twitter-like.util.request)

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
      (log-warn "Failed to parse JSON body"
                :context (list :|error| (princ-to-string e)))
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
