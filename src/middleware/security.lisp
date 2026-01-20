(defpackage twitter-like.middleware.security
  (:use :cl)
  (:export :security-headers-middleware
           :build-security-headers
           :production-environment-p))

(in-package :twitter-like.middleware.security)

;;; ============================================================
;;; Environment Detection
;;; ============================================================

(defun get-environment ()
  "Get current environment from APP_ENV config.
   Returns: \"production\", \"development\", or \"test\""
  (handler-case
      (or (twitter-like.config:get-config "app-env") "development")
    (error ()
      "development")))

(defun production-environment-p ()
  "Check if running in production environment.
   Returns T for production, NIL for development/test."
  (string-equal (get-environment) "production"))

;;; ============================================================
;;; Security Header Definitions
;;; ============================================================

(defparameter *base-security-headers*
  (list :content-security-policy "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; report-uri /api/csp-report"
        :x-content-type-options "nosniff"
        :x-frame-options "DENY"
        :referrer-policy "strict-origin-when-cross-origin"
        :permissions-policy "geolocation=(), microphone=(), camera=(), accelerometer=(), gyroscope=(), magnetometer=(), payment=(), usb=()")
  "Base security headers applied in all environments.
   CSP follows strict policy: default-src 'none' as baseline.")

(defparameter *hsts-header*
  (list :strict-transport-security "max-age=63072000; includeSubDomains; preload")
  "HSTS header for production environment only.
   Disabled in development/test to allow HTTP connections.")

(defparameter *security-header-keys*
  '(:content-security-policy :strict-transport-security
    :x-content-type-options :x-frame-options
    :referrer-policy :permissions-policy)
  "List of security header keys that should be overridden by middleware.")

;;; ============================================================
;;; Header Building
;;; ============================================================

(defun build-security-headers ()
  "Build security headers based on current environment.
   Production: All headers including HSTS
   Development/Test: All headers except HSTS (allows HTTP)"
  (if (production-environment-p)
      ;; Production: full security headers including HSTS
      (append (copy-list *base-security-headers*)
              (copy-list *hsts-header*))
      ;; Development/Test: security headers without HSTS
      (copy-list *base-security-headers*)))

;;; ============================================================
;;; Header Key Normalization
;;; ============================================================

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

;;; ============================================================
;;; Middleware
;;; ============================================================

(defun security-headers-middleware (app)
  "セキュリティヘッダーを追加するミドルウェア
   Woo/Clackのベストプラクティス:
   - responseがNILの場合は適切にハンドリング
   - すべてのヘッダー値は文字列である必要がある
   - 上流のセキュリティヘッダーは上書きする（セキュリティ境界の一貫性確保）
   - フォールバック500レスポンスにもセキュリティヘッダーを付与

   環境別設定:
   - Production: HSTS含むフルセキュリティヘッダー
   - Development/Test: HSTS除外（HTTP接続を許可）"
  ;; ミドルウェア生成時に一度だけヘッダーを構築（パフォーマンス最適化）
  (let ((security-headers (build-security-headers)))
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
                   ;; copy-list: 防御的プログラミング - appendの最後の引数は共有されるため、
                   ;; 後続でヘッダーplistが破壊的に更新された場合のグローバル汚染を防止
                   (new-headers (append filtered-headers (copy-list security-headers))))
              (list status new-headers body))
            ;; 異常なレスポンスの場合は500エラーを返す（セキュリティヘッダー付与）
            (list 500
                  (append (list :content-type "text/plain") (copy-list security-headers))
                  (list "Internal Server Error")))))))
