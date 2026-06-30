package com.reuven.auth.service;

import com.reuven.auth.exception.KeyProviderException;
import lombok.extern.slf4j.Slf4j;
import org.springframework.core.io.FileSystemResource;
import org.springframework.core.io.Resource;
import org.springframework.security.converter.RsaKeyConverters;

import java.io.IOException;
import java.io.InputStream;
import java.security.GeneralSecurityException;
import java.security.KeyFactory;
import java.security.interfaces.RSAPrivateCrtKey;
import java.security.interfaces.RSAPrivateKey;
import java.security.interfaces.RSAPublicKey;
import java.security.spec.RSAPublicKeySpec;

/**
 * Single source of truth: every implementation supplies only a private key.
 * The public key is always derived from it here - never loaded from a separate
 * file/secret - so the two halves of the key pair can never drift out of sync
 * (e.g. rotating the private key without remembering to update a sibling public
 * key file).
 */
@Slf4j
abstract class AbstractRsaKeyProvider implements KeyProvider {

    private final RSAPrivateKey privateKey;
    private final RSAPublicKey publicKey;

    protected AbstractRsaKeyProvider(RSAPrivateKey privateKey) {
        this.privateKey = privateKey;
        this.publicKey = derivePublicKey(privateKey);
    }

    @Override
    public RSAPrivateKey getPrivateKey() {
        return privateKey;
    }

    @Override
    public RSAPublicKey getPublicKey() {
        return publicKey;
    }

    /**
     * RSA private keys decoded from a standard PKCS#8 encoding (via RsaKeyConverters,
     * or via java.security.KeyFactory directly, as used for the Secrets Manager path)
     * always come back as RSAPrivateCrtKey - the ASN.1 structure for an RSA private key
     * includes the full CRT parameters (n, e, d, p, q, dp, dq, qInv), and Sun's RSA
     * KeyFactory always populates them. This only breaks for a future KMS-style
     * provider that never exposes private key material to the JVM at all - in that
     * case the whole signing abstraction needs to change (remote sign vs. local
     * RSASSASigner), not just this cast - see ARCHITECTURE.md.
     */
    private static RSAPublicKey derivePublicKey(RSAPrivateKey privateKey) {
        if (!(privateKey instanceof RSAPrivateCrtKey crtKey)) {
            throw new KeyProviderException(
                    "Private key does not expose RSA CRT parameters; cannot derive the " +
                    "public key locally. This is expected if the key originates from a " +
                    "provider that never hands JVM-side private key material (e.g. AWS KMS) - " +
                    "such a provider needs its own signing abstraction, not AbstractRsaKeyProvider.");
        }
        try {
            KeyFactory keyFactory = KeyFactory.getInstance("RSA");
            return (RSAPublicKey) keyFactory.generatePublic(
                    new RSAPublicKeySpec(crtKey.getModulus(), crtKey.getPublicExponent()));
        } catch (GeneralSecurityException e) {
            throw new KeyProviderException("Failed to derive RSA public key from private key", e);
        }
    }

    // --- shared private-key parsing - every child works against an InputStream,
    //     regardless of whether it came from a file or a secret manager response ---

    protected static RSAPrivateKey parsePkcs8PrivateKey(InputStream pem, String sourceDescription) {
        try {
            return RsaKeyConverters.pkcs8().convert(pem);
        } catch (Exception e) {
            log.error("Could not parse private key from: {}", sourceDescription, e);
            throw new KeyProviderException("Could not parse private key from: " + sourceDescription, e);
        }
    }

    protected static RSAPrivateKey loadPrivateKeyFromPath(String path) {
        Resource resource = new FileSystemResource(path);
        try {
            log.info("Loading key from: {}", resource.getFile().getAbsolutePath());
            log.info("Exists: {}", resource.exists());

            return parsePkcs8PrivateKey(resource.getInputStream(), resource.getDescription());
        } catch (IOException e) {
            throw new KeyProviderException("Could not read private key resource: " + resource.getDescription(), e);
        }
    }

}
