(defpackage twitter-like.middleware.security
  (:use :cl)
  (:export :security-headers-middleware))

(in-package :twitter-like.middleware.security)

(defun security-headers-middleware (app)
  "セキュリティヘッダーを追加するミドルウェア
   Woo/Clackのベストプラクティス:
   - responseがNILの場合は適切にハンドリング
   - すべてのヘッダー値は文字列である必要がある"
  (lambda (env)
    (let ((response (funcall app env)))
      (if (and response (listp response) (>= (length response) 3))
          ;; 正常なレスポンスの場合のみセキュリティヘッダーを追加
          (let* ((status (first response))
                 (headers (second response))
                 (body (third response))
                 (new-headers (append (or headers '())
                                      (list :content-security-policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'"
                                            :strict-transport-security "max-age=63072000; includeSubDomains; preload"
                                            :x-content-type-options "nosniff"
                                            :x-frame-options "DENY"
                                            :referrer-policy "strict-origin-when-cross-origin"
                                            :permissions-policy "geolocation=(), microphone=(), camera=()"))))
            (list status new-headers body))
          ;; 異常なレスポンスの場合は500エラーを返す
          (list 500
                (list :content-type "text/plain")
                (list "Internal Server Error"))))))
