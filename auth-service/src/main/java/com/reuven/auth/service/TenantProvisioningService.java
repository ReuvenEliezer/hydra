package com.reuven.auth.service;

import com.reuven.auth.config.TenantResolutionProperties;
import com.reuven.auth.dto.CreateTenantRequest;
import com.reuven.auth.dto.TenantResponse;
import com.reuven.auth.entity.EntityStatus;
import com.reuven.auth.entity.ReservedTenantIdentifier;
import com.reuven.auth.entity.Tenant;
import com.reuven.auth.exception.BusinessRuleException;
import com.reuven.auth.repository.ReservedTenantIdentifierRepository;
import com.reuven.auth.repository.TenantRepository;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.Locale;

/**
 * Creates a tenant together with the permanent claim on its sign-in address.
 * <p>
 * The two writes are one transaction on purpose. A tenant without its reservation could later
 * have its address handed to someone else; a reservation without its tenant would block an
 * address nobody uses. Neither is a state this system should be able to reach, so neither is
 * reachable: if either write fails, both roll back.
 * <p>
 * Note what is NOT here: a "is this identifier free?" query followed by an insert. Two
 * concurrent requests for the same identifier would both pass that check and both proceed. The
 * primary key on {@code reserved_tenant_identifiers} is what actually decides the race - the
 * loser's insert violates it and its whole transaction unwinds. The
 * {@code existsByIdentifier} call below is a courtesy that turns the common, uncontended case
 * into a clear {@code 422} instead of a constraint-violation stack trace; it is not the
 * safety mechanism.
 */
@Slf4j
@Service
@RequiredArgsConstructor
public class TenantProvisioningService {

    private final TenantRepository tenantRepository;
    private final ReservedTenantIdentifierRepository reservedIdentifierRepository;
    private final TenantResolutionProperties tenantProperties;

    @Transactional
    public TenantResponse createTenant(CreateTenantRequest request) {
        // The bean-validation pattern already forbids uppercase, so this only normalizes what
        // is already lowercase - it is here so the stored value can never differ in case from
        // what TenantHostParser produces when reading a host back.
        String identifier = request.urlIdentifier().toLowerCase(Locale.ROOT);

        if (tenantProperties.reservedIdentifiers().contains(identifier)) {
            throw new BusinessRuleException(
                    "URL identifier '" + identifier + "' is reserved and cannot be assigned to a tenant");
        }

        if (reservedIdentifierRepository.existsByIdentifier(identifier)) {
            // Deliberately does not distinguish "a live tenant has it" from "a deleted tenant
            // had it": both mean the address is spent, permanently, and the caller's next
            // action is the same either way - pick another one.
            throw new BusinessRuleException(
                    "URL identifier '" + identifier + "' has already been claimed and can never be reused");
        }

        Tenant tenant = tenantRepository.save(
                new Tenant(request.name(), identifier, EntityStatus.ACTIVE));
        reservedIdentifierRepository.save(new ReservedTenantIdentifier(identifier, tenant.getId()));

        log.info("Tenant '{}' provisioned at identifier '{}' ({})",
                tenant.getName(), identifier, tenant.getId());
        return new TenantResponse(tenant.getId(), tenant.getName(), tenant.getUrlIdentifier());
    }
}
