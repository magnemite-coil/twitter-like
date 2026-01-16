(defpackage twitter-like-test.cors
  (:use :cl :rove)
  (:import-from :twitter-like.middleware.cors
                :cors-middleware)
  (:import-from :twitter-like.config
                :load-config
                :get-config
                :*config*))
;; Note: cl-dotenv is included in twitter-like dependencies, no need to add
;; Following test-request.lisp pattern, using package prefix (cl-dotenv:...) directly

(in-package :twitter-like-test.cors)

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
;;; This test follows test-request.lisp pattern (see L19-28 comments).

;;; ============================================================
;;; Helper Functions
;;; ============================================================

(defun call-with-cors-config (origins-value thunk)
  "Temporarily set CORS config and execute thunk, restore on completion
   origins-value: string, NIL, or non-string (for error testing)"
  (let ((original (gethash "cors-allowed-origins" *config*)))
    (unwind-protect
        (progn
          (setf (gethash "cors-allowed-origins" *config*) origins-value)
          (funcall thunk))
      (setf (gethash "cors-allowed-origins" *config*) original))))

(defun make-test-env (&key (method :get) origin (headers nil))
  "Generate test Clack env
   method: :get, :post, :options etc.
   origin: Origin header value (not set if NIL)
   headers: additional headers as alist ((\"key\" . \"value\") ...)"
  (let ((header-table (make-hash-table :test #'equal)))
    (when origin
      (setf (gethash "origin" header-table) origin))
    (loop for (k . v) in headers
          do (setf (gethash k header-table) v))
    (list :request-method method
          :headers header-table)))

(defun make-dummy-app (&optional (response '(200 (:content-type "text/plain") ("OK"))))
  "Generate dummy app for testing
   response: Clack response format (status headers body)"
  (lambda (env)
    (declare (ignore env))
    response))

(defun get-response-header (response header-key)
  "Get header value from response
   response: (status headers body)
   header-key: keyword (e.g., :access-control-allow-origin)"
  (getf (second response) header-key))

;;; ============================================================
;;; setup/teardown
;;; ============================================================

(setup
  ;; Load .env.test if present
  (when (probe-file ".env.test")
    (cl-dotenv:load-env ".env.test"))
  ;; Initialize config
  (load-config))

(teardown
  ;; Each test uses unwind-protect to restore *config*,
  ;; so no additional cleanup is needed
  nil)

;;; ============================================================
;;; test-origin-allowed-p (Section 3.2: 13 test cases)
;;; ============================================================

(deftest test-origin-allowed-p
  ;; Access unexported function with :: prefix
  (let ((origin-allowed-p #'twitter-like.middleware.cors::origin-allowed-p))

    ;; #1: Origin in allowed list
    (testing "returns truthy when origin is in allowed list"
      (ok (funcall origin-allowed-p "http://localhost:3000" '("http://localhost:3000"))
          "Should return truthy (cons cell from member)"))

    ;; #2: Origin not in allowed list
    (testing "returns NIL when origin is not in allowed list"
      (ok (null (funcall origin-allowed-p "http://evil.com" '("http://localhost:3000")))
          "Should return NIL for disallowed origin"))

    ;; #3: Match in multiple origins
    (testing "returns truthy when origin matches one of multiple allowed origins"
      (ok (funcall origin-allowed-p "https://b.com" '("https://a.com" "https://b.com"))
          "Should return truthy for matching origin in list"))

    ;; #4: Origin is NIL
    (testing "returns NIL when origin is NIL"
      (ok (null (funcall origin-allowed-p nil '("http://localhost:3000")))
          "Should return NIL when origin is NIL"))

    ;; #5: Allowed-origins is NIL
    (testing "returns NIL when allowed-origins is NIL"
      (ok (null (funcall origin-allowed-p "http://localhost:3000" nil))
          "Should return NIL when allowed-origins is NIL"))

    ;; #6: Both NIL
    (testing "returns NIL when both origin and allowed-origins are NIL"
      (ok (null (funcall origin-allowed-p nil nil))
          "Should return NIL when both are NIL"))

    ;; #7: Case sensitivity
    (testing "is case sensitive"
      (ok (null (funcall origin-allowed-p "HTTP://LOCALHOST:3000" '("http://localhost:3000")))
          "Should return NIL for case mismatch (origins are case-sensitive)"))

    ;; #8: Wildcard * handling (security test)
    (testing "does not treat wildcard * as special (exact match only)"
      (ok (null (funcall origin-allowed-p "http://any.com" '("*")))
          "Should return NIL - wildcard is treated as literal string, not pattern"))

    ;; #9: Null string origin (security test)
    (testing "rejects 'null' string origin"
      (ok (null (funcall origin-allowed-p "null" '("http://localhost:3000")))
          "Should return NIL for 'null' string origin (security vector)"))

    ;; #10: Subdomain spoofing (OWASP regression test)
    (testing "prevents subdomain spoofing attack"
      (ok (null (funcall origin-allowed-p "http://localhost:3000.attacker.com" '("http://localhost:3000")))
          "Should return NIL - exact match prevents subdomain spoofing"))

    ;; #11: Protocol mismatch (security test)
    (testing "distinguishes between http and https"
      (ok (null (funcall origin-allowed-p "https://localhost:3000" '("http://localhost:3000")))
          "Should return NIL for protocol mismatch"))

    ;; #12: Port mismatch (security test)
    (testing "distinguishes between different ports"
      (ok (null (funcall origin-allowed-p "http://localhost:8080" '("http://localhost:3000")))
          "Should return NIL for port mismatch"))

    ;; #13: Origin reflection attack (regression test)
    (testing "prevents origin reflection attack"
      (ok (null (funcall origin-allowed-p "http://attacker.com" '("http://trusted.com")))
          "Should return NIL - prevents blind reflection of untrusted origins"))))

;;; ============================================================
;;; test-get-origin-header (Section 3.3: 4 test cases)
;;; ============================================================

(deftest test-get-origin-header
  ;; Access unexported function with :: prefix
  (let ((get-origin-header #'twitter-like.middleware.cors::get-origin-header))

    ;; #1: Origin present
    (testing "returns origin when present in headers"
      (let ((env (make-test-env :origin "http://localhost:3000")))
        (ok (string= (funcall get-origin-header env) "http://localhost:3000")
            "Should return the origin header value")))

    ;; #2: Origin absent
    (testing "returns NIL when origin is absent"
      (let ((env (make-test-env :headers '(("content-type" . "application/json")))))
        (ok (null (funcall get-origin-header env))
            "Should return NIL when origin header is missing")))

    ;; #3: No headers key
    (testing "returns NIL when no headers in env"
      (let ((env '()))
        (ok (null (funcall get-origin-header env))
            "Should return NIL for empty env")))

    ;; #4: Headers is NIL
    (testing "returns NIL when headers is NIL"
      (let ((env '(:headers nil)))
        (ok (null (funcall get-origin-header env))
            "Should return NIL when headers is NIL")))))

;;; ============================================================
;;; test-parse-allowed-origins (Section 3.1: 6 test cases)
;;; ============================================================

(deftest test-parse-allowed-origins
  ;; Access unexported function with :: prefix
  (let ((parse-allowed-origins #'twitter-like.middleware.cors::parse-allowed-origins))

    ;; #1: Single origin
    (testing "parses single origin"
      (call-with-cors-config "http://localhost:3000"
        (lambda ()
          (let ((result (funcall parse-allowed-origins)))
            (ok (and (listp result)
                     (= (length result) 1)
                     (string= (first result) "http://localhost:3000"))
                "Should parse single origin into list")))))

    ;; #2: Multiple origins
    (testing "parses multiple comma-separated origins"
      (call-with-cors-config "http://localhost:3000,https://example.com"
        (lambda ()
          (let ((result (funcall parse-allowed-origins)))
            (ok (and (listp result)
                     (= (length result) 2)
                     (string= (first result) "http://localhost:3000")
                     (string= (second result) "https://example.com"))
                "Should parse comma-separated origins into list")))))

    ;; #3: With whitespace
    (testing "trims whitespace from origins"
      (call-with-cors-config " http://a.com , https://b.com "
        (lambda ()
          (let ((result (funcall parse-allowed-origins)))
            (ok (and (listp result)
                     (= (length result) 2)
                     (string= (first result) "http://a.com")
                     (string= (second result) "https://b.com"))
                "Should trim whitespace from each origin")))))

    ;; #4: Empty string
    (testing "returns NIL for empty string"
      (call-with-cors-config ""
        (lambda ()
          (ok (null (funcall parse-allowed-origins))
              "Should return NIL for empty string"))))

    ;; #5: Not set (NIL)
    (testing "returns NIL when not set"
      (call-with-cors-config nil
        (lambda ()
          (ok (null (funcall parse-allowed-origins))
              "Should return NIL when config is NIL"))))

    ;; #6: Non-string (number) - tests error handling
    ;; Note: This outputs a warning to stdout (expected behavior)
    (testing "returns NIL for non-string input (TYPE-ERROR handling)"
      (call-with-cors-config 12345
        (lambda ()
          (ok (null (funcall parse-allowed-origins))
              "Should catch TYPE-ERROR and return NIL"))))))

;;; ============================================================
;;; test-cors-middleware-preflight (Section 3.4.1: 3 test cases)
;;; ============================================================

(deftest test-cors-middleware-preflight
  ;; #1: OPTIONS from allowed origin
  (testing "returns 200 with CORS headers for allowed origin preflight"
    (call-with-cors-config "http://localhost:3000"
      (lambda ()
        (let* ((app (make-dummy-app))
               (middleware (cors-middleware app))
               (env (make-test-env :method :options :origin "http://localhost:3000"))
               (response (funcall middleware env)))
          (ok (= (first response) 200)
              "Should return 200 status")
          (ok (string= (get-response-header response :access-control-allow-origin)
                       "http://localhost:3000")
              "Should set Access-Control-Allow-Origin to request origin")
          (ok (string= (get-response-header response :access-control-allow-methods)
                       "GET, POST, PUT, DELETE, OPTIONS")
              "Should set Access-Control-Allow-Methods")
          (ok (string= (get-response-header response :access-control-allow-headers)
                       "Content-Type, Authorization")
              "Should set Access-Control-Allow-Headers")
          (ok (string= (get-response-header response :access-control-allow-credentials)
                       "true")
              "Should set Access-Control-Allow-Credentials to true")
          (ok (string= (get-response-header response :access-control-max-age)
                       "86400")
              "Should set Access-Control-Max-Age to 86400")
          (ok (string= (get-response-header response :vary)
                       "Origin")
              "Should set Vary: Origin for cache poisoning prevention")))))

  ;; #2: OPTIONS from disallowed origin
  (testing "returns 403 without CORS headers for disallowed origin preflight"
    (call-with-cors-config "http://localhost:3000"
      (lambda ()
        (let* ((app (make-dummy-app))
               (middleware (cors-middleware app))
               (env (make-test-env :method :options :origin "http://evil.com"))
               (response (funcall middleware env)))
          (ok (= (first response) 403)
              "Should return 403 status")
          (ok (equal (third response) '("Forbidden"))
              "Should return Forbidden body")
          (ok (null (get-response-header response :access-control-allow-origin))
              "Should NOT set Access-Control-Allow-Origin")
          (ok (string= (get-response-header response :vary)
                       "Origin")
              "Should set Vary: Origin even for 403 (cache poisoning prevention)")))))

  ;; #3: OPTIONS without Origin header
  (testing "returns 403 for preflight without Origin header"
    (call-with-cors-config "http://localhost:3000"
      (lambda ()
        (let* ((app (make-dummy-app))
               (middleware (cors-middleware app))
               (env (make-test-env :method :options))  ; no origin
               (response (funcall middleware env)))
          (ok (= (first response) 403)
              "Should return 403 status")
          (ok (null (get-response-header response :access-control-allow-origin))
              "Should NOT set Access-Control-Allow-Origin")
          (ok (string= (get-response-header response :vary)
                       "Origin")
              "Should set Vary: Origin even for 403 without Origin header"))))))

;;; ============================================================
;;; test-cors-middleware-normal (Section 3.4.2: 7 test cases)
;;; ============================================================

(deftest test-cors-middleware-normal
  ;; #1: Allowed origin + normal response
  (testing "adds CORS headers for allowed origin"
    (call-with-cors-config "http://localhost:3000"
      (lambda ()
        (let* ((app (make-dummy-app '(200 (:content-type "text/plain") ("OK"))))
               (middleware (cors-middleware app))
               (env (make-test-env :method :get :origin "http://localhost:3000"))
               (response (funcall middleware env)))
          (ok (= (first response) 200)
              "Should return 200 status")
          (ok (string= (get-response-header response :access-control-allow-origin)
                       "http://localhost:3000")
              "Should set Access-Control-Allow-Origin")
          (ok (string= (get-response-header response :access-control-allow-credentials)
                       "true")
              "Should set Access-Control-Allow-Credentials")
          (ok (string= (get-response-header response :content-type)
                       "text/plain")
              "Should preserve original Content-Type header")
          (ok (string= (get-response-header response :vary)
                       "Origin")
              "Should set Vary: Origin for cache poisoning prevention")))))

  ;; #2: Disallowed origin + normal response
  (testing "does not add CORS headers for disallowed origin"
    (call-with-cors-config "http://localhost:3000"
      (lambda ()
        (let* ((app (make-dummy-app '(200 (:content-type "text/plain") ("OK"))))
               (middleware (cors-middleware app))
               (env (make-test-env :method :get :origin "http://evil.com"))
               (response (funcall middleware env)))
          (ok (= (first response) 200)
              "Should return 200 status (app response passed through)")
          (ok (null (get-response-header response :access-control-allow-origin))
              "Should NOT set Access-Control-Allow-Origin for disallowed origin")))))

  ;; #3: No Origin + normal response
  (testing "does not add CORS headers when no Origin header"
    (call-with-cors-config "http://localhost:3000"
      (lambda ()
        (let* ((app (make-dummy-app '(200 (:content-type "text/plain") ("OK"))))
               (middleware (cors-middleware app))
               (env (make-test-env :method :get))  ; no origin
               (response (funcall middleware env)))
          (ok (= (first response) 200)
              "Should return 200 status")
          (ok (null (get-response-header response :access-control-allow-origin))
              "Should NOT set Access-Control-Allow-Origin when no Origin")))))

  ;; #4: Allowed origin + app returns NIL (defensive test)
  (testing "passes through NIL response from app"
    (call-with-cors-config "http://localhost:3000"
      (lambda ()
        (let* ((app (make-dummy-app nil))
               (middleware (cors-middleware app))
               (env (make-test-env :method :get :origin "http://localhost:3000"))
               (response (funcall middleware env)))
          (ok (null response)
              "Should pass through NIL response without modification")))))

  ;; #5: Allowed origin + short list (defensive test)
  (testing "passes through incomplete response format"
    (call-with-cors-config "http://localhost:3000"
      (lambda ()
        (let* ((app (make-dummy-app '(200 ())))  ; only 2 elements
               (middleware (cors-middleware app))
               (env (make-test-env :method :get :origin "http://localhost:3000"))
               (response (funcall middleware env)))
          (ok (equal response '(200 ()))
              "Should pass through 2-element response without modification")))))

  ;; #6: Empty allowed list (defensive test)
  (testing "does not add CORS headers when allowed list is empty"
    (call-with-cors-config nil
      (lambda ()
        (let* ((app (make-dummy-app '(200 (:content-type "text/plain") ("OK"))))
               (middleware (cors-middleware app))
               (env (make-test-env :method :get :origin "http://localhost:3000"))
               (response (funcall middleware env)))
          (ok (= (first response) 200)
              "Should return 200 status")
          (ok (null (get-response-header response :access-control-allow-origin))
              "Should NOT set CORS headers when allowed list is NIL")))))

  ;; #7: Credentials + wildcard prohibition (OWASP security test)
  (testing "does not allow credentials with wildcard origin"
    (call-with-cors-config "*"
      (lambda ()
        (let* ((app (make-dummy-app '(200 (:content-type "text/plain") ("OK"))))
               (middleware (cors-middleware app))
               (env (make-test-env :method :get :origin "http://any.com"))
               (response (funcall middleware env)))
          ;; * is treated as literal string, so "http://any.com" won't match
          ;; This ensures credentials are never sent with wildcard
          (ok (null (get-response-header response :access-control-allow-origin))
              "Should NOT set CORS headers - wildcard is literal, not pattern")
          (ok (null (get-response-header response :access-control-allow-credentials))
              "Should NOT set credentials header - prevents credentials+wildcard combination"))))))
