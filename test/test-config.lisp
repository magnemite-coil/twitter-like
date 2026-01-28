(defpackage twitter-like-test.config
  (:use :cl :rove)
  (:import-from :twitter-like.config
                :load-config
                :get-config
                :*config*)
  (:import-from :twitter-like-test.util
                :with-env-var))

(in-package :twitter-like-test.config)

;;; ============================================================
;;; Environment Guard Notes
;;; ============================================================

;;; This test file only manipulates environment variables and hash tables,
;;; so the following guards are unnecessary:
;;; - APP_ENV check (no Redis/DB connections used)
;;; - Redis host/port whitelist (no Redis connections used)
;;; - PostgreSQL connection check (no DB connections used)
;;;
;;; However, since environment variables and *config* are temporarily modified,
;;; each test uses unwind-protect to ensure proper restoration.
;;;
;;; Reference: test-session.lisp (L205-221), test-cors.lisp (L36-44)
;;; for *config* temporary replacement pattern.
;;; Reference: test-request.lisp (L38-51) for with-env-var pattern.

;;; ============================================================
;;; Helper Functions
;;; ============================================================

;;; NOTE: with-env-var is now shared via twitter-like-test.util.
;;; See test/util.lisp for the implementation.

;;; ============================================================
;;; setup/teardown
;;; ============================================================

;;; NOTE: Roveの setup/teardown はパッケージ単位で1回のみ実行される。
;;; 各テスト前の初期化が必要な場合は defhook :before を使用する。
;;; 本テストファイルでは、パッケージ読み込み時に1回 load-config を呼び、
;;; 各テストは unwind-protect で状態を復元するため、setup での1回実行で十分。
;;; Reference: test-cors.lisp (L65-75)

(setup
  ;; Load .env.test if present (consistent with test-session.lisp, test-cors.lisp)
  ;; NOTE: load-config also loads .env.test when APP_ENV=test, but explicit loading
  ;; here ensures environment variables are available before load-config runs.
  ;; This is the established pattern across test files in this project.
  (when (probe-file ".env.test")
    (cl-dotenv:load-env ".env.test"))
  ;; Initialize config
  (load-config))

(teardown
  ;; Each test uses unwind-protect to restore *config*,
  ;; so no additional cleanup is needed
  nil)

;;; ============================================================
;;; Existing Tests
;;; ============================================================

;;; Note: setup already loads .env.test and calls load-config once per package.
;;; Individual tests do not need to call cl-dotenv:load-env again.
;;; Reference: test-session.lisp (L30-34), test-cors.lisp (L65-70)
;;;
;;; IMPORTANT: テスト実行時は APP_ENV=test が設定されていることが前提。
;;; Makefile の test ターゲットで APP_ENV=test を設定している。
;;; 外部環境で直接テストを実行する場合は、事前に以下を確認:
;;;   export APP_ENV=test
;;; または Rove の run オプションで環境変数を指定する。

(deftest test-load-config
  (testing "Configuration loading"
    ;; load-config internally loads .env.test when APP_ENV=test
    (twitter-like.config:load-config)

    ;; Verify basic settings
    (ok (string= (twitter-like.config:get-config "app-env") "test")
        "APP_ENV should be 'test'")
    (ok (= (twitter-like.config:get-config "app-port") 8081)
        "APP_PORT should be 8081")
    (ok (string= (twitter-like.config:get-config "db-name") "twitter_like_test")
        "DB_NAME should be 'twitter_like_test'")))

(deftest test-validate-config
  (testing "Configuration validation"
    ;; load-config internally loads .env.test when APP_ENV=test
    (twitter-like.config:load-config)

    ;; Verify configuration validation succeeds
    (ok (twitter-like.config::validate-config)
        "Configuration should be valid")))

;;; ============================================================
;;; required-env-var Tests (New)
;;; ============================================================

(deftest test-required-env-var
  ;; Normal case
  ;; with-env-var パターンで元値を保存・復元
  (testing "returns value when environment variable is set"
    (with-env-var "TEST_REQUIRED_VAR" "test-value"
      (lambda ()
        (ok (string= (twitter-like.config::required-env-var "TEST_REQUIRED_VAR")
                     "test-value")
            "Should return the environment variable value"))))

  ;; Error case: environment variable not set
  ;; Note: Following test-auth-validation.lisp pattern (L47-48),
  ;; verify error message contains the variable name for debugging
  (testing "signals error with variable name when not set"
    (with-env-var "NONEXISTENT_VAR_12345" nil
      (lambda ()
        (handler-case
            (progn
              (twitter-like.config::required-env-var "NONEXISTENT_VAR_12345")
              (fail "Should have signaled an error"))
          (error (e)
            (ok (search "NONEXISTENT_VAR_12345" (princ-to-string e))
                "Error message should contain the variable name"))))))

  ;; Error case: empty string
  (testing "signals error with variable name when empty string"
    (with-env-var "TEST_EMPTY_VAR" ""
      (lambda ()
        (handler-case
            (progn
              (twitter-like.config::required-env-var "TEST_EMPTY_VAR")
              (fail "Should have signaled an error"))
          (error (e)
            (ok (search "TEST_EMPTY_VAR" (princ-to-string e))
                "Error message should contain the variable name")))))))

;;; ============================================================
;;; validate-secret-key Tests (New)
;;; ============================================================

(deftest test-validate-secret-key
  ;; Normal case: valid 128-char hex key (longer than min-length)
  (testing "returns T for valid hex key longer than min-length"
    (unwind-protect
        (progn
          ;; 128 chars = 512 bits, well above 64-char minimum
          ;; make-string で長さを明示（'a' は有効な16進文字）
          (setf (gethash "test-valid-secret" *config*)
                (make-string 128 :initial-element #\a))
          (ok (twitter-like.config::validate-secret-key "test-valid-secret" 64)
              "Should return T for valid 128-char hex key"))
      ;; cleanup: remove test key
      (remhash "test-valid-secret" *config*)))

  ;; Normal case: uppercase hex characters (digit-char-p accepts A-F)
  (testing "returns T for valid uppercase hex key"
    (unwind-protect
        (progn
          ;; make-string で長さを明示（'A' は有効な16進文字）
          (setf (gethash "test-uppercase-secret" *config*)
                (make-string 64 :initial-element #\A))
          (ok (twitter-like.config::validate-secret-key "test-uppercase-secret" 64)
              "Should return T for valid uppercase hex key"))
      ;; cleanup
      (remhash "test-uppercase-secret" *config*)))

  ;; Normal case: numeric hex characters (digit-char-p accepts 0-9)
  (testing "returns T for valid numeric hex key"
    (unwind-protect
        (progn
          ;; make-string で長さを明示（'5' は有効な16進文字）
          (setf (gethash "test-numeric-secret" *config*)
                (make-string 64 :initial-element #\5))
          (ok (twitter-like.config::validate-secret-key "test-numeric-secret" 64)
              "Should return T for numeric hex key"))
      ;; cleanup
      (remhash "test-numeric-secret" *config*)))

  ;; Normal case: mixed hex characters (realistic pattern)
  ;; Optional test per design doc section 5.6 (3)
  (testing "returns T for mixed hex character key"
    (unwind-protect
        (progn
          ;; "0123456789abcdef" repeated 4 times = 64 chars
          ;; More realistic test data than single-character strings
          (setf (gethash "test-mixed-secret" *config*)
                (concatenate 'string
                             "0123456789abcdef"
                             "0123456789abcdef"
                             "0123456789abcdef"
                             "0123456789abcdef"))
          (ok (twitter-like.config::validate-secret-key "test-mixed-secret" 64)
              "Should return T for mixed hex character key"))
      ;; cleanup
      (remhash "test-mixed-secret" *config*)))

  ;; Error case: key is missing (nil)
  (testing "signals error when key is missing (nil)"
    ;; "test-missing-key" does not exist in *config*
    ;; Use remhash to ensure it's definitely not present
    (remhash "test-missing-key" *config*)
    (ok (signals (twitter-like.config::validate-secret-key "test-missing-key" 64))
        "Should signal error for missing key"))

  ;; Error message verification (optional per design doc section 5.6 (1))
  ;; Verify that error messages contain the key name for debugging
  (testing "error message contains key name for missing key"
    (remhash "test-missing-key-msg" *config*)
    (handler-case
        (progn
          (twitter-like.config::validate-secret-key "test-missing-key-msg" 64)
          (fail "Should have signaled an error"))
      (error (e)
        (ok (search "test-missing-key-msg" (princ-to-string e))
            "Error message should contain the key name"))))

  ;; Error case: empty string
  (testing "signals error when key is empty string"
    (unwind-protect
        (progn
          (setf (gethash "test-empty-secret" *config*) "")
          (ok (signals (twitter-like.config::validate-secret-key "test-empty-secret" 64))
              "Should signal error for empty key"))
      ;; cleanup
      (remhash "test-empty-secret" *config*)))

  ;; Error case: contains non-hex characters
  (testing "signals error when key contains non-hex characters"
    (unwind-protect
        (progn
          ;; 'g' is not a hex digit (only 0-9, a-f, A-F are valid)
          ;; make-string で長さを明示
          (setf (gethash "test-invalid-hex" *config*)
                (make-string 64 :initial-element #\g))
          (ok (signals (twitter-like.config::validate-secret-key "test-invalid-hex" 64))
              "Should signal error for non-hex characters"))
      ;; cleanup
      (remhash "test-invalid-hex" *config*)))

  ;; Error case: key too short (32 chars < 64 chars)
  (testing "signals error when key is too short"
    (unwind-protect
        (progn
          ;; make-string で長さを明示
          (setf (gethash "test-short-secret" *config*)
                (make-string 32 :initial-element #\a))
          (ok (signals (twitter-like.config::validate-secret-key "test-short-secret" 64))
              "Should signal error for key shorter than min-length"))
      ;; cleanup
      (remhash "test-short-secret" *config*)))

  ;; Boundary: exactly 1 char below min-length (63 chars)
  ;; Strict boundary test: min-length - 1
  (testing "signals error when key is exactly 1 char below min-length"
    (unwind-protect
        (progn
          ;; make-string で長さを明示（境界値テストで重要）
          (setf (gethash "test-boundary-short" *config*)
                (make-string 63 :initial-element #\a))
          (ok (signals (twitter-like.config::validate-secret-key "test-boundary-short" 64))
              "Should signal error for key with 63 chars (min-length - 1)"))
      ;; cleanup
      (remhash "test-boundary-short" *config*)))

  ;; Boundary: exactly at min-length (64 chars)
  (testing "returns T for key exactly at min-length"
    (unwind-protect
        (progn
          ;; make-string で長さを明示（境界値テストで重要）
          (setf (gethash "test-exact-length" *config*)
                (make-string 64 :initial-element #\a))
          (ok (twitter-like.config::validate-secret-key "test-exact-length" 64)
              "Should return T for key exactly at min-length"))
      ;; cleanup
      (remhash "test-exact-length" *config*))))

;;; ============================================================
;;; reload-config Tests (New)
;;; ============================================================

(deftest test-reload-config
  ;; reload-config only works in development environment (app-env = "development")
  ;; Verify it does nothing in test environment (APP_ENV=test)

  (testing "does nothing in test environment"
    ;; Check current settings
    (let ((original-env (gethash "app-env" *config*))
          (original-port (gethash "app-port" *config*)))
      ;; Verify app-env is "test" (precondition)
      (ok (string= original-env "test")
          "APP_ENV should be 'test'")
      ;; Call reload-config
      (twitter-like.config::reload-config)
      ;; Verify settings unchanged
      (ok (string= (gethash "app-env" *config*) original-env)
          "app-env should not change in test environment")
      (ok (= (gethash "app-port" *config*) original-port)
          "app-port should not change in test environment")))

  ;; Test behavior in development environment
  (testing "reloads config in development environment"
    (let ((original-app-env (gethash "app-env" *config*))
          (original-app-port (gethash "app-port" *config*)))
      (unwind-protect
          (progn
            ;; Temporarily set to development environment
            (setf (gethash "app-env" *config*) "development")
            ;; Change port to verify reload behavior
            (setf (gethash "app-port" *config*) 9999)
            ;; Call reload-config (reloads from .env.test)
            (twitter-like.config::reload-config)
            ;; Verify settings reloaded from .env.test
            ;; Note: load-config inside reload-config reads APP_ENV=test
            (ok (string= (gethash "app-env" *config*) "test")
                "app-env should be reloaded from .env.test")
            (ok (= (gethash "app-port" *config*) 8081)
                "app-port should be reloaded from .env.test (8081)"))
        ;; cleanup: restore original settings
        ;; Note: reload-config success means values are from .env.test,
        ;; but explicitly restore for safety
        (setf (gethash "app-env" *config*) original-app-env)
        (setf (gethash "app-port" *config*) original-app-port)))))
