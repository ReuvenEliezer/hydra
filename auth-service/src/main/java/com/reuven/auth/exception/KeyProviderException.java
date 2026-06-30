package com.reuven.auth.exception;

public class KeyProviderException extends RuntimeException {
    public KeyProviderException(String message) {
        super(message);
    }

    public KeyProviderException(String message, Throwable cause) {
        super(message, cause);
    }
}
