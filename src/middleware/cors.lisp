(defpackage twitter-like.middleware.cors
  (:use :cl)
  (:import-from :str
                :split
                :trim)
  (:export :cors-middleware))

(in-package :twitter-like.middleware.cors)

(defun parse-allowed-origins ()
  "環境変数からCORS許可オリジンリストを取得"
  (handler-case
      (let ((origins-str (twitter-like.config:get-config "cors-allowed-origins")))
        (if (and origins-str (not (string= origins-str "")))
            ;; カンマ区切りで分割、トリム
            (mapcar #'str:trim (str:split "," origins-str))
            ;; 未設定の場合は空リスト
            nil))
    (error (e)
      (format t "⚠ Failed to parse CORS_ALLOWED_ORIGINS: ~A~%" e)
      nil)))

(defun origin-allowed-p (origin allowed-origins)
  "オリジンが許可リストに含まれるか確認"
  (when (and origin allowed-origins)
    (member origin allowed-origins :test #'string=)))

(defun cors-middleware (app)
  "CORS設定を追加するミドルウェア（環境変数ベース）"
  (let ((allowed-origins (parse-allowed-origins)))
    (lambda (env)
      (let ((origin (getf env :http-origin)))
        (if (eq (getf env :request-method) :options)
            ;; プリフライトリクエスト
            (if (origin-allowed-p origin allowed-origins)
                (list 200
                      (list :content-type "text/plain"
                            :access-control-allow-origin origin
                            :access-control-allow-methods "GET, POST, PUT, DELETE, OPTIONS"
                            :access-control-allow-headers "Content-Type, Authorization"
                            :access-control-allow-credentials "true"
                            :access-control-max-age "86400")  ; 24時間キャッシュ
                      (list "OK"))
                ;; 許可されていないオリジン
                (list 403
                      (list :content-type "text/plain")
                      (list "Forbidden")))
            ;; 通常のリクエスト
            (let ((response (funcall app env)))
              (when (origin-allowed-p origin allowed-origins)
                ;; レスポンスヘッダーにCORSヘッダーを追加（plist形式）
                (let ((headers (second response)))
                  (setf headers (append headers
                                        (list :access-control-allow-origin origin
                                              :access-control-allow-credentials "true")))
                  (setf (second response) headers)))
              response))))))
