(defpackage twitter-like.util.response
  (:use :cl)
  (:import-from :com.inuoe.jzon
                :stringify)
  (:export :response-success
           :response-error))

(in-package :twitter-like.util.response)

(defun response-success (data &key (status 200))
  "成功レスポンスを生成（Clack準拠のplist形式ヘッダー）"
  (unless (and (>= status 200) (<= status 299))
    (error "Invalid success status code: ~A (must be 2xx)" status))
  (let ((json-string (com.inuoe.jzon:stringify data)))
    (list status
          (list :content-type "application/json; charset=utf-8")
          (list json-string))))

(defun response-error (status message &key error-id details)
  "エラーレスポンスを生成（Clack準拠のplist形式ヘッダー）"
  (unless (and (>= status 400) (<= status 599))
    (error "Invalid error status code: ~A (must be 4xx or 5xx)" status))
  (let* ((error-data (list (cons "error" message)))
         (_ (when error-id (push (cons "error_id" error-id) error-data)))
         (_ (when details (push (cons "details" details) error-data)))
         (json-string (com.inuoe.jzon:stringify error-data)))
    (declare (ignore _ _))
    (list status
          (list :content-type "application/json; charset=utf-8")
          (list json-string))))
