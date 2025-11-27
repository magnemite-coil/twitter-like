(defpackage twitter-like.util.logger
  (:use :cl)
  (:import-from :local-time
                :now
                :format-timestring)
  (:import-from :ironclad
                :byte-array-to-hex-string
                :random-data)
  (:import-from :bordeaux-threads
                :make-lock
                :with-lock-held)
  (:export :log-info
           :log-warn
           :log-error
           :log-debug
           :logging-middleware))

(in-package :twitter-like.util.logger)

(defvar *log-levels* '(:debug 0 :info 1 :warn 2 :error 3)
  "ログレベルの優先度マップ")

(defvar *log-lock* (bordeaux-threads:make-lock "log-lock")
  "ログ出力のロック（マルチスレッド対応）")

(defun log-level-priority (level)
  "ログレベルの優先度を取得"
  (or (getf *log-levels* level) 0))

(defun should-log-p (level)
  "指定されたログレベルが出力すべきか判定"
  (let ((configured-level (intern (string-upcase (twitter-like.config:get-config "log-level")) :keyword))
        (message-level level))
    (>= (log-level-priority message-level)
        (log-level-priority configured-level))))

(defun generate-error-id ()
  "エラーIDを生成（16バイト = 32文字の16進数）"
  (ironclad:byte-array-to-hex-string (ironclad:random-data 16)))

(defun ensure-log-directory ()
  "ログディレクトリが存在することを確認、なければ作成
  ログファイルのパーミッションを640に設定（所有者+グループのみ読み取り可）"
  (let* ((log-file (twitter-like.config:get-config "log-file"))
         (log-dir (uiop:pathname-directory-pathname log-file)))
    (ensure-directories-exist log-dir)
    ;; ログファイルのパーミッション設定（Unix系のみ）
    #+unix
    (when (probe-file log-file)
      (handler-case
          (uiop:run-program (list "chmod" "640" (namestring log-file))
                            :ignore-error-status t)
        (error (e)
          (format t "[WARN] Failed to set log file permissions: ~A~%" e))))))

(defun log-message (level message &key context error)
  "ログメッセージを出力（標準出力 + ファイル）
  level: キーワードシンボル (:info, :warn, :error, :debug)
  マルチスレッド対応（ファイル書き込み時にロック）"
  (unless (should-log-p level)
    (return-from log-message nil))

  (let ((log-line (with-output-to-string (s)
                    (format s "[~A] [~A] ~A"
                            (format-timestring nil (now))
                            (string-upcase (symbol-name level))
                            message)
                    (when context
                      (format s " | Context: ~A" context))
                    (when error
                      (format s " | Error: ~A" error)))))

    ;; 標準出力に出力（ロック不要、標準出力はスレッドセーフ）
    (format t "~A~%" log-line)

    ;; ファイルに出力（ロック付き、マルチスレッド対応）
    (bordeaux-threads:with-lock-held (*log-lock*)
      (handler-case
          (progn
            (ensure-log-directory)
            (with-open-file (stream (twitter-like.config:get-config "log-file")
                                    :direction :output
                                    :if-exists :append
                                    :if-does-not-exist :create)
              (format stream "~A~%" log-line)))
        (error (e)
          (format t "[ERROR] Failed to write to log file: ~A~%" e))))))

(defun log-info (message &key context)
  "INFOレベルログ"
  (log-message :info message :context context))

(defun log-warn (message &key context)
  "WARNレベルログ"
  (log-message :warn message :context context))

(defun log-error (message &key context error)
  "ERRORレベルログ（error_idを生成して返す）"
  (let ((error-id (generate-error-id)))
    (log-message :error message
                 :context (append (list :|error_id| error-id) context)
                 :error error)
    error-id))

(defun log-debug (message &key context)
  "DEBUGレベルログ"
  (log-message :debug message :context context))

(defun logging-middleware (app)
  "リクエスト/レスポンスをロギングするミドルウェア"
  (lambda (env)
    (let ((start-time (get-internal-real-time))
          (method (getf env :request-method))
          (path (getf env :path-info)))

      ;; リクエストログ
      (format t "[~A] ~A ~A~%"
              (format-timestring nil (now))
              method
              path)

      ;; リクエスト処理
      (let ((response (funcall app env)))
        ;; レスポンスログ
        (let* ((end-time (get-internal-real-time))
               (duration-ms (/ (- end-time start-time) (/ internal-time-units-per-second 1000.0)))
               (status-code (first response)))
          (format t "[~A] ~A ~A - ~A (~,2f ms)~%"
                  (format-timestring nil (now))
                  method
                  path
                  status-code
                  duration-ms))
        response))))
