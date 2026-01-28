(defpackage twitter-like-test.util
  (:use :cl)
  (:export :make-dummy-app
           :get-response-header
           :with-env-var))

(in-package :twitter-like-test.util)

;;; ============================================================
;;; Middleware Unit Test Helpers
;;; ============================================================
;;; These functions are shared across middleware unit tests
;;; (test-cors.lisp, test-security.lisp, etc.)
;;;
;;; For integration test helpers (HTTP requests, server setup),
;;; see test/setup.lisp instead.

(defun make-dummy-app (&optional (response '(200 (:content-type "text/plain") ("OK"))))
  "Generate dummy app for testing
   response: Clack response format (status headers body)"
  (lambda (env)
    (declare (ignore env))
    response))

(defun get-response-header (response header-key)
  "Get header value from response
   response: (status headers body)
   header-key: keyword (e.g., :content-security-policy)"
  (getf (second response) header-key))

;;; ============================================================
;;; Environment Variable Test Helpers
;;; ============================================================
;;; Shared helper for temporarily modifying environment variables
;;; in tests. Used by test-config.lisp, test-request.lisp, etc.

(defun with-env-var (name value thunk)
  "Execute THUNK with environment variable NAME temporarily set to VALUE.
   If VALUE is NIL, the environment variable is unset.
   The original value is always restored after THUNK completes.

   Example:
     (with-env-var \"TEST_VAR\" \"test-value\"
       (lambda ()
         (do-something-with-env-var)))"
  (let ((original (uiop:getenv name)))
    (unwind-protect
        (progn
          (if value
              (sb-posix:setenv name value 1)
              (sb-posix:unsetenv name))
          (funcall thunk))
      ;; Always restore the original value
      (if original
          (sb-posix:setenv name original 1)
          (sb-posix:unsetenv name)))))
