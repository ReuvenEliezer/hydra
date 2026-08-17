package com.reuven.auth.service;

import java.security.interfaces.RSAPrivateKey;
import java.security.interfaces.RSAPublicKey;

public interface KeyProvider {
    RSAPrivateKey getPrivateKey();
    RSAPublicKey getPublicKey(); // the concrete implementation already knows how to derive this, once
}
