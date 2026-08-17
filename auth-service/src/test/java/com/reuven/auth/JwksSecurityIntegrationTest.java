package com.reuven.auth;

import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.crypto.RSASSAVerifier;
import com.nimbusds.jose.jwk.JWK;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import com.reuven.JwtClaimNames;
import com.reuven.Role;
import com.reuven.auth.entity.EntityStatus;
import com.reuven.auth.entity.Tenant;
import com.reuven.auth.entity.User;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MvcResult;

import java.security.KeyPairGenerator;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Extends BaseIntegrationTest to reuse its Testcontainers Postgres instance and
 * jwt.private-key/jwt.issuer wiring, rather than duplicating that setup here.
 */
class JwksSecurityIntegrationTest extends BaseIntegrationTest {

    private User user;

    @BeforeEach
    protected void setUp() throws Exception {
        super.setUp();
        // BaseIntegrationTest.setUp() already ran and gave us a clean DB plus
        // superAdmin/testTenant - we just add one more user specific to this test class.
        // A distinct identifier from BaseIntegrationTest's fixtures - url_identifier is unique.
        Tenant tenant = new Tenant("JWKS Test Tenant", "jwks", EntityStatus.ACTIVE);
        tenant = tenantRepository.save(tenant);

        user = new User();
        user.setUsername("test_admin");
        user.setTenant(tenant);
        user.addRole(Role.ADMIN);
        user.setStatus(EntityStatus.ACTIVE);
        user.setPasswordHash(passwordEncoder.encode("ExampleSecurePassword123!"));
        userRepository.save(user);
    }

    @Test
    void jwksEndpointShouldMatchGeneratedToken() throws Exception {
        String token = jwtProvider.generateToken(user);
        SignedJWT signedJWT = SignedJWT.parse(token);

        MvcResult result = mockMvc.perform(get("/.well-known/jwks.json")
                        .accept(MediaType.APPLICATION_JSON))
                .andExpect(status().isOk())
                .andReturn();

        String jwksJson = result.getResponse().getContentAsString();
        JWKSet jwkSet = JWKSet.parse(jwksJson);

        String kid = signedJWT.getHeader().getKeyID();
        RSAKey rsaKey = (RSAKey) jwkSet.getKeyByKeyId(kid);

        assertNotNull(rsaKey, "Public key not found for kid: " + kid);
        assertTrue(signedJWT.verify(new RSASSAVerifier(rsaKey)),
                "Signature verification failed");
    }

    @Test
    void tokenShouldContainCorrectClaims() throws Exception {
        String token = jwtProvider.generateToken(userRepository.findWithRolesByTenantIdAndUsername(user.getTenant().getId(), user.getUsername()).get());
        SignedJWT signedJWT = SignedJWT.parse(token);
        JWTClaimsSet claims = signedJWT.getJWTClaimsSet();

        assertEquals(user.getTenant().getId().toString(), claims.getClaim(JwtClaimNames.TENANT_ID), "Tenant ID mismatch");

        // Instead of comparing a single string, we compare the list of roles
        List<String> rolesFromToken = (List<String>) claims.getClaim(JwtClaimNames.ROLES);

        List<String> expectedRoles = userRepository.findWithRolesById(user.getId()).get().getRoles().stream()
                .map(Role::authority)
                .toList();

        assertEquals(expectedRoles.size(), rolesFromToken.size(), "Number of roles mismatch");
        assertTrue(rolesFromToken.containsAll(expectedRoles), "Roles in token do not match user roles");
        assertEquals(user.getId().toString(), claims.getSubject(), "Subject should be the user ID");
    }

    @Test
    void shouldRejectTokenSignedWithUnknownKey() throws Exception {
        // 1. Generate a completely unrelated key pair (not ours).
        KeyPairGenerator keyGen = KeyPairGenerator.getInstance("RSA");
        keyGen.initialize(2048);
        var wrongKeyPair = keyGen.generateKeyPair();

        // 2. Sign a token with that foreign key.
        JWSHeader header = new JWSHeader.Builder(JWSAlgorithm.RS256)
                .keyID("attacker-key")
                .build();
        JWTClaimsSet claims = new JWTClaimsSet.Builder().subject("hacker").build();
        SignedJWT signedJWT = new SignedJWT(header, claims);
        signedJWT.sign(new RSASSASigner(wrongKeyPair.getPrivate()));

        // 3. Fetch our real JWKS.
        MvcResult result = mockMvc.perform(get("/.well-known/jwks.json")).andReturn();
        JWKSet jwkSet = JWKSet.parse(result.getResponse().getContentAsString());

        // 4. The forged token must NOT verify against any of our legitimate keys.
        boolean isVerified = false;
        for (JWK key : jwkSet.getKeys()) {
            if (signedJWT.verify(new RSASSAVerifier((RSAKey) key))) {
                isVerified = true;
            }
        }

        assertFalse(isVerified, "The system should have rejected the token signed with an unknown key!");
    }
}