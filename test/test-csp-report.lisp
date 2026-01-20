(defpackage twitter-like-test.csp-report
  (:use :cl :rove)
  (:import-from :twitter-like.handler.csp-report
                :+max-csp-report-size+
                :read-body-safely
                :extract-csp-report-fields))

(in-package :twitter-like-test.csp-report)

;;; ============================================================
;;; Environment Guard Notes
;;; ============================================================

;;; This test file tests pure functions, so the following guards are unnecessary:
;;; - APP_ENV check (no Redis/DB connection used)
;;; - Redis host/port whitelist (no Redis connection used)
;;; - PostgreSQL connection check (no DB connection used)
;;;
;;; This test follows test-cors.lisp and test-security.lisp pattern.

;;; setup/teardown不要（純粋関数のテスト）

;;; ============================================================
;;; Helper Functions
;;; ============================================================

(defun make-stream-from-string (str)
  "Create a binary input stream from a string for testing."
  (let ((bytes (babel:string-to-octets str :encoding :utf-8)))
    (flexi-streams:make-in-memory-input-stream bytes)))

(defun make-mock-env (&key content-type content-length body-string)
  "Create a mock Clack environment for testing read-body-safely."
  (let ((env (list :content-type content-type)))
    (when content-length
      (setf (getf env :content-length) content-length))
    (when body-string
      (setf (getf env :raw-body) (make-stream-from-string body-string)))
    env))

;;; ============================================================
;;; test-max-csp-report-size (Section 1: Constants)
;;; ============================================================

(deftest test-max-csp-report-size
  (testing "+max-csp-report-size+ is 64KB"
    (ok (= +max-csp-report-size+ (* 64 1024))
        "Should be 64KB (65536 bytes)")))

;;; ============================================================
;;; test-read-body-safely (Section 2: Body Reading)
;;; ============================================================

(deftest test-read-body-safely
  ;; #1: Read body within size limit
  (testing "reads body within size limit"
    (let* ((body-string "{\"csp-report\": {}}")
           (env (make-mock-env :content-type "application/csp-report"
                               :content-length (length body-string)
                               :body-string body-string))
           (result (read-body-safely env +max-csp-report-size+)))
      (ok (string= result body-string)
          "Should read body correctly")))

  ;; #2: Read body at exactly max size
  (testing "reads body at exactly max size"
    (let* ((body-string (make-string (* 64 1024) :initial-element #\a))
           (env (make-mock-env :content-type "application/csp-report"
                               :content-length (length body-string)
                               :body-string body-string))
           (result (read-body-safely env +max-csp-report-size+)))
      (ok (= (length result) (* 64 1024))
          "Should read exactly 64KB")))

  ;; #3: Reject body exceeding max size
  (testing "rejects body exceeding max size"
    (let* ((body-string (make-string (1+ (* 64 1024)) :initial-element #\a))
           (env (make-mock-env :content-type "application/csp-report"
                               :content-length (length body-string)
                               :body-string body-string))
           (result (read-body-safely env +max-csp-report-size+)))
      (ok (null result)
          "Should return NIL for oversized body")))

  ;; #4: Handle NIL content-length
  (testing "handles NIL content-length"
    (let* ((env (make-mock-env :content-type "application/csp-report"
                               :body-string "{\"test\": 1}"))
           (result (read-body-safely env +max-csp-report-size+)))
      (ok (null result)
          "Should return NIL when content-length is missing")))

  ;; #5: Handle zero content-length
  (testing "handles zero content-length"
    (let* ((env (make-mock-env :content-type "application/csp-report"
                               :content-length 0
                               :body-string ""))
           (result (read-body-safely env +max-csp-report-size+)))
      (ok (null result)
          "Should return NIL for zero content-length")))

  ;; #6: Handle string content-length (HTTP header format)
  (testing "handles string content-length"
    (let* ((body-string "{\"test\": 1}")
           (env (make-mock-env :content-type "application/csp-report"
                               :content-length (write-to-string (length body-string))
                               :body-string body-string))
           (result (read-body-safely env +max-csp-report-size+)))
      (ok (string= result body-string)
          "Should parse string content-length correctly")))

  ;; #7: Handle NIL raw-body
  (testing "handles NIL raw-body"
    (let* ((env (make-mock-env :content-type "application/csp-report"
                               :content-length 100))
           (result (read-body-safely env +max-csp-report-size+)))
      (ok (null result)
          "Should return NIL when raw-body is missing"))))

;;; ============================================================
;;; test-extract-csp-report-fields (Section 3: Field Extraction)
;;; ============================================================

(deftest test-extract-csp-report-fields
  ;; #1: Extract all fields from valid report
  (testing "extracts all fields from valid CSP report"
    (let* ((csp-report (make-hash-table :test 'equal))
           (report (make-hash-table :test 'equal)))
      (setf (gethash "document-uri" csp-report) "https://example.com/page")
      (setf (gethash "violated-directive" csp-report) "script-src 'self'")
      (setf (gethash "effective-directive" csp-report) "script-src")
      (setf (gethash "blocked-uri" csp-report) "https://evil.com/script.js")
      (setf (gethash "referrer" csp-report) "https://example.com/")
      (setf (gethash "status-code" csp-report) 200)
      (setf (gethash "csp-report" report) csp-report)
      (let ((fields (extract-csp-report-fields report)))
        (ok (string= (getf fields :|document-uri|) "https://example.com/page")
            "Should extract document-uri")
        (ok (string= (getf fields :|violated-directive|) "script-src 'self'")
            "Should extract violated-directive")
        (ok (string= (getf fields :|effective-directive|) "script-src")
            "Should extract effective-directive")
        (ok (string= (getf fields :|blocked-uri|) "https://evil.com/script.js")
            "Should extract blocked-uri")
        (ok (string= (getf fields :|referrer|) "https://example.com/")
            "Should extract referrer")
        (ok (= (getf fields :|status-code|) 200)
            "Should extract status-code"))))

  ;; #2: Handle missing csp-report key
  (testing "returns NIL when csp-report key is missing"
    (let ((report (make-hash-table :test 'equal)))
      (setf (gethash "other-key" report) "value")
      (let ((fields (extract-csp-report-fields report)))
        (ok (null fields)
            "Should return NIL when csp-report key is missing"))))

  ;; #3: Handle NIL input
  (testing "returns NIL for NIL input"
    (let ((fields (extract-csp-report-fields nil)))
      (ok (null fields)
          "Should return NIL for NIL input")))

  ;; #4: Handle non-hash-table input
  (testing "returns NIL for non-hash-table input"
    (let ((fields (extract-csp-report-fields "not a hash table")))
      (ok (null fields)
          "Should return NIL for non-hash-table input")))

  ;; #5: Handle csp-report value that is not a hash-table
  (testing "returns NIL when csp-report value is not a hash-table"
    (let ((report (make-hash-table :test 'equal)))
      (setf (gethash "csp-report" report) "not a hash table")
      (let ((fields (extract-csp-report-fields report)))
        (ok (null fields)
            "Should return NIL when csp-report value is not a hash-table"))))

  ;; #6: Handle partial fields (some missing)
  (testing "handles partial fields gracefully"
    (let* ((csp-report (make-hash-table :test 'equal))
           (report (make-hash-table :test 'equal)))
      (setf (gethash "document-uri" csp-report) "https://example.com/page")
      (setf (gethash "violated-directive" csp-report) "script-src 'self'")
      ;; Other fields are missing
      (setf (gethash "csp-report" report) csp-report)
      (let ((fields (extract-csp-report-fields report)))
        (ok fields
            "Should return fields even when some are missing")
        (ok (string= (getf fields :|document-uri|) "https://example.com/page")
            "Should have document-uri")
        (ok (null (getf fields :|blocked-uri|))
            "Missing field should be NIL"))))

  ;; #7: Handle empty csp-report object
  (testing "handles empty csp-report object"
    (let* ((csp-report (make-hash-table :test 'equal))
           (report (make-hash-table :test 'equal)))
      (setf (gethash "csp-report" report) csp-report)
      (let ((fields (extract-csp-report-fields report)))
        (ok fields
            "Should return plist for empty csp-report")
        (ok (null (getf fields :|document-uri|))
            "All fields should be NIL")))))
