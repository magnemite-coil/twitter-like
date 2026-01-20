(defpackage twitter-like.handler.csp-report
  (:use :cl)
  (:import-from :twitter-like.util.logger
                :log-warn)
  (:export :register-csp-report-routes
           ;; Exported for unit testing
           :+max-csp-report-size+
           :read-body-safely
           :extract-csp-report-fields
           :process-csp-report))

(in-package :twitter-like.handler.csp-report)

;;; ============================================================
;;; CSP Violation Report Handler
;;; ============================================================
;;;
;;; This handler receives Content-Security-Policy violation reports
;;; from browsers and logs them for security monitoring.
;;;
;;; CSP Report Format (JSON):
;;; {
;;;   "csp-report": {
;;;     "document-uri": "https://example.com/page",
;;;     "referrer": "",
;;;     "violated-directive": "script-src 'self'",
;;;     "effective-directive": "script-src",
;;;     "original-policy": "default-src 'none'; script-src 'self'",
;;;     "blocked-uri": "https://evil.com/script.js",
;;;     "status-code": 200
;;;   }
;;; }
;;;
;;; Reference: https://developer.mozilla.org/en-US/docs/Web/HTTP/CSP#violation_report_syntax

(defconstant +max-csp-report-size+ (* 64 1024)
  "Maximum CSP report size: 64KB (防止DoS)")

(defun get-env ()
  "ningleのコンテキストからリクエスト環境を取得"
  (lack.request:request-env (ningle:context :request)))

(defun read-body-safely (env max-size)
  "ストリームからボディを安全に読み取る"
  (let* ((content-length-raw (getf env :content-length))
         (content-length (if (stringp content-length-raw)
                             (parse-integer content-length-raw :junk-allowed t)
                             content-length-raw))
         (body-stream (getf env :raw-body)))
    ;; サイズチェック
    (when (and content-length (> content-length max-size))
      (return-from read-body-safely nil))
    ;; ボディ読み取り
    (when (and content-length body-stream (> content-length 0))
      (let ((body-bytes (make-array content-length :element-type '(unsigned-byte 8))))
        (read-sequence body-bytes body-stream)
        (babel:octets-to-string body-bytes :encoding :utf-8)))))

(defun extract-csp-report-fields (report)
  "Extract relevant fields from CSP report for logging.
   Returns a plist with normalized field names."
  (when (hash-table-p report)
    (let ((csp-report (gethash "csp-report" report)))
      (when (hash-table-p csp-report)
        (list
         :|document-uri| (gethash "document-uri" csp-report)
         :|violated-directive| (gethash "violated-directive" csp-report)
         :|effective-directive| (gethash "effective-directive" csp-report)
         :|blocked-uri| (gethash "blocked-uri" csp-report)
         :|referrer| (gethash "referrer" csp-report)
         :|status-code| (gethash "status-code" csp-report))))))

(defun process-csp-report (env)
  "Process CSP violation report from request environment.
   This is the core logic extracted for testability.

   Args:
     env: Clack request environment plist

   Returns:
     A plist with keys:
       :status - HTTP status code (always 204)
       :processed - T if report was processed, NIL otherwise
       :logged - T if violation was logged, NIL otherwise
       :error - Error message if an error occurred, NIL otherwise"
  (handler-case
      (let ((content-type (getf env :content-type)))
        ;; Validate Content-Type
        (unless (and content-type
                     (or (search "application/csp-report" content-type)
                         (search "application/json" content-type)))
          ;; Invalid Content-Type, silently accept but don't process
          (return-from process-csp-report
            (list :status 204 :processed nil :logged nil :error nil)))

        ;; Parse and log the report
        (let ((body-string (read-body-safely env +max-csp-report-size+)))
          (if body-string
              (let* ((report (handler-case
                                 (com.inuoe.jzon:parse body-string)
                               (error () nil)))
                     (fields (extract-csp-report-fields report)))
                (if fields
                    (progn
                      ;; Log as warning (security event)
                      (log-warn "CSP violation detected" :context fields)
                      (list :status 204 :processed t :logged t :error nil))
                    ;; JSON parsed but no valid csp-report fields
                    (list :status 204 :processed t :logged nil :error nil)))
              ;; No body or body read failed
              (list :status 204 :processed nil :logged nil :error nil))))
    (error (e)
      ;; Log error but still return 204 to avoid information leakage
      (let ((error-msg (princ-to-string e)))
        (log-warn "CSP report processing error" :context (list :error error-msg))
        (list :status 204 :processed nil :logged nil :error error-msg)))))

(defun csp-report-handler (params)
  "Handle CSP violation reports from browsers.

   Accepts POST requests with Content-Type: application/csp-report
   Logs the violation for security monitoring and returns 204 No Content.

   Note: This endpoint intentionally returns minimal response to avoid
   being used for information gathering by attackers."
  (declare (ignore params))
  (process-csp-report (get-env))
  ;; Always return 204 No Content
  (list 204 '(:content-type "text/plain") '("")))

(defun register-csp-report-routes (app)
  "Register CSP report route to the application.

   POST /api/csp-report - Receive CSP violation reports"
  (setf (ningle:route app "/api/csp-report" :method :post) #'csp-report-handler)
  app)
