package com.reuven.auth.service;

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

    private final UserRepository userRepository;
    private final TenantRepository tenantRepository;
    private final PasswordEncoder passwordEncoder;
    private final String superAdminPassword;

    public BootstrapService(
            UserRepository userRepository,
            TenantRepository tenantRepository,
            PasswordEncoder passwordEncoder,
            @Value("${app.bootstrap.super-admin-password}") String superAdminPassword) {

        this.userRepository = userRepository;
        this.tenantRepository = tenantRepository;
        this.passwordEncoder = passwordEncoder;
        this.superAdminPassword = superAdminPassword;
    }

    @Override
    @Transactional
    public void onApplicationEvent(ApplicationReadyEvent event) {
        if (userRepository.count() == 0) {
            log.info("Bootstrapping system: creating super admin...");

            // 1. Creating a system tenant for the SUPER_ADMIN
            Tenant systemTenant = new Tenant("System Tenant", EntityStatus.ACTIVE);
            tenantRepository.save(systemTenant);

            // 2. Creating a SUPER_ADMIN with a pre-computed hash
            // The hash below is for the password "admin123" (for example)
            // I created it once - we will never see the plain text password in the code.
            String precomputedHash = passwordEncoder.encode(superAdminPassword);

            User superAdmin = new User(
                    systemTenant,
                    "super-admin",
                    precomputedHash, // Using the hash directly!
                    UserRole.SUPER_ADMIN,
                    EntityStatus.ACTIVE
            );

            userRepository.save(superAdmin);
            log.info("Super Admin 'super-admin' created.");
        }
    }
}