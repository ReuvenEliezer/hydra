package com.reuven.auth.controller;

import com.reuven.auth.dto.TenantResolutionResponse;
import com.reuven.auth.service.TenantResolutionService;
import com.reuven.ratelimit.RateLimited;
import jakarta.servlet.http.HttpServletRequest;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * The public tenant lookup the sign-in page calls once on load, before anyone has credentials to
 * offer (FR-014). Unauthenticated by necessity - see the {@code permitAll} rule in
 * {@code SecurityCommons.authRules()}, without which this 401s.
 * <p>
 * All three outcomes return {@code 200}: the resolution status is the payload, not the HTTP code.
 * A {@code 404} for an unknown address would collide with {@code ResourceNotFoundException}'s
 * meaning in this service and force clients to distinguish "no tenant at this address" from "this
 * endpoint does not exist".
 * <p>
 * Rate-limited per client IP (FR-016). The three statuses stay distinct - deliberately not blurred
 * into a uniform answer to hide which tenants exist, since DNS already reveals that and FR-004/
 * FR-005 require a user to be told which of the three situations they are in. Throttling, not
 * ambiguity, is the mitigation for enumeration.
 */
@RestController
@RequestMapping("/api/v1")
@RequiredArgsConstructor
public class TenantController {

    private final TenantResolutionService tenantResolutionService;

    @GetMapping("/tenant")
    @RateLimited(limit = "tenant-resolve-ip", key = "T(com.reuven.ratelimit.ClientIpResolver).resolve(#httpRequest)")
    public TenantResolutionResponse resolveTenant(HttpServletRequest httpRequest) {
        return TenantResolutionResponse.from(tenantResolutionService.resolve(httpRequest));
    }
}
