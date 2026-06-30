package com.reuven.auth.service;

import java.security.interfaces.RSAPrivateKey;
import java.security.interfaces.RSAPublicKey;

public interface KeyProvider {
    RSAPrivateKey getPrivateKey();
    RSAPublicKey getPublicKey(); // המימוש הקונקרטי כבר יודע לגזור את זה, פעם אחת
}
