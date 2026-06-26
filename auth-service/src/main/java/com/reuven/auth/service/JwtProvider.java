package com.reuven.auth.service;

import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.JWSVerifier;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.crypto.RSASSAVerifier;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import com.reuven.auth.dto.CustomUserDetails;
import com.reuven.auth.entity.User;
import lombok.Getter;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.stereotype.Service;

import java.security.KeyFactory;
import java.security.Principal;
import java.security.interfaces.RSAPrivateCrtKey;
import java.security.interfaces.RSAPrivateKey;
import java.security.interfaces.RSAPublicKey;
import java.security.spec.PKCS8EncodedKeySpec;
import java.security.spec.RSAPublicKeySpec;
import java.text.ParseException;
import java.time.Duration;
import java.util.Base64;
import java.util.Date;
import java.util.UUID;

@Slf4j
@Service
public class JwtProvider {

    private final String issuer;
    private final Duration tokenValidityDuration;
    private final RSAPrivateKey privateKey;
    @Getter
    private final RSAPublicKey publicKey;
    @Getter
    private final RSAKey publicJwk;

    public JwtProvider(
            @Value("${jwt.private-key}") String privateKeyContent,
            @Value("${jwt.issuer:hydra-auth-service}") String issuer,
            @Value("${jwt.key-id:hydra-auth-key-1}") String keyId,
            @Value("${jwt.expiration-duration:PT1H}") Duration tokenValidityDuration) throws Exception {

        this.issuer = issuer;
        this.tokenValidityDuration = tokenValidityDuration;

        String pem = privateKeyContent
                .replace("-----BEGIN PRIVATE KEY-----", "")
                .replace("-----END PRIVATE KEY-----", "")
                .replaceAll("[\\r\\n\\s]+", "");

        byte[] encoded = Base64.getDecoder().decode(pem);
        KeyFactory kf = KeyFactory.getInstance("RSA");

        this.privateKey = (RSAPrivateKey) kf.generatePrivate(new PKCS8EncodedKeySpec(encoded));

        RSAPrivateCrtKey crtKey = (RSAPrivateCrtKey) this.privateKey;
        this.publicKey = (RSAPublicKey) kf.generatePublic(
                new RSAPublicKeySpec(crtKey.getModulus(), crtKey.getPublicExponent())
        );

        this.publicJwk = new RSAKey.Builder(this.publicKey)
                .keyID(keyId)
                .build();
    }

    public String generateToken(User user, Date expirationTime) {
        try {
            Date now = new Date();
            JWTClaimsSet claims = new JWTClaimsSet.Builder()
                    .subject(user.getId().toString())
                    .claim("roles", user.getRoles().stream()
                            .map(role -> "ROLE_" + role.name())
                            .toList())
                    .claim("tenantId", user.getTenant().getId().toString())
                    .issuer(this.issuer)
                    .issueTime(now)
                    .expirationTime(expirationTime)
                    .jwtID(UUID.randomUUID().toString())
                    .build();

            SignedJWT jwt = new SignedJWT(
                    new JWSHeader.Builder(JWSAlgorithm.RS256)
                            .keyID(publicJwk.getKeyID())
                            .build(),
                    claims
            );
            jwt.sign(new RSASSASigner(privateKey));
            return jwt.serialize();
        } catch (Exception e) {
            throw new RuntimeException("Error signing token", e);
        }
    }

    public String generateToken(User user) {
        Date now = new Date();
        return generateToken(user, new Date(now.getTime() + tokenValidityDuration.toMillis()));
    }

    public JWTClaimsSet validateAndExtractClaims(String token) {
        try {
            SignedJWT jwt = SignedJWT.parse(token);
            JWSVerifier verifier = new RSASSAVerifier(publicKey);

            if (!jwt.verify(verifier)) {
                log.error("Invalid token");
                throw new SecurityException("Invalid token signature");
            }

            JWTClaimsSet claims = jwt.getJWTClaimsSet();

            if (claims.getExpirationTime() == null || claims.getExpirationTime().before(new Date())) {
                throw new SecurityException("Token has expired");
            }

            if (!this.issuer.equals(claims.getIssuer())) {
                log.error("Token issuer mismatch: expected '{}', got '{}'", this.issuer, claims.getIssuer());
                throw new SecurityException("Invalid token issuer");
            }

            return claims;
        } catch (SecurityException e) {
            log.error("Invalid token signature", e);
            throw e;
        } catch (Exception e) {
            log.error("Invalid token signature", e);
            throw new SecurityException("Token validation failed: " + e.getMessage());
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
}