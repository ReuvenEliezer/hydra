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
import com.reuven.auth.dto.CustomUserDetails;
import com.reuven.auth.entity.User;
import com.reuven.auth.exception.InvalidTokenException;
import com.reuven.auth.exception.TokenGenerationException;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.stereotype.Service;

import java.security.Principal;
import java.security.interfaces.RSAPrivateKey;
import java.text.ParseException;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.Date;
import java.util.Set;
import java.util.UUID;

@Slf4j
@Service
public class JwtProvider {

    private static final JWSAlgorithm SIGNING_ALGORITHM = JWSAlgorithm.RS256;
    private static final long CLOCK_SKEW_SECONDS = 30;

    private final Clock clock; // Clock.systemUTC() in prod (see GeneralConfig); Clock.fixed(...) in tests
    private final String issuer;
    private final Duration tokenValidityDuration;
    private final RSAPrivateKey privateKey;
    private final String keyId;
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
                Set.of("sub", "exp", "iat", "tenantId")
        );
        claimsVerifier.setMaxClockSkew((int) CLOCK_SKEW_SECONDS);
        this.jwtProcessor.setJWTClaimsSetVerifier(claimsVerifier);
    }

    public String generateToken(User user) {
        Instant nowInstant = clock.instant();
        Date now = Date.from(nowInstant);
        Date exp = Date.from(nowInstant.plus(tokenValidityDuration));

        JWTClaimsSet claims = new JWTClaimsSet.Builder()
                .subject(user.getId().toString())
                .claim("roles", user.getRoles().stream()
                        .map(r -> "ROLE_" + r.name())
                        .toList())
                .claim("tenantId", user.getTenant().getId().toString())
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
            log.error("JWT signing failed for user {}", user.getId(), e);
            throw new TokenGenerationException("Failed to sign JWT", e);
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

    public String extractSubject(String token) {
        return validateAndExtractClaims(token).getSubject();
    }

    public String extractTenantId(String token) throws ParseException {
        return validateAndExtractClaims(token).getStringClaim("tenantId");
    }

    public UUID getTenantIdFromToken(Principal principal) {
        if (principal instanceof UsernamePasswordAuthenticationToken auth
                && auth.getPrincipal() instanceof CustomUserDetails userDetails) {
            return userDetails.getTenantId();
        }
        log.error("Invalid principal type");
        throw new IllegalStateException("Principal is not of type CustomUserDetails");
    }

    public RSAKey getPublicJwk() {
        return publicJwk;
    }
}
