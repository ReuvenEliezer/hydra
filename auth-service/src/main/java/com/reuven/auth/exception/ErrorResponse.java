package com.reuven.auth.exception;

import java.time.Instant;

public record ErrorResponse(int status, String error, String message, String path, Instant timestamp) {
    public ErrorResponse(int status, String error, String message, String path) {
        this(status, error, message, path, Instant.now());
    }
}
