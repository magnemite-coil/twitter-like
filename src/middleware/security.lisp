(defpackage twitter-like.middleware.security
  (:use :cl)
  (:export :security-headers-middleware))

(in-package :twitter-like.middleware.security)

(defun security-headers-middleware (app)
  "セキュリティヘッダーを追加するミドルウェア"
  (lambda (env)
    (let ((response (funcall app env)))
      (when response
        ;; レスポンスヘッダーにセキュリティヘッダーを追加（plist形式）
        ;; 新しいリストを作成して返す（破壊的変更を避ける）
        (let* ((status (first response))
               (headers (second response))
               (body (third response))
               (new-headers (append headers
                                    (list :content-security-policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'"
                                          :strict-transport-security "max-age=63072000; includeSubDomains; preload"
                                          :x-content-type-options "nosniff"
                                          :x-frame-options "DENY"
                                          :referrer-policy "strict-origin-when-cross-origin"
                                          :permissions-policy "geolocation=(), microphone=(), camera=()"))))
          (list status new-headers body))))))
