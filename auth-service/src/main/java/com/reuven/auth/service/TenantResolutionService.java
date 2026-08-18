package com.reuven.auth.service;

import com.reuven.auth.entity.EntityStatus;
import com.reuven.auth.entity.Tenant;
import com.reuven.auth.repository.TenantRepository;
import jakarta.servlet.http.HttpServletRequest;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.HttpHeaders;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Resolves the tenant a request is addressed to, from that request's own {@code Host}.
 * <p>
 * Note "that request's own": the browser sets {@code Host} from the URL it is calling, not from
 * the URL of the page doing the calling. A sign-in page served at {@code acme.localhost:5173}
 * that calls {@code http://localhost:8083} sends {@code Host: localhost:8083} and resolves to
 * {@code UNKNOWN}, however correct the page looks. This is the single most likely way to
 * misconfigure the feature.
 */
@Slf4j
@Service
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class TenantResolutionService {

    private final TenantHostParser hostParser;
    private final TenantRepository tenantRepository;

    public TenantResolution resolve(HttpServletRequest request) {
        return hostParser.extractIdentifier(hostOf(request))
                .flatMap(tenantRepository::findByUrlIdentifier)
                .map(TenantResolutionService::toResolution)
                .orElseGet(TenantResolution::unknown);
    }

    /**
     * HTTP/1.1 requires the {@code Host} header; HTTP/2 and HTTP/3 send {@code :authority}
     * instead, which servlet containers surface as the same header - so one read covers all
     * three. {@code getServerName()} is the container's already-parsed view of that same value
     * and is the right fallback rather than a second source of truth.
     * <p>
     * {@code X-Forwarded-Host} is deliberately NOT consulted: it is a client-settable header, and
     * trusting it would hand the browser back the tenant override this feature exists to remove.
     * Preserving the real {@code Host} is the edge layer's job (FR-011).
     */
    private static String hostOf(HttpServletRequest request) {
        String host = request.getHeader(HttpHeaders.HOST);
        return (host == null || host.isBlank()) ? request.getServerName() : host;
    }

    private static TenantResolution toResolution(Tenant tenant) {
        return EntityStatus.ACTIVE.equals(tenant.getStatus())
                ? TenantResolution.recognized(tenant.getId(), tenant.getName())
                : TenantResolution.inactive(tenant.getId(), tenant.getName());
    }
}
