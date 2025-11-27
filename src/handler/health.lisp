(defpackage twitter-like.handler.health
  (:use :cl)
  (:import-from :twitter-like.util.response
                :response-success
                :response-error)
  (:import-from :twitter-like.util.logger
                :log-error
                :log-warn)
  (:import-from :str
                :split
                :emptyp
                :replace-all)
  (:export :register-health-routes))

(in-package :twitter-like.handler.health)

(defun health-handler (params)
  "ヘルスチェックエンドポイント（拡張版）"
  (declare (ignore params))
  (handler-case
      (let ((health-data (make-hash-table :test 'equal)))
        ;; 基本情報
        (setf (gethash "status" health-data) "healthy")
        (setf (gethash "timestamp" health-data) (local-time:timestamp-to-unix (local-time:now)))

        ;; データベース接続確認
        (handler-case
            (progn
              (twitter-like.db:ensure-db-connected)
              (setf (gethash "database" health-data) "connected"))
          (error (e)
            (setf (gethash "database" health-data) "disconnected")
            (setf (gethash "status" health-data) "unhealthy")
            (twitter-like.util.logger:log-error "Database health check failed" :error e)))

        ;; Redis接続確認
        (handler-case
            (progn
              (twitter-like.middleware.session:ensure-redis-connected)
              ;; Redis PING確認（cl-redisではred:pingを使用）
              (red:ping)
              (setf (gethash "redis" health-data) "connected"))
          (error (e)
            (setf (gethash "redis" health-data) "disconnected")
            (setf (gethash "status" health-data) "unhealthy")
            (twitter-like.util.logger:log-error "Redis health check failed" :error e)))

        ;; ディスク容量チェック（簡易版）
        (let ((disk-usage (check-disk-usage)))
          (setf (gethash "disk" health-data) disk-usage)
          (when (and (gethash "usage_percent" disk-usage)
                     (> (gethash "usage_percent" disk-usage) 90))
            (setf (gethash "status" health-data) "degraded")
            (twitter-like.util.logger:log-warn "Disk usage critical"
                                               :context (list :|usage_percent| (gethash "usage_percent" disk-usage)))))

        ;; メモリ使用量チェック（簡易版）
        (let ((memory-usage (check-memory-usage)))
          (setf (gethash "memory" health-data) memory-usage))

        ;; ステータスに応じてHTTPステータスコードを決定
        (let ((status-code (cond
                             ((string= (gethash "status" health-data) "healthy") 200)
                             ((string= (gethash "status" health-data) "degraded") 200)
                             (t 503))))
          (response-success health-data :status status-code)))
    (error (e)
      ;; エラーIDを生成してログ記録
      (let ((error-id (twitter-like.util.logger:log-error
                        "Health check failed"
                        :error e)))
        (response-error 503 "Service Unavailable" :error-id error-id)))))

(defun check-disk-usage ()
  "ディスク容量をチェック（POSIX準拠、移植性向上版）"
  (handler-case
      (let* ((log-dir (uiop:pathname-directory-pathname
                        (twitter-like.config:get-config "log-file")))
             ;; df -P でPOSIX準拠フォーマット（移植性向上、macOS/Linux共通）
             (df-output (uiop:run-program
                          (list "df" "-P" (namestring log-dir))
                          :output :string))
             ;; 1行目はヘッダー、2行目がデータ
             (lines (str:split #\Newline df-output :omit-nulls t))
             (data-line (second lines))
             ;; スペースで分割（空文字列を除去）
             (fields (remove-if #'str:emptyp (str:split #\Space data-line)))
             ;; POSIX準拠フォーマットでは5番目のフィールドが使用率（0-indexed: 4番目）
             ;; フォーマット: Filesystem 512-blocks Used Available Capacity Mounted
             (usage-str (fifth fields))
             (usage-percent (parse-integer (str:replace-all "%" "" usage-str))))
        (let ((result (make-hash-table :test 'equal)))
          (setf (gethash "status" result) "ok")
          (setf (gethash "usage_percent" result) usage-percent)
          result))
    (error (e)
      (twitter-like.util.logger:log-warn "Failed to check disk usage" :error e)
      (let ((result (make-hash-table :test 'equal)))
        (setf (gethash "status" result) "unknown")
        result))))

(defun check-memory-usage ()
  "メモリ使用量をチェック（SBCL専用、他の処理系では'unsupported'を返す）"
  (handler-case
      #+sbcl
      (let* ((dynamic-usage (sb-kernel:dynamic-usage))
             ;; バイトからMBに変換
             (usage-mb (/ dynamic-usage 1024 1024)))
        (let ((result (make-hash-table :test 'equal)))
          (setf (gethash "status" result) "ok")
          (setf (gethash "usage_mb" result) (floor usage-mb))
          result))
      #-sbcl
      (let ((result (make-hash-table :test 'equal)))
        (setf (gethash "status" result) "unsupported")
        (setf (gethash "implementation" result) (lisp-implementation-type))
        result)
    (error (e)
      (twitter-like.util.logger:log-warn "Failed to check memory usage" :error e)
      (let ((result (make-hash-table :test 'equal)))
        (setf (gethash "status" result) "unknown")
        result))))

(defun register-health-routes (app)
  "ヘルスチェックルートをアプリケーションに登録"
  (setf (ningle:route app "/api/health" :method :get) #'health-handler)
  app)
