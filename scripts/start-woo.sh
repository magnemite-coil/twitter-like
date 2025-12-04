#!/usr/bin/env bash
set -euo pipefail

# Project root
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Ensure vendor-locals are used for Woo / fast-http
export QL_LOCAL_PROJECTS="${ROOT}/vendor"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${ROOT}/var/cache}"

# Runtime env
export APP_ENV="${APP_ENV:-production}"
export APP_PORT="${APP_PORT:-8080}"

LISP=${LISP:-sbcl}
LISP_SCRIPT="${ROOT}/var/cache/start-woo.lisp"

mkdir -p "${ROOT}/var/cache"

cat > "${LISP_SCRIPT}" <<'LISP'
(let* ((root (truename "."))
       (vendor (merge-pathnames "vendor/" root)))
  ;; Prefer vendored deps
  (pushnew vendor ql:*local-project-directories* :test #'equal)
  (pushnew root asdf:*central-registry* :test #'equal)
  (pushnew vendor asdf:*central-registry* :test #'equal)
  (pushnew (merge-pathnames "vendor/woo/" root) asdf:*central-registry* :test #'equal)
  (pushnew (merge-pathnames "vendor/fast-http/" root) asdf:*central-registry* :test #'equal)
  ;; Clear any previously cached definitions
  (ignore-errors (asdf:clear-system :woo))
  (ignore-errors (asdf:clear-system :fast-http)))

(ql:quickload :twitter-like)

;; Start with Woo (production/non-test); port is taken from APP_PORT env
(twitter-like:start :port (parse-integer (uiop:getenv "APP_PORT")))

(loop (sleep 3600))
LISP

exec "${LISP}" --disable-debugger --noinform --load "${LISP_SCRIPT}"
