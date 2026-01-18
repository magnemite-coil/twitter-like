(defpackage twitter-like.middleware.security
  (:use :cl)
  (:export :security-headers-middleware))

(in-package :twitter-like.middleware.security)

(defparameter *security-headers*
  (list :content-security-policy "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'"
        :strict-transport-security "max-age=63072000; includeSubDomains; preload"
        :x-content-type-options "nosniff"
        :x-frame-options "DENY"
        :referrer-policy "strict-origin-when-cross-origin"
        :permissions-policy "geolocation=(), microphone=(), camera=()")
  "Security headers to be added to all responses (OWASP 2024-2025 compliant).
   CSP follows strict policy: default-src 'none' as baseline.")

(defparameter *security-header-keys*
  '(:content-security-policy :strict-transport-security
    :x-content-type-options :x-frame-options
    :referrer-policy :permissions-policy)
  "List of security header keys that should be overridden by middleware.")

(defun normalize-header-key (key)
  "Normalize header key to keyword for comparison.
   Handles both keyword and string keys from upstream responses."
  (etypecase key
    (keyword key)
    (string (intern (string-upcase key) :keyword))
    (symbol (intern (string-upcase (symbol-name key)) :keyword))))

(defun security-header-key-p (key)
  "Check if key is a security header that should be filtered out.
   Handles both keyword and string keys."
  (member (normalize-header-key key) *security-header-keys*))

(defun security-headers-middleware (app)
  "セキュリティヘッダーを追加するミドルウェア
   Woo/Clackのベストプラクティス:
   - responseがNILの場合は適切にハンドリング
   - すべてのヘッダー値は文字列である必要がある
   - 上流のセキュリティヘッダーは上書きする（セキュリティ境界の一貫性確保）
   - フォールバック500レスポンスにもセキュリティヘッダーを付与"
  (lambda (env)
    (let ((response (funcall app env)))
      (if (and response (listp response) (>= (length response) 3))
          ;; 正常なレスポンスの場合のみセキュリティヘッダーを追加
          (let* ((status (first response))
                 (headers (second response))
                 (body (third response))
                 ;; 既存のセキュリティヘッダーをフィルタリング（キーワード/文字列両対応）
                 (filtered-headers (loop for (key value) on (or headers '()) by #'cddr
                                         unless (security-header-key-p key)
                                         append (list key value)))
                 (new-headers (append filtered-headers *security-headers*)))
            (list status new-headers body))
          ;; 異常なレスポンスの場合は500エラーを返す（セキュリティヘッダー付与）
          (list 500
                (append (list :content-type "text/plain") *security-headers*)
                (list "Internal Server Error"))))))
