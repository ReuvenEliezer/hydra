package com.reuven.auth.exception;

public class InvalidTokenException extends RuntimeException {
    public InvalidTokenException(String message, Throwable cause) { super(message, cause); }
}