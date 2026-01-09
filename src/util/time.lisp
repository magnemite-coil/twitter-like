;;; src/util/time.lisp
;;; 時刻関連のユーティリティ関数

(defpackage twitter-like.util.time
  (:use :cl)
  (:import-from :local-time
                :format-timestring
                :+iso-8601-format+
                :+utc-zone+)
  (:export :format-timestamp
           :get-unix-time))

(in-package :twitter-like.util.time)

(defun format-timestamp (timestamp)
  "タイムスタンプをISO 8601形式（UTC固定）に変換
   Phase 2: タイムゾーンをUTCに統一（ベストプラクティス）
   出力例: 2026-01-09T12:34:56.789Z"
  (when timestamp
    (local-time:format-timestring nil timestamp
                                   :format local-time:+iso-8601-format+
                                   :timezone local-time:+utc-zone+)))

(defun get-unix-time ()
  "Unix timestamp（1970年1月1日からの秒数）を取得"
  (- (get-universal-time) 2208988800))
