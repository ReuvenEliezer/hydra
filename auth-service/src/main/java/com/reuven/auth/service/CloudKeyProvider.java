package com.reuven.auth.service;

import com.reuven.auth.exception.KeyProviderException;
import jakarta.annotation.PreDestroy;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Component;
import software.amazon.awssdk.services.secretsmanager.SecretsManagerClient;
import software.amazon.awssdk.services.secretsmanager.model.GetSecretValueRequest;
import software.amazon.awssdk.services.secretsmanager.model.SecretsManagerException;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.security.interfaces.RSAPrivateKey;

@Component
@Profile({"prod", "staging"})
public class CloudKeyProvider extends AbstractRsaKeyProvider {

    private final SecretsManagerClient secretsClient;

    @Autowired // explicit: there are two constructors here, don't leave Spring to guess
    public CloudKeyProvider(@Value("${jwt.secret-name}") String secretName) {
        this(SecretsManagerClient.create(), secretName);
    }

    // secretsClient is a constructor parameter here, not yet a field - so it's legal to
    // pass it into super(...) before `this` is fully initialized, then keep it afterwards
    // for the @PreDestroy shutdown below. An instance field could not have been read
    // before super() returns.
    private CloudKeyProvider(SecretsManagerClient secretsClient, String secretName) {
        super(loadPrivateKeyFromSecret(secretsClient, secretName));
        this.secretsClient = secretsClient;
    }

    private static RSAPrivateKey loadPrivateKeyFromSecret(SecretsManagerClient client, String secretName) {
        String pem;
        try {
            pem = client.getSecretValue(
                    GetSecretValueRequest.builder().secretId(secretName).build()
            ).secretString();
        } catch (SecretsManagerException e) {
            throw new KeyProviderException("Secrets Manager unavailable for secret: " + secretName, e);
        }
        return parsePkcs8PrivateKey(
                new ByteArrayInputStream(pem.getBytes(StandardCharsets.UTF_8)),
                "secret:" + secretName
        );
    }

    @PreDestroy
    public void shutdown() {
        secretsClient.close();
    }
}
