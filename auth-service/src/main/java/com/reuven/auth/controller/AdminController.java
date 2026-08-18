package com.reuven.auth.controller;

import com.reuven.Role;
import com.reuven.Roles;
import com.reuven.auth.dto.AuthResponse;
import com.reuven.auth.dto.CreateTenantRequest;
import com.reuven.auth.dto.CustomUserDetails;
import com.reuven.auth.dto.RegisterRequest;
import com.reuven.auth.dto.TenantResponse;
import com.reuven.auth.service.AuthService;
import com.reuven.auth.service.JwtProvider;
import com.reuven.auth.service.TenantProvisioningService;
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
    private final TenantProvisioningService tenantProvisioningService;

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

    /**
     * Creates a tenant and permanently claims its sign-in address in one step.
     * <p>
     * On {@code 201} the address works immediately - {@code GET /api/v1/tenant} at
     * {@code <urlIdentifier>.<base-domain>} returns {@code recognized} with no further
     * configuration, deployment, or restart. That is the point: an address that needed a
     * second manual step would be an address that is broken between the two.
     */
    @PostMapping("/tenants")
    @PreAuthorize(Roles.SUPER_ADMIN_ONLY)
    @ResponseStatus(HttpStatus.CREATED)
    public TenantResponse createTenant(@Valid @RequestBody CreateTenantRequest request) {
        return tenantProvisioningService.createTenant(request);
    }

    @PostMapping("/{tenantId}/register-admin")
    @PreAuthorize(Roles.SUPER_ADMIN_ONLY)
    @ResponseStatus(HttpStatus.CREATED)
    public AuthResponse registerAdmin(
            @PathVariable("tenantId") UUID tenantId,
            @Valid @RequestBody RegisterRequest request) {

        return authService.registerAdmin(request, tenantId, Role.SUPER_ADMIN);
    }
}