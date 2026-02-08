# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Tweet System Phase 2: Cursor Pagination & N+1 Resolution**
  - Cursor-based pagination (max_id/since_id) for Twitter API v1.1 compatibility
  - N+1 query resolution using JOIN-based user info retrieval
  - Parameter validation with bigint range checking

- **Rate Limiting Improvements**
  - Unified rate limiting with Lua atomic operations (src/util/rate-limit.lisp)
  - :optimistic mode for login (count on attempt, decrement on success)
  - :always mode for registration (count on every attempt)
  - IETF RateLimit structured headers (draft-09/10 compliant)
    - `RateLimit: "default";r=<remaining>;t=<reset-seconds>`
    - `RateLimit-Policy: "default";q=<quota>;w=<window>`
    - Backward compatible X-RateLimit-* headers maintained

- **Error Handling**
  - Added handler-case to get-user-tweets-handler for unexpected errors

- **Security Unit Tests** (test/test-crypto.lisp, test/test-session.lisp, test/test-request.lisp)
  - Crypto utilities: PBKDF2 hashing, constant-time comparison, token generation (27 cases)
  - Session management: Redis operations, session rotation, CSRF tokens (30 cases)
  - Request utilities: Cookie parsing, IP extraction, DoS protection (48 cases)
  - Total 105 security-focused test cases covering OWASP Top 10 concerns

- **CORS Middleware Unit Tests** (test/test-cors.lisp)
  - Origin validation with OWASP security tests (wildcard, null origin, subdomain spoofing)
  - Header parsing and middleware behavior tests
  - Total 33 test cases ensuring CORS security compliance

- **Security Middleware Unit Tests** (test/test-security.lisp)
  - Header addition, preservation, and override tests (OWASP security boundary)
  - Environment-based HSTS configuration (production only)
  - Fallback 500 response with security headers (defense-in-depth)
  - String/keyword header key normalization
  - Total 31 test cases covering all security header behaviors

- **CSP Report Handler & Tests** (src/handler/csp-report.lisp, test/test-csp-report.lisp)
  - POST /api/csp-report endpoint for CSP violation monitoring
  - DoS protection with 64KB body size limit
  - Chunked transfer encoding support (RFC 7230)
  - Case-insensitive Content-Type comparison (RFC 7231)
  - Total 24 test cases for handler and utility functions

- **Auth Service Unit Tests** (test/test-auth-validation.lisp, test/test-auth-service.lisp)
  - Pure function tests for validate-username and validate-password (19 test cases)
  - Redis/DB dependent tests with 12-layer security guard (61 test cases)
  - Rate limiting: check-login-rate-limit, decrement-login-rate-limit, check-register-rate-limit
  - Account lockout: check-account-lockout, record-login-failure, clear-login-failures
  - User registration and authentication with cleanup helpers
  - Total 80 test cases improving auth service coverage from 47.7% to 80%+

- **Auth Handler Integration Tests** (test/test-auth.lisp)
  - Content-Type validation tests (415 for missing/invalid Content-Type)
  - JSON parse error tests (400 for empty/invalid body)
  - Username validation tests (400 for missing/empty username)
  - Session validation tests (401 for missing/invalid session)
  - Session timeout tests (401 for absolute/idle timeout)
  - Account lockout tests (429 after 5 failed attempts)
  - Rate limit tests with IETF RateLimit header verification
  - Request body size limit tests (413 for >1MB body)
  - User DB inconsistency tests (401 when user deleted)
  - error_id verification for all client-caused errors (4xx should NOT have error_id)
  - Total 23 test cases covering handler/auth.lisp edge cases

- **Config Validation Unit Tests** (test/test-config.lisp)
  - `required-env-var`: Environment variable retrieval with error message verification (3 cases)
  - `validate-secret-key`: Secret key validation with boundary value tests (10 cases)
  - `reload-config`: Configuration reload behavior in test/development environments (2 cases)
  - Expression coverage improved from 75.9% to 90.3%
  - Branch coverage improved from 38.9% to 77.8%
  - Total 15 test cases covering config.lisp validation functions

- **Test Utilities** (test/util.lisp)
  - `with-env-var`: Environment variable temporary modification helper (refactored from test-request.lisp)

- **Session Branch Coverage Tests** (test/test-session.lisp)
  - Edge case tests for `touch-session`, `disconnect-redis`, `ensure-redis-connected` (nil/empty state handling)
  - Defensive code coverage tests for `get-session-user-id`, `get-csrf-token`, `delete-session` (nil session-id)
  - Branch coverage improved from 36.4% to 57.1%
  - Total 9 deftests covering session management edge cases

- **Coverage Measurement Targets** (Makefile)
  - `test-coverage`: Full test suite with sb-cover HTML report generation
  - `test-coverage-session`: Session module focused coverage measurement

- **Health Handler Unit Tests** (test/test-health-unit.lisp)
  - Core function extraction: `collect-health-data` with dependency injection pattern
  - DB/Redis failure tests (503 unhealthy response)
  - Disk usage degraded state tests (200 with status=degraded for >90%)
  - Disk/memory check error handling tests (status=unknown)
  - Status priority regression tests (unhealthy > degraded > healthy)
  - Boundary value tests (exactly 90% disk usage)
  - Expression coverage improved from 61.2% to 86.0%
  - Branch coverage improved from 37.5% to 100%
  - Total 13 unit tests covering collect-health-data edge cases

- **Rate-Limit Unit Tests** (test/test-rate-limit.lisp, test/test-rate-limit-redis.lisp)
  - Pure function tests: `ensure-integer`, `format-ratelimit-header`, `format-ratelimit-policy-header`, `build-ratelimit-headers` (34 cases)
  - Redis integration tests: `check-and-increment`, `increment`, `decrement` with 12-layer security guard (44 cases)
  - IETF draft-09/10 compliant RateLimit header verification
  - increment-on mode tests (:always, :check, :optimistic, :manual) with ZSET count verification
  - Window expiration tests using ZADD (no sleep, flaky-free)
  - Total 78 test cases covering rate-limit module

### Changed

- **Timestamp Format** (Breaking Change)
  - All API timestamps now use UTC timezone (ISO 8601 with Z suffix)
  - Frontend applications should parse timestamps as UTC

- **Query Parameter Validation** (Breaking Change)
  - Non-integer query parameters (max_id, since_id, count, limit, offset) now return 400 error
  - Out-of-range bigint values return 400 error

### Fixed

- **Session Middleware** (src/middleware/session.lisp)
  - Fix `DEFCONSTANT-UNEQL` error on system reload by changing Lua script definition from `defconstant` to `defparameter`
  - String literals in Common Lisp are not `eql` across recompilations, causing SBCL to reject redefinition

- **Health Handler** (src/handler/health.lisp)
  - Fix status priority bug: `unhealthy` status was being overwritten by `degraded` when disk usage exceeded 90%
  - Status priority is now correctly enforced: unhealthy > degraded > healthy
  - Refactored to extract `collect-health-data` core function for testability

### Security

- Improved login rate limiting with atomic Lua operations
- Added Vary: Origin header to CORS responses for cache poisoning prevention (OWASP recommendation)
- Enhanced security headers middleware with configurable HSTS (production-only)
- Added CSP violation reporting endpoint for security monitoring

## [0.2.0] - 2025-11-29

### Added

- **User Authentication System** (OWASP 2024-2025 Compliant)
  - PBKDF2-HMAC-SHA256 password hashing with 600,000 iterations (src/util/crypto.lisp)
  - 128-bit salt, 256-bit output, constant-time comparison for timing attack prevention
  - Cryptographically secure session ID and CSRF token generation (128-bit CSPRNG)
  - Session ID masking for secure logging

- **User Model** (src/model/user.lisp)
  - Mito ORM table definition with username, password, email, display_name, bio fields
  - UNIQUE constraint on username
  - Public and private JSON conversion functions

- **Session Management** (src/middleware/session.lisp)
  - Redis Hash-based session storage
  - Absolute timeout (7 days) and idle timeout (30 minutes)
  - Session rotation on login (session fixation attack prevention)
  - Secure cookie construction (HttpOnly, Secure, SameSite=Lax)

- **Authentication Service** (src/service/auth.lisp)
  - Username validation (3-20 characters, alphanumeric + underscore)
  - Password validation (15-128 characters)
  - IP-based rate limiting (login: 5/15min, register: 3/1hr)
  - Account lockout after 5 failed attempts (30 minute lock)
  - Timing attack protection with dummy hash verification

- **Authentication Endpoints** (src/handler/auth.lisp)
  - POST /api/auth/register - User registration with auto-login
  - POST /api/auth/login - Login with session rotation
  - POST /api/auth/logout - Logout with CSRF validation
  - GET /api/auth/me - Current user info with X-CSRF-Token header

- **Authentication Tests** (test/test-auth.lisp)
  - Register -> me -> logout flow test with CSRF validation
  - Login rate limit test (429 after threshold)

## [0.1.3] - 2025-12-04

### Fixed

- **Vendor: fast-http** (vendor/fast-http/src/parser.lisp)
  - Add `message-complete-safe` function to absorb `CALLBACK-ERROR` gracefully
  - Wrap `callback-data :body` calls in `handler-case` to prevent parser crashes
  - Handle cases where socket data handler is already cleared after 429 responses

- **Vendor: Woo** (vendor/woo/src/response.lisp)
  - Add HTTP status codes: 425 (Too Early), 428 (Precondition Required), 429 (Too Many Requests), 431 (Request Header Fields Too Large)
  - Make `response-headers-bytes` defensive: dynamically build status line when status code is not in lookup table (fixes 429 returning 500)
  - Add nil check for header keys in response header loop

## [0.1.2] - 2025-12-01

### Fixed

- **Response Utility** (src/util/response.lisp)
  - Fix `content-length` header value to be string instead of integer
  - Woo/Clack requires all header values to be strings

- **Security Middleware** (src/middleware/security.lisp)
  - Add proper NIL response handling
  - Return 500 error for invalid/NIL responses instead of implicit NIL return

- **CORS Middleware** (src/middleware/cors.lisp)
  - Add proper NIL response checking
  - Use non-destructive list creation for response headers

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

[Unreleased]: https://github.com/magnemite-coil/twitter-like/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/magnemite-coil/twitter-like/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/magnemite-coil/twitter-like/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/magnemite-coil/twitter-like/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/magnemite-coil/twitter-like/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/magnemite-coil/twitter-like/releases/tag/v0.1.0
