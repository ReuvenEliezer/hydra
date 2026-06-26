package com.reuven.auth.dto;
import com.fasterxml.jackson.annotation.JsonInclude;

import java.util.UUID;

@JsonInclude(JsonInclude.Include.NON_NULL)
public record AuthResponse(UUID userId, String token, String message) {
    public AuthResponse(UUID userId, String token) {
        this(userId, token, null);
    }
}
