package com.reuven.auth.service;

import com.reuven.Role;
import com.reuven.auth.entity.*;
import com.reuven.auth.repository.*;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.ApplicationListener;
import org.springframework.context.annotation.Profile;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

@Slf4j
@Component
//@Profile("!prod")
@Profile({"local"})
public class BootstrapService implements ApplicationListener<ApplicationReadyEvent> {

    /** The System Tenant's sign-in address: {@code system.<base-domain>}. */
    static final String SYSTEM_TENANT_IDENTIFIER = "system";

    private final UserRepository userRepository;
    private final TenantRepository tenantRepository;
    private final ReservedTenantIdentifierRepository reservedTenantIdentifierRepository;
    private final PasswordEncoder passwordEncoder;
    private final String superAdminPassword;

    public BootstrapService(
            UserRepository userRepository,
            TenantRepository tenantRepository,
            ReservedTenantIdentifierRepository reservedTenantIdentifierRepository,
            PasswordEncoder passwordEncoder,
            @Value("${app.bootstrap.super-admin-password}") String superAdminPassword) {

        this.userRepository = userRepository;
        this.tenantRepository = tenantRepository;
        this.reservedTenantIdentifierRepository = reservedTenantIdentifierRepository;
        this.passwordEncoder = passwordEncoder;
        this.superAdminPassword = superAdminPassword;
    }

    @Override
    @Transactional
    public void onApplicationEvent(ApplicationReadyEvent event) {
        if (userRepository.count() == 0) {
            log.info("Bootstrapping system: creating super admin...");

            // 1. Creating a system tenant for the SUPER_ADMIN.
            // Its identifier makes the super admin sign in at http://system.localhost:5173 like
            // every other account - resolution is strictly per-address and is never bypassed by
            // role (FR-010). The reservation row is written in this same transaction, so "system"
            // can never later be handed to a real tenant; claiming it through the ledger rather
            // than through hydra.tenant.reserved-identifiers keeps that config list meaning
            // purely "words an operator may not choose".
            Tenant systemTenant = new Tenant("System Tenant", SYSTEM_TENANT_IDENTIFIER, EntityStatus.ACTIVE);
            tenantRepository.save(systemTenant);
            reservedTenantIdentifierRepository.save(
                    new ReservedTenantIdentifier(SYSTEM_TENANT_IDENTIFIER, systemTenant.getId()));

            // 2. Creating a SUPER_ADMIN with a pre-computed hash
            // The hash below is for the password "admin123" (for example)
            // I created it once - we will never see the plain text password in the code.
            String precomputedHash = passwordEncoder.encode(superAdminPassword);

            User superAdmin = new User(
                    systemTenant,
                    "super-admin",
                    precomputedHash, // Using the hash directly!
                    Role.SUPER_ADMIN,
                    EntityStatus.ACTIVE
            );

            userRepository.save(superAdmin);
            log.info("Super Admin 'super-admin' created.");
        }
    }
}