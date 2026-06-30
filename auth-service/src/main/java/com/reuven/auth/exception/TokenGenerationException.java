package com.reuven.auth.exception;

public class TokenGenerationException extends RuntimeException {
    public TokenGenerationException(String message, Throwable cause) { super(message, cause); }
}
