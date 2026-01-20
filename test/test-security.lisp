(defpackage twitter-like-test.security
  (:use :cl :rove)
  (:import-from :twitter-like.middleware.security
                :security-headers-middleware
                :build-security-headers
                :production-environment-p)
  (:import-from :twitter-like-test.util
                :make-dummy-app
                :get-response-header))

(in-package :twitter-like-test.security)

;;; ============================================================
;;; Environment Guard Notes
;;; ============================================================

;;; This test file tests pure functions, so the following guards are unnecessary:
;;; - APP_ENV check (no Redis/DB connection used)
;;; - Redis host/port whitelist (no Redis connection used)
;;; - PostgreSQL connection check (no DB connection used)
;;;
;;; Reference: test-session.lisp implements multi-layer security guards
;;; because it actually connects to Redis.
;;; See test/test-session.lisp L30-74 for details.
;;;
;;; This test follows test-cors.lisp and test-crypto.lisp pattern.
;;;
;;; NOTE: Tests run in "test" environment (APP_ENV=test), which means:
;;; - HSTS header is NOT included (development/test mode)
;;; - All other security headers ARE included
;;; Environment-specific header tests are in test-security-headers-environment

;;; setup/teardown不要（純粋関数のテスト）

;;; ============================================================
;;; Helper Functions
;;; ============================================================

;;; make-dummy-app and get-response-header are imported from twitter-like-test.util

(defun has-base-security-headers-p (response)
  "Check if response has base security headers (excluding HSTS).
   Used for development/test environment where HSTS is disabled."
  (let ((headers (second response)))
    (and (getf headers :content-security-policy)
         (getf headers :x-content-type-options)
         (getf headers :x-frame-options)
         (getf headers :referrer-policy)
         (getf headers :permissions-policy))))

(defun has-all-security-headers-p (response)
  "Check if response has all required security headers including HSTS.
   Used for production environment tests."
  (let ((headers (second response)))
    (and (has-base-security-headers-p response)
         (getf headers :strict-transport-security))))

;;; ============================================================
;;; test-security-headers-normal-response (Section 3.1: 8 test cases)
;;; ============================================================
;;; Note: These tests run in test environment, so HSTS is excluded

(deftest test-security-headers-normal-response
  ;; #1: Standard 200 response
  (testing "adds security headers to standard 200 response"
    (let* ((app (make-dummy-app '(200 (:content-type "text/plain") ("OK"))))
           (middleware (security-headers-middleware app))
           (env '(:request-method :get))
           (response (funcall middleware env)))
      (ok (= (first response) 200)
          "Should return 200 status")
      (ok (has-base-security-headers-p response)
          "Should have base security headers (HSTS excluded in test env)")
      (ok (string= (get-response-header response :content-type) "text/plain")
          "Should preserve original Content-Type header")))

  ;; #2: Response with existing non-security headers
  (testing "preserves existing non-security headers"
    (let* ((app (make-dummy-app '(200 (:content-type "application/json" :x-custom "value") ("{}"))))
           (middleware (security-headers-middleware app))
           (env '(:request-method :get))
           (response (funcall middleware env)))
      (ok (= (first response) 200)
          "Should return 200 status")
      (ok (string= (get-response-header response :content-type) "application/json")
          "Should preserve Content-Type header")
      (ok (string= (get-response-header response :x-custom) "value")
          "Should preserve custom header")
      (ok (has-base-security-headers-p response)
          "Should have base security headers")))

  ;; #3: Response with empty headers
  (testing "adds security headers to response with empty headers"
    (let* ((app (make-dummy-app '(200 () ("OK"))))
           (middleware (security-headers-middleware app))
           (env '(:request-method :get))
           (response (funcall middleware env)))
      (ok (= (first response) 200)
          "Should return 200 status")
      (ok (has-base-security-headers-p response)
          "Should have base security headers")))

  ;; #4: Response with NIL headers
  (testing "adds security headers to response with NIL headers"
    (let* ((app (make-dummy-app '(200 nil ("OK"))))
           (middleware (security-headers-middleware app))
           (env '(:request-method :get))
           (response (funcall middleware env)))
      (ok (= (first response) 200)
          "Should return 200 status")
      (ok (has-base-security-headers-p response)
          "Should have base security headers")))

  ;; #5: 404 error response
  (testing "adds security headers to 404 error response"
    (let* ((app (make-dummy-app '(404 (:content-type "text/plain") ("Not Found"))))
           (middleware (security-headers-middleware app))
           (env '(:request-method :get))
           (response (funcall middleware env)))
      (ok (= (first response) 404)
          "Should return 404 status")
      (ok (has-base-security-headers-p response)
          "Should have base security headers on error response")))

  ;; #6: 500 error response from app
  (testing "adds security headers to 500 error response from app"
    (let* ((app (make-dummy-app '(500 (:content-type "text/plain") ("Error"))))
           (middleware (security-headers-middleware app))
           (env '(:request-method :get))
           (response (funcall middleware env)))
      (ok (= (first response) 500)
          "Should return 500 status")
      (ok (has-base-security-headers-p response)
          "Should have base security headers on 500 error response")))

  ;; #7: Response with empty body
  (testing "adds security headers to response with empty body"
    (let* ((app (make-dummy-app '(200 (:content-type "text/plain") ())))
           (middleware (security-headers-middleware app))
           (env '(:request-method :get))
           (response (funcall middleware env)))
      (ok (= (first response) 200)
          "Should return 200 status")
      (ok (has-base-security-headers-p response)
          "Should have base security headers")))

  ;; #8: Response with conflicting security header (CRITICAL)
  ;; Middleware's CSP must take precedence over upstream's unsafe CSP
  (testing "overrides upstream security headers with secure values"
    (let* ((unsafe-csp "default-src 'unsafe-inline' 'unsafe-eval'")
           (app (make-dummy-app `(200 (:content-security-policy ,unsafe-csp) ("OK"))))
           (middleware (security-headers-middleware app))
           (env '(:request-method :get))
           (response (funcall middleware env)))
      (ok (= (first response) 200)
          "Should return 200 status")
      ;; CRITICAL: Middleware's CSP must take precedence over upstream's unsafe CSP
      (ok (string= (get-response-header response :content-security-policy)
                   "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; report-uri /api/csp-report")
          "Middleware CSP should override upstream's unsafe CSP")
      ;; Verify upstream's unsafe CSP is NOT present
      (ok (not (search "unsafe-eval" (get-response-header response :content-security-policy)))
          "Upstream's unsafe-eval should not be in final CSP"))))

;;; ============================================================
;;; test-security-headers-abnormal-response (Section 3.2: 6 test cases)
;;; ============================================================

(deftest test-security-headers-abnormal-response
  ;; #1: Response is NIL
  ;; UPDATED: Fallback 500 now includes security headers for defense consistency
  (testing "returns 500 with security headers for NIL response"
    (let* ((app (make-dummy-app nil))
           (middleware (security-headers-middleware app))
           (env '(:request-method :get))
           (response (funcall middleware env)))
      (ok (= (first response) 500)
          "Should return 500 status")
      (ok (string= (get-response-header response :content-type) "text/plain")
          "Should have text/plain Content-Type")
      (ok (equal (third response) '("Internal Server Error"))
          "Should have error message body")
      (ok (has-base-security-headers-p response)
          "Should have security headers on fallback 500 response for defense consistency")))

  ;; #2: Response is not a list (string)
  (testing "returns 500 for string response"
    (let* ((app (make-dummy-app "string"))
           (middleware (security-headers-middleware app))
           (env '(:request-method :get))
           (response (funcall middleware env)))
      (ok (= (first response) 500)
          "Should return 500 status")
      (ok (string= (get-response-header response :content-type) "text/plain")
          "Should have text/plain Content-Type")
      (ok (equal (third response) '("Internal Server Error"))
          "Should have error message body")))

  ;; #3: Response is a number
  (testing "returns 500 for number response"
    (let* ((app (make-dummy-app 200))
           (middleware (security-headers-middleware app))
           (env '(:request-method :get))
           (response (funcall middleware env)))
      (ok (= (first response) 500)
          "Should return 500 status")
      (ok (string= (get-response-header response :content-type) "text/plain")
          "Should have text/plain Content-Type")))

  ;; #4: Response has 1 element
  (testing "returns 500 for 1-element response"
    (let* ((app (make-dummy-app '(200)))
           (middleware (security-headers-middleware app))
           (env '(:request-method :get))
           (response (funcall middleware env)))
      (ok (= (first response) 500)
          "Should return 500 status")
      (ok (equal (third response) '("Internal Server Error"))
          "Should have error message body")))

  ;; #5: Response has 2 elements
  (testing "returns 500 for 2-element response"
    (let* ((app (make-dummy-app '(200 ())))
           (middleware (security-headers-middleware app))
           (env '(:request-method :get))
           (response (funcall middleware env)))
      (ok (= (first response) 500)
          "Should return 500 status")
      (ok (equal (third response) '("Internal Server Error"))
          "Should have error message body")))

  ;; #6: Response is empty list
  (testing "returns 500 for empty list response"
    (let* ((app (make-dummy-app '()))
           (middleware (security-headers-middleware app))
           (env '(:request-method :get))
           (response (funcall middleware env)))
      (ok (= (first response) 500)
          "Should return 500 status")
      (ok (string= (get-response-header response :content-type) "text/plain")
          "Should have text/plain Content-Type"))))

;;; ============================================================
;;; test-security-headers-values (Section 3.3: 6 test cases)
;;; ============================================================
;;; Note: HSTS test checks for absence in test environment

(deftest test-security-headers-values
  (let* ((app (make-dummy-app '(200 (:content-type "text/plain") ("OK"))))
         (middleware (security-headers-middleware app))
         (env '(:request-method :get))
         (response (funcall middleware env)))

    ;; #1: Content-Security-Policy
    (testing "sets correct Content-Security-Policy value"
      (ok (string= (get-response-header response :content-security-policy)
                   "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; report-uri /api/csp-report")
          "CSP should match expected value"))

    ;; #2: Strict-Transport-Security (environment-dependent)
    (testing "HSTS is excluded in development/test environment"
      (ok (null (get-response-header response :strict-transport-security))
          "HSTS should NOT be set in test environment (allows HTTP development)"))

    ;; #3: X-Content-Type-Options
    (testing "sets correct X-Content-Type-Options value"
      (ok (string= (get-response-header response :x-content-type-options)
                   "nosniff")
          "Should prevent MIME-type sniffing"))

    ;; #4: X-Frame-Options
    (testing "sets correct X-Frame-Options value"
      (ok (string= (get-response-header response :x-frame-options)
                   "DENY")
          "Should deny all framing (clickjacking protection)"))

    ;; #5: Referrer-Policy
    (testing "sets correct Referrer-Policy value"
      (ok (string= (get-response-header response :referrer-policy)
                   "strict-origin-when-cross-origin")
          "Should limit referrer information"))

    ;; #6: Permissions-Policy
    (testing "sets correct Permissions-Policy value"
      (ok (string= (get-response-header response :permissions-policy)
                   "geolocation=(), microphone=(), camera=(), accelerometer=(), gyroscope=(), magnetometer=(), payment=(), usb=()")
          "Should disable sensitive browser features"))))

;;; ============================================================
;;; test-security-headers-preservation (Section 3.4: 2 test cases)
;;; ============================================================

(deftest test-security-headers-preservation
  ;; #1: Non-security headers preserved
  (testing "preserves non-security headers"
    (let* ((app (make-dummy-app '(200 (:content-type "application/json" :x-custom "custom-value" :x-request-id "12345") ("{}"))))
           (middleware (security-headers-middleware app))
           (env '(:request-method :get))
           (response (funcall middleware env)))
      (ok (string= (get-response-header response :content-type) "application/json")
          "Should preserve Content-Type")
      (ok (string= (get-response-header response :x-custom) "custom-value")
          "Should preserve X-Custom header")
      (ok (string= (get-response-header response :x-request-id) "12345")
          "Should preserve X-Request-Id header")))

  ;; #2: Security headers present with correct values (test environment)
  (testing "adds base security headers with correct values alongside original headers"
    (let* ((app (make-dummy-app '(200 (:content-type "text/html") ("<html></html>"))))
           (middleware (security-headers-middleware app))
           (env '(:request-method :get))
           (response (funcall middleware env)))
      ;; Verify original header is preserved
      (ok (string= (get-response-header response :content-type) "text/html")
          "Should preserve original Content-Type")
      ;; Verify base security headers are present with correct values
      (ok (string= (get-response-header response :content-security-policy)
                   "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; report-uri /api/csp-report")
          "Should have correct CSP")
      ;; HSTS should NOT be present in test environment
      (ok (null (get-response-header response :strict-transport-security))
          "HSTS should NOT be set in test environment")
      (ok (string= (get-response-header response :x-content-type-options)
                   "nosniff")
          "Should have correct X-Content-Type-Options")
      (ok (string= (get-response-header response :x-frame-options)
                   "DENY")
          "Should have correct X-Frame-Options")
      (ok (string= (get-response-header response :referrer-policy)
                   "strict-origin-when-cross-origin")
          "Should have correct Referrer-Policy")
      (ok (string= (get-response-header response :permissions-policy)
                   "geolocation=(), microphone=(), camera=(), accelerometer=(), gyroscope=(), magnetometer=(), payment=(), usb=()")
          "Should have correct Permissions-Policy"))))

;;; ============================================================
;;; test-security-headers-string-key-filtering (Section 3.5: 2 test cases)
;;; ============================================================
;;; Tests for header key normalization (string/keyword handling)

(deftest test-security-headers-string-key-filtering
  ;; #1: String key security headers should be filtered
  ;; Note: This test uses plist with string keys which is unusual for Clack
  ;; but tests defensive programming for edge cases
  (testing "filters security headers with string keys"
    (let* ((app (make-dummy-app '(200 ("content-security-policy" "unsafe-value"
                                       :content-type "text/plain") ("OK"))))
           (middleware (security-headers-middleware app))
           (env '(:request-method :get))
           (response (funcall middleware env)))
      (ok (= (first response) 200)
          "Should return 200 status")
      ;; Middleware CSP should override string-keyed upstream CSP
      (ok (string= (get-response-header response :content-security-policy)
                   "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; report-uri /api/csp-report")
          "Should override string-keyed CSP with middleware CSP")
      (ok (not (search "unsafe-value" (or (get-response-header response :content-security-policy) "")))
          "Upstream string-keyed unsafe CSP should not be present")))

  ;; #2: Mixed string/keyword headers should both be normalized
  ;; Note: In test environment, HSTS is not set regardless of upstream value
  (testing "handles mixed string and keyword security headers"
    (let* ((app (make-dummy-app '(200 ("x-frame-options" "SAMEORIGIN"
                                       :strict-transport-security "max-age=0"
                                       :content-type "text/html") ("<html></html>"))))
           (middleware (security-headers-middleware app))
           (env '(:request-method :get))
           (response (funcall middleware env)))
      (ok (= (first response) 200)
          "Should return 200 status")
      ;; String-keyed X-Frame-Options should be overridden
      (ok (string= (get-response-header response :x-frame-options) "DENY")
          "Should override string-keyed X-Frame-Options")
      ;; HSTS should be filtered out AND not added back (test environment)
      (ok (null (get-response-header response :strict-transport-security))
          "HSTS should NOT be set in test environment (upstream filtered, not re-added)")
      (ok (string= (get-response-header response :content-type) "text/html")
          "Should preserve non-security headers"))))

;;; ============================================================
;;; test-security-headers-fallback-500 (Section 3.6: 2 test cases)
;;; ============================================================
;;; Tests for security headers on fallback 500 responses

(deftest test-security-headers-fallback-500
  ;; #1: Fallback 500 should have base security headers
  (testing "fallback 500 includes base security headers"
    (let* ((app (make-dummy-app nil))
           (middleware (security-headers-middleware app))
           (env '(:request-method :get))
           (response (funcall middleware env)))
      (ok (= (first response) 500)
          "Should return 500 status")
      (ok (has-base-security-headers-p response)
          "Fallback 500 should have base security headers")
      (ok (string= (get-response-header response :content-security-policy)
                   "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; report-uri /api/csp-report")
          "Fallback 500 should have correct CSP value")))

  ;; #2: Fallback 500 for malformed response should have security headers
  (testing "fallback 500 for malformed response includes security headers"
    (let* ((app (make-dummy-app '(200)))  ; malformed: only 1 element
           (middleware (security-headers-middleware app))
           (env '(:request-method :get))
           (response (funcall middleware env)))
      (ok (= (first response) 500)
          "Should return 500 status for malformed response")
      (ok (has-base-security-headers-p response)
          "Fallback 500 for malformed response should have security headers")
      (ok (string= (get-response-header response :x-frame-options) "DENY")
          "Fallback 500 should have X-Frame-Options: DENY"))))

;;; ============================================================
;;; test-security-headers-environment (Section 3.7: Environment tests)
;;; ============================================================
;;; Tests for environment-specific header configuration

(deftest test-security-headers-environment
  ;; #1: Test environment detection
  (testing "detects non-production environment correctly"
    (ok (not (production-environment-p))
        "Test environment should NOT be detected as production"))

  ;; #2: Build security headers excludes HSTS in test environment
  (testing "build-security-headers excludes HSTS in test environment"
    (let ((headers (build-security-headers)))
      (ok (getf headers :content-security-policy)
          "Should have CSP in built headers")
      (ok (getf headers :x-frame-options)
          "Should have X-Frame-Options in built headers")
      (ok (getf headers :permissions-policy)
          "Should have Permissions-Policy in built headers")
      (ok (null (getf headers :strict-transport-security))
          "Should NOT have HSTS in test environment")))

  ;; #3: Verify base headers are complete
  (testing "base security headers include all non-HSTS headers"
    (let ((headers (build-security-headers)))
      (ok (= 5 (/ (length headers) 2))
          "Should have exactly 5 base security headers (10 plist elements)"))))
