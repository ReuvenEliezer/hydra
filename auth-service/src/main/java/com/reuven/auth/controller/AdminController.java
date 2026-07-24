package com.reuven.auth.controller;

import com.reuven.Role;
import com.reuven.Roles;
import com.reuven.auth.dto.AuthResponse;
import com.reuven.auth.dto.CustomUserDetails;
import com.reuven.auth.dto.RegisterRequest;
import com.reuven.auth.service.AuthService;
import com.reuven.auth.service.JwtProvider;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.HttpStatus;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.bind.annotation.*;

import java.security.Principal;
import java.util.UUID;

@Slf4j
@RestController
@RequestMapping("/api/v1/admin")
@RequiredArgsConstructor
public class AdminController {

    private final AuthService authService;

    @PostMapping("/register-user")
    @PreAuthorize(Roles.ADMIN)
    @ResponseStatus(HttpStatus.CREATED)
    public AuthResponse registerUser(
            @Valid @RequestBody RegisterRequest request,
            @AuthenticationPrincipal CustomUserDetails currentUser) {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        log.info("AUTH: {}", auth);
        log.info("AUTHORITIES: {}", auth.getAuthorities());
        return authService.registerUser(request, currentUser);
    }

    @PostMapping("/{tenantId}/register-admin") //TODO do by domain (mapping domain-url to tenantId)
    @PreAuthorize(Roles.SUPER_ADMIN_ONLY)
    @ResponseStatus(HttpStatus.CREATED)
    public AuthResponse registerAdmin(
            @PathVariable("tenantId") UUID tenantId,
            @Valid @RequestBody RegisterRequest request) {

        return authService.registerAdmin(request, tenantId, Role.SUPER_ADMIN);
    }
}