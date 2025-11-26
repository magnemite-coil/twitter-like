(defpackage twitter-like.web
  (:use :cl)
  (:import-from :lack.middleware.static
                :*lack-middleware-static*)
  (:export :<app>
           :*app*
           :build-app))

(in-package :twitter-like.web)

(defclass <app> (ningle:<app>) ())

(defvar *app* nil
  "Lackアプリケーションインスタンス（build-app呼び出し後に設定）")

(defun build-app ()
  "ミドルウェアスタックを構築してアプリケーションを返す
   設定読み込み後に呼び出すこと"
  (let ((app (make-instance '<app>)))
    ;; ルートを登録
    (twitter-like.handler.health:register-health-routes app)

    ;; 最小構成：ningleアプリをラップしない
    (setf *app* app)
    *app*))
