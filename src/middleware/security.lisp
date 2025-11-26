(defpackage twitter-like.middleware.security
  (:use :cl)
  (:export :security-headers-middleware))

(in-package :twitter-like.middleware.security)

(defun security-headers-middleware (app)
  "セキュリティヘッダーを追加するミドルウェア"
  (lambda (env)
    (let ((response (funcall app env)))
      ;; レスポンスヘッダーにセキュリティヘッダーを追加（plist形式）
      (let ((headers (second response)))
        ;; 既存のヘッダーにセキュリティヘッダーを追加
        (setf headers (append headers
                              (list :content-security-policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'"
                                    :strict-transport-security "max-age=63072000; includeSubDomains; preload"
                                    :x-content-type-options "nosniff"
                                    :x-frame-options "DENY"
                                    :referrer-policy "strict-origin-when-cross-origin"
                                    :permissions-policy "geolocation=(), microphone=(), camera=()")))
        (setf (second response) headers))
      response)))
