;;; src/util/time.lisp
;;; 時刻関連のユーティリティ関数

(defpackage twitter-like.util.time
  (:use :cl)
  (:import-from :local-time
                :format-timestring
                :+iso-8601-format+)
  (:export :format-timestamp
           :get-unix-time))

(in-package :twitter-like.util.time)

(defun format-timestamp (timestamp)
  "タイムスタンプをISO 8601形式に変換"
  (when timestamp
    (local-time:format-timestring nil timestamp
                                   :format local-time:+iso-8601-format+)))

(defun get-unix-time ()
  "Unix timestamp（1970年1月1日からの秒数）を取得"
  (- (get-universal-time) 2208988800))
