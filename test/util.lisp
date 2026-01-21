(defpackage twitter-like-test.util
  (:use :cl)
  (:export :make-dummy-app
           :get-response-header))

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
