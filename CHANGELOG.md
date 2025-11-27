# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2025-11-27

### Fixed

- **Middleware Stack Integration** (src/web.lisp)
  - Use `lack:builder` to properly integrate ningle app with Clack middleware
  - ningle `<app>` class instances are now correctly converted to Clack-compatible functions

- **CORS Middleware** (src/middleware/cors.lisp)
  - Fix Origin header retrieval using `:headers` hash table with lowercase key
  - Preflight requests now correctly return 200 with CORS headers for allowed origins

## [0.1.0] - 2025-11-27

### Added

- **Project Foundation**
  - ASDF system definition (twitter-like.asd)
  - Directory structure (src/, test/, docs/)
  - Environment variable template (.env.example)
  - Makefile for development tasks

- **Configuration Management** (src/config.lisp)
  - Environment variable loading via cl-dotenv
  - Secret key validation (256-bit hexadecimal)
  - Configuration validation on startup

- **Database Connection** (src/db.lisp)
  - PostgreSQL connection with Mito ORM
  - Retry mechanism (max 3 attempts)
  - Connection health check

- **Redis Connection** (src/middleware/session.lisp)
  - Redis connection management
  - Authentication support
  - Database selection support
  - Retry mechanism

- **Health Check Endpoint** (src/handler/health.lisp)
  - GET /api/health endpoint
  - Database connectivity check
  - Redis connectivity check
  - Disk usage monitoring (POSIX compliant)
  - Memory usage monitoring (SBCL)

- **Security Middleware** (src/middleware/security.lisp)
  - Content-Security-Policy header
  - Strict-Transport-Security header
  - X-Content-Type-Options header
  - X-Frame-Options header
  - Referrer-Policy header
  - Permissions-Policy header

- **CORS Middleware** (src/middleware/cors.lisp)
  - Environment-based allowed origins configuration
  - Preflight request handling

- **Utilities**
  - JSON response helpers with Clack-compliant plist headers (src/util/response.lisp)
  - Structured logging with thread safety and file output (src/util/logger.lisp)

- **Test Infrastructure**
  - Test setup utilities (test/setup.lisp)
  - Configuration tests (test/test-config.lisp)
  - Database tests (test/test-db.lisp)
  - Health check tests (test/test-health.lisp)

[Unreleased]: https://github.com/magnemite-coil/twitter-like/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/magnemite-coil/twitter-like/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/magnemite-coil/twitter-like/releases/tag/v0.1.0
