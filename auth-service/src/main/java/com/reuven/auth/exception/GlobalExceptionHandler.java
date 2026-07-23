package com.reuven.auth.exception;

import com.reuven.ErrorResponse;
import com.reuven.auth.ratelimit.RateLimitErrorCodes;
import com.reuven.auth.ratelimit.RateLimitExceededException;
import jakarta.servlet.http.HttpServletRequest;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.BadCredentialsException;
import org.springframework.validation.FieldError;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.MissingRequestHeaderException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestControllerAdvice;

import java.util.stream.Collectors;

@Slf4j
@RestControllerAdvice
public class GlobalExceptionHandler {

    @ExceptionHandler(ResourceNotFoundException.class)
    @ResponseStatus(HttpStatus.NOT_FOUND)
    public ErrorResponse handleNotFound(ResourceNotFoundException ex, HttpServletRequest request) {
        log.warn("Resource not found: {}", ex.getMessage());
        return errorResponse(HttpStatus.NOT_FOUND, ex.getMessage(), request);
    }

    @ExceptionHandler(BusinessRuleException.class)
    @ResponseStatus(HttpStatus.UNPROCESSABLE_CONTENT)
    public ErrorResponse handleBusinessRule(BusinessRuleException ex, HttpServletRequest request) {
        log.warn("Business rule violation: {}", ex.getMessage());
        return errorResponse(HttpStatus.UNPROCESSABLE_CONTENT, ex.getMessage(), request);
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    @ResponseStatus(HttpStatus.BAD_REQUEST)
    public ErrorResponse handleValidation(MethodArgumentNotValidException ex, HttpServletRequest request) {
        String details = ex.getBindingResult().getFieldErrors().stream()
                .map(FieldError::getDefaultMessage)
                .collect(Collectors.joining(", "));
        return errorResponse(HttpStatus.BAD_REQUEST, details, request);
    }

    @ExceptionHandler(MissingRequestHeaderException.class)
    @ResponseStatus(HttpStatus.BAD_REQUEST)
    public ErrorResponse handleMissingHeader(MissingRequestHeaderException ex, HttpServletRequest request) {
        log.warn("Missing header: {}", ex.getHeaderName());
        return errorResponse(HttpStatus.BAD_REQUEST, "Missing header: " + ex.getHeaderName(), request);
    }

    @ExceptionHandler(AccessDeniedException.class)
    @ResponseStatus(HttpStatus.FORBIDDEN)
    public ErrorResponse handleAccessDenied(AccessDeniedException ex, HttpServletRequest request) {
        return errorResponse(HttpStatus.FORBIDDEN, "Access denied", request);
    }

    @ExceptionHandler(RefreshTokenReuseException.class)
    @ResponseStatus(HttpStatus.UNAUTHORIZED)
    public ErrorResponse handleRefreshTokenReuse(RefreshTokenReuseException ex, HttpServletRequest request) {
        log.warn("Refresh token reuse detected at {}: {}", request.getRequestURI(), ex.getMessage());
        return errorResponse(HttpStatus.UNAUTHORIZED, AuthErrorCodes.REFRESH_TOKEN_REUSE_DETECTED, request);
    }

    @ExceptionHandler(InvalidRefreshTokenException.class)
    @ResponseStatus(HttpStatus.UNAUTHORIZED)
    public ErrorResponse handleInvalidRefreshToken(InvalidRefreshTokenException ex, HttpServletRequest request) {
        return errorResponse(HttpStatus.UNAUTHORIZED, AuthErrorCodes.INVALID_REFRESH_TOKEN, request);
    }

    @ExceptionHandler(BadCredentialsException.class)
    @ResponseStatus(HttpStatus.UNAUTHORIZED)
    public ErrorResponse handleBadCredentials(BadCredentialsException ex, HttpServletRequest request) {
        return errorResponse(HttpStatus.UNAUTHORIZED, "Invalid credentials", request);
    }

    @ExceptionHandler(RateLimitExceededException.class)
    public ResponseEntity<ErrorResponse> handleRateLimitExceeded(RateLimitExceededException ex, HttpServletRequest request) {
        log.warn("Rate limit exceeded at {}: {}", request.getRequestURI(), ex.getMessage());
        long retryAfterSeconds = Math.max(1, ex.retryAfter().toSeconds());
        ErrorResponse body = new ErrorResponse(
                HttpStatus.TOO_MANY_REQUESTS.value(),
                RateLimitErrorCodes.RATE_LIMIT_EXCEEDED,
                ex.getMessage(),
                request.getRequestURI());
        return ResponseEntity.status(HttpStatus.TOO_MANY_REQUESTS)
                .header(HttpHeaders.RETRY_AFTER, String.valueOf(retryAfterSeconds))
                .body(body);
    }

    @ExceptionHandler(Exception.class)
    @ResponseStatus(HttpStatus.INTERNAL_SERVER_ERROR)
    public ErrorResponse handleGeneric(Exception ex, HttpServletRequest request) {
        log.error("Unexpected error at {}: {}", request.getRequestURI(), ex.getMessage(), ex);
        return errorResponse(HttpStatus.INTERNAL_SERVER_ERROR, "An unexpected error occurred", request);
    }

    /**
     * Builds the response body from the SAME {@link HttpStatus} already declared on
     * the handler's {@code @ResponseStatus} - the numeric code and reason phrase
     * ("404"/"Not Found", "401"/"Unauthorized", etc.) are read off the enum instead
     * of being hand-typed a second time, so the two can never fall out of sync with
     * each other or with the actual HTTP status returned to the client.
     */
    private static ErrorResponse errorResponse(HttpStatus status, String message, HttpServletRequest request) {
        return new ErrorResponse(status.value(), status.getReasonPhrase(), message, request.getRequestURI());
    }
}
