package com.reuven.auth.service;

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.source.ImmutableJWKSet;
import com.nimbusds.jose.proc.BadJOSEException;
import com.nimbusds.jose.proc.JWSKeySelector;
import com.nimbusds.jose.proc.JWSVerificationKeySelector;
import com.nimbusds.jose.proc.SecurityContext;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import com.nimbusds.jwt.proc.ConfigurableJWTProcessor;
import com.nimbusds.jwt.proc.DefaultJWTClaimsVerifier;
import com.nimbusds.jwt.proc.DefaultJWTProcessor;
import com.reuven.Role;
import com.reuven.JwtClaimNames;
import com.reuven.auth.exception.InvalidTokenException;
import com.reuven.auth.exception.TokenGenerationException;
import lombok.Getter;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.security.interfaces.RSAPrivateKey;
import java.text.ParseException;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.Date;
import java.util.List;
import java.util.Set;
import java.util.UUID;

@Slf4j
@Service
public class JwtProvider {

    private static final JWSAlgorithm SIGNING_ALGORITHM = JWSAlgorithm.RS256;
    private static final int CLOCK_SKEW_SECONDS = 30;

    private final Clock clock;
    private final String issuer;
    private final Duration tokenValidityDuration;
    private final RSAPrivateKey privateKey;
    private final String keyId;
    @Getter
    private final RSAKey publicJwk;
    private final ConfigurableJWTProcessor<SecurityContext> jwtProcessor;

    public JwtProvider(
            KeyProvider keyProvider,
            Clock clock,
            @Value("${jwt.issuer:hydra-auth-service}") String issuer,
            @Value("${jwt.key-id:hydra-auth-key-1}") String keyId,
            @Value("${jwt.expiration-duration:PT1H}") Duration tokenValidityDuration) {

        this.clock = clock;
        this.issuer = issuer;
        this.tokenValidityDuration = tokenValidityDuration;
        this.keyId = keyId;
        this.privateKey = keyProvider.getPrivateKey();

        this.publicJwk = new RSAKey.Builder(keyProvider.getPublicKey())
                .keyID(keyId)
                .build();

        this.jwtProcessor = new DefaultJWTProcessor<>();

        // Explicit algorithm binding against the public JWK -> prevents algorithm confusion attacks
        JWSKeySelector<SecurityContext> keySelector = new JWSVerificationKeySelector<>(
                SIGNING_ALGORITHM,
                new ImmutableJWKSet<>(new JWKSet(publicJwk))
        );
        this.jwtProcessor.setJWSKeySelector(keySelector);

        DefaultJWTClaimsVerifier<SecurityContext> claimsVerifier = new DefaultJWTClaimsVerifier<>(
                new JWTClaimsSet.Builder().issuer(issuer).build(),
                Set.of("sub", "exp", "iat", JwtClaimNames.TENANT_ID)
        );
        claimsVerifier.setMaxClockSkew(CLOCK_SKEW_SECONDS);
        this.jwtProcessor.setJWTClaimsSetVerifier(claimsVerifier);
    }

    public String generateToken(com.reuven.auth.entity.User user) {
        List<Role> roles = List.copyOf(user.getRoles());
        return generateToken(user.getId(), user.getTenant().getId(), roles);
    }

    /**
     * Mints an access token directly from claims — no DB round-trip.
     * Used by the refresh flow, where userId/tenantId/roles come from the Redis-backed
     * refresh token's status-tagged slot.
     */
    public String generateToken(UUID userId, UUID tenantId, List<Role> roles) {
        Instant nowInstant = clock.instant();
        Date now = Date.from(nowInstant);
        Date exp = Date.from(nowInstant.plus(tokenValidityDuration));

        JWTClaimsSet claims = new JWTClaimsSet.Builder()
                .subject(userId.toString())
                .claim(JwtClaimNames.ROLES, roles.stream().map(Role::authority).toList())
                .claim(JwtClaimNames.TENANT_ID, tenantId.toString())
                .issuer(issuer)
                .issueTime(now)
                .expirationTime(exp)
                .jwtID(UUID.randomUUID().toString())
                .build();

        try {
            SignedJWT jwt = new SignedJWT(
                    new JWSHeader.Builder(SIGNING_ALGORITHM).keyID(keyId).build(),
                    claims
            );
            jwt.sign(new RSASSASigner(privateKey));
            return jwt.serialize();
        } catch (JOSEException e) {
            log.error("JWT signing failed for user {}", userId, e);
            throw new TokenGenerationException("Failed to sign JWT", e);
        }
    }

    /**
     * Validates the token (signature, expiry, issuer, required claims) and extracts
     * typed claims into a {@link TokenClaims} record.
     * <p>
     * This is the single entry point for the JWT filter — keeps nimbus types
     * out of the web/dto layer and avoids a DB call on every request.
     */
    public TokenClaims extractTokenClaims(String token) {
        JWTClaimsSet raw = validateAndExtractClaims(token);
        try {
            UUID userId   = UUID.fromString(raw.getSubject());
            UUID tenantId = UUID.fromString(raw.getStringClaim(JwtClaimNames.TENANT_ID));
            List<String> roleAuthorities = raw.getStringListClaim(JwtClaimNames.ROLES);
            List<Role> roles = roleAuthorities == null
                    ? List.of()
                    : roleAuthorities.stream().map(Role::fromAuthority).toList();
            return new TokenClaims(userId, tenantId, roles);
        } catch (ParseException e) {
            throw new InvalidTokenException("Invalid token claims structure", e);
        } catch (IllegalArgumentException e) {
            throw new InvalidTokenException("Token contains an unrecognized role", e);
        }
    }

    public JWTClaimsSet validateAndExtractClaims(String token) {
        try {
            return jwtProcessor.process(token, null);
        } catch (ParseException e) {
            throw new InvalidTokenException("Malformed JWT", e);
        } catch (BadJOSEException e) {
            throw new InvalidTokenException("Token rejected: " + e.getMessage(), e);
        } catch (JOSEException e) {
            log.error("Unexpected JOSE processing error", e);
            throw new InvalidTokenException("Token validation failed", e);
        }
    }

    /** Convenience accessor — prefer {@link #extractTokenClaims} on the hot path. */
    public String extractSubject(String token) {
        return validateAndExtractClaims(token).getSubject();
    }

    public String extractTenantId(String token) {
        try {
            return validateAndExtractClaims(token).getStringClaim(JwtClaimNames.TENANT_ID);
        } catch (ParseException e) {
            throw new InvalidTokenException("Invalid tenantId claim", e);
        }
    }

}
