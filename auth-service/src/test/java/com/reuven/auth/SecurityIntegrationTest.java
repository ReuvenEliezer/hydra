package com.reuven.auth;

import com.reuven.auth.dto.CustomUserDetails;
import com.reuven.auth.dto.UserSecurity;
import com.reuven.auth.entity.EntityStatus;
import com.reuven.auth.entity.Tenant;
import com.reuven.auth.entity.User;
import com.reuven.auth.entity.UserRole;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.BadCredentialsException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

class SecurityIntegrationTest extends BaseIntegrationTest {

    private static final String PLAIN_PASSWORD = "ExampleSecurePassword123!";

    private UUID tenantId;

    @BeforeEach
    void setup() {
        super.setUp();
        String secureHash = passwordEncoder.encode(PLAIN_PASSWORD);
        System.out.println("secureHash: " + secureHash);
        // Deleting previous data to prevent duplicates in tests
        userRepository.deleteAll();
        tenantRepository.deleteAll(); // Important to also clean tenants
        // Creating valid tenant and user
        Tenant tenant = new Tenant();
        tenant.setName("Test Tenant");
        tenant.setStatus(EntityStatus.ACTIVE);
        tenant = tenantRepository.save(tenant); // Save the tenant and get the object with the ID
        tenantId = tenant.getId(); // Save the tenant ID for use in tests

        User user = new User();
        user.setUsername("test_admin");
        user.setTenant(tenant);
        user.addRole(UserRole.ADMIN);
        user.setStatus(EntityStatus.ACTIVE);
        user.setPasswordHash(passwordEncoder.encode(PLAIN_PASSWORD));

        User save = userRepository.save(user);
        assertNotNull(save);
    }

    @Test
    void testPasswordValidation() {
        User user = userRepository.findByTenantIdAndUsername(tenantId, "test_admin")
                .orElseThrow(() -> new BadCredentialsException("Invalid credentials"));
        String storedHash = user.getPasswordHash();

        // Here you know what the password is ("Password123!") and check against the Hash
        assertTrue(passwordEncoder.matches(PLAIN_PASSWORD, storedHash), "The password should match!");
    }

    @Test
    void shouldExtractTenantIdFromSecurityContext() {
        // 1. Fetch from DB
        User user = userRepository.findWithRolesByTenantIdAndUsername(tenantId, "test_admin")
                .orElseThrow(() -> new BadCredentialsException("Invalid credentials"));

        // 2. Convert to CustomUserDetails
        CustomUserDetails customUserDetails = CustomUserDetails.fromEntity(user);

        // 3. Creating the Authentication correctly (the Constructor that includes authorities)
        // Once you pass a non-empty authorities list, the Token is automatically set as authenticated (trusted)
        UsernamePasswordAuthenticationToken auth = new UsernamePasswordAuthenticationToken(
                customUserDetails,
                null,
                customUserDetails.getAuthorities() // Ensure this is not null
        );

        // No need for auth.setAuthenticated(true) - it already happens in the Constructor
        SecurityContextHolder.getContext().setAuthentication(auth);

        // 4. Executing the method and comparing
        UUID extractedTenantId = CustomUserDetails.getCurrentTenantId();

        assertNotNull(extractedTenantId);
        assertEquals(user.getTenant().getId(), extractedTenantId);
    }
}