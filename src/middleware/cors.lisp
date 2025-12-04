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

(defun get-origin-header (env)
  "ClackのenvからOriginヘッダーを取得する。
   Lack/Clackではヘッダーは:headersキーのハッシュテーブルに格納される。
   キーは小文字の文字列。"
  (let ((headers (getf env :headers)))
    (when headers
      (gethash "origin" headers))))

(defun cors-middleware (app)
  "CORS設定を追加するミドルウェア（環境変数ベース）
   Woo/Clackのベストプラクティス:
   - responseがNILの場合は適切にハンドリング
   - 破壊的変更を避けて新しいリストを返す
   - すべてのヘッダー値は文字列である必要がある"
  (let ((allowed-origins (parse-allowed-origins)))
    (lambda (env)
      ;; ヘッダーは:headersハッシュテーブルから取得
      (let ((origin (get-origin-header env)))
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
              ;; レスポンスが正常な場合のみCORSヘッダーを追加
              (if (and response (listp response) (>= (length response) 3)
                       (origin-allowed-p origin allowed-origins))
                  ;; 新しいリストを作成して返す（破壊的変更を避ける）
                  (let* ((status (first response))
                         (headers (second response))
                         (body (third response))
                         (new-headers (append (or headers '())
                                              (list :access-control-allow-origin origin
                                                    :access-control-allow-credentials "true"))))
                    (list status new-headers body))
                  ;; CORSヘッダー不要またはレスポンスが異常な場合はそのまま返す
                  response)))))))
