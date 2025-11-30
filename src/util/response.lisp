(defpackage twitter-like.util.response
  (:use :cl)
  (:import-from :com.inuoe.jzon
                :stringify)
  (:export :response-success
           :response-error))

(in-package :twitter-like.util.response)

(defun utf8-byte-length (string)
  "文字列のUTF-8エンコード時のバイト長を計算"
  (length (babel:string-to-octets string :encoding :utf-8)))

(defun response-success (data &key (status 200))
  "成功レスポンスを生成（Clack準拠のplist形式ヘッダー）"
  (unless (and (>= status 200) (<= status 299))
    (error "Invalid success status code: ~A (must be 2xx)" status))
  (let* ((json-string (com.inuoe.jzon:stringify data))
         (content-length (utf8-byte-length json-string)))
    (list status
          (list :content-type "application/json; charset=utf-8"
                :content-length content-length)
          (list json-string))))

(defun response-error (status message &key error-id details)
  "エラーレスポンスを生成（Clack準拠のplist形式ヘッダー）"
  (unless (and (>= status 400) (<= status 599))
    (error "Invalid error status code: ~A (must be 4xx or 5xx)" status))
  (let ((error-data (make-hash-table :test 'equal)))
    (setf (gethash "error" error-data) message)
    (when error-id
      (setf (gethash "error_id" error-data) error-id))
    (when details
      (setf (gethash "details" error-data) details))
    (let* ((json-string (com.inuoe.jzon:stringify error-data))
           (content-length (utf8-byte-length json-string)))
      (list status
            (list :content-type "application/json; charset=utf-8"
                  :content-length content-length)
            (list json-string)))))
