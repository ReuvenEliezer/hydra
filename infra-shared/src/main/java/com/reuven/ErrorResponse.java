package com.reuven;

import java.time.Instant;

/**
 * Standard error response body. auth-service and order-service each had their own
 * byte-for-byte identical copy of this record - same fields, same convenience
 * constructor - which is the kind of duplication that's easy to let drift (add a
 * field to one copy under time pressure and forget the other). Both services'
 * {@code GlobalExceptionHandler} now return this one shared type instead.
 */
public record ErrorResponse(int status, String error, String message, String path, Instant timestamp) {
    public ErrorResponse(int status, String error, String message, String path) {
        this(status, error, message, path, Instant.now());
    }
}
