package com.reuven.auth.service;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Component;

@Component
// "test" added deliberately: BaseIntegrationTest activates the "test" profile, and
// needs a real KeyProvider bean too - it's the same file-based loading as local dev,
// just pointed at a fixture key instead of a real dev key. Without this, no KeyProvider
// bean exists under "test" at all and every integration test fails at context startup.
@Profile({"local", "test"})
public class LocalKeyProvider extends AbstractRsaKeyProvider {

    public LocalKeyProvider(@Value("${jwt.private-key-path}") String privateKeyPath) {
        super(loadPrivateKeyFromPath(privateKeyPath));
    }
}
