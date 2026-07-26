package com.reuven.ratelimit;

import com.reuven.ErrorResponse;
import jakarta.servlet.http.HttpServletRequest;
import lombok.extern.slf4j.Slf4j;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

/**
 * Maps {@link RateLimitExceededException} to a 429 with a {@code Retry-After} header,
 * for every service that adopts this module - previously duplicated by hand inside
 * each service's own {@code GlobalExceptionHandler}. Registered by
 * {@link RateLimitAutoConfiguration} under the same condition as the engine/aspect, so
 * a service that hasn't adopted rate limiting never gets an advice bean for an
 * exception type it can never throw.
 *
 * <p>A dedicated advice class rather than folding this into each service's own
 * handler also means a service-specific {@code @ExceptionHandler(Exception.class)}
 * catch-all can never accidentally intercept this one first - Spring picks the most
 * specific exception match regardless of which advice bean declares it, but keeping
 * it out of the generic handler removes any doubt when reading either class.
 */
@Slf4j
@RestControllerAdvice
@Order(Ordered.HIGHEST_PRECEDENCE)
public class RateLimitExceptionHandler {

    @ExceptionHandler(RateLimitExceededException.class)
    public ResponseEntity<ErrorResponse> handleRateLimitExceeded(RateLimitExceededException ex, HttpServletRequest request) {
        log.warn("rate_limit_exceeded path={} message={}", request.getRequestURI(), ex.getMessage());

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
}
