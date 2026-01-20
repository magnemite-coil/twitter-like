(defpackage twitter-like.web
  (:use :cl)
  (:import-from :lack
                :builder)
  (:export :<app>
           :*app*
           :*ningle-app*
           :build-app))

(in-package :twitter-like.web)

(defclass <app> (ningle:<app>) ())

(defvar *ningle-app* nil
  "ningleアプリケーションインスタンス（ルート登録用）")

(defvar *app* nil
  "Lackアプリケーションインスタンス（build-app呼び出し後に設定）")

(defun build-app ()
  "ミドルウェアスタックを構築してアプリケーションを返す
   設定読み込み後に呼び出すこと

   lack:builderを使用してミドルウェアスタックを構築する。
   builderはningleアプリをClack互換の関数に自動変換する。

   ミドルウェア適用順序（リクエスト処理順）:
   static -> logging -> cors -> security -> ningle-app"
  ;; ningleアプリを作成（ルート登録用に保持）
  (setf *ningle-app* (make-instance '<app>))

  ;; ルートを登録
  (twitter-like.handler.health:register-health-routes *ningle-app*)
  (twitter-like.handler.auth:register-auth-routes *ningle-app*)
  (twitter-like.handler.tweet:register-tweet-routes *ningle-app*)
  (twitter-like.handler.csp-report:register-csp-report-routes *ningle-app*)

  ;; lack:builderでミドルウェアスタックを構築
  ;; builderの引数は外側から内側の順（リクエスト処理順）
  ;; 最後の引数がningleアプリ
  (let ((is-development (string= (twitter-like.config:get-config "app-env") "development")))
    (setf *app*
          (lack:builder
           ;; 静的ファイル配信（最外側）
           (:static :path "/static/" :root #P"static/")
           ;; ロギングミドルウェア
           #'twitter-like.util.logger:logging-middleware
           ;; CORS（開発環境のみ）- nilは無視される
           (if is-development
               #'twitter-like.middleware.cors:cors-middleware
               nil)
           ;; セキュリティヘッダー（最内側のミドルウェア）
           #'twitter-like.middleware.security:security-headers-middleware
           ;; ningleアプリ（コア）
           *ningle-app*))

    (format t "✓ Middleware stack built:~%")
    (format t "  - Static file serving (/static/)~%")
    (format t "  - Request/Response logging~%")
    (when is-development
      (format t "  - CORS (development only)~%"))
    (format t "  - Security headers~%")
    *app*))
