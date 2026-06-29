package com.reuven.auth.controller;

import com.nimbusds.jose.jwk.JWKSet;
import com.reuven.auth.service.JwtProvider;
import lombok.RequiredArgsConstructor;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.Duration;
import java.util.Map;


@RestController
@RequestMapping("/.well-known")
@RequiredArgsConstructor
public class JwksController {

    private final JwtProvider jwtProvider;

    @GetMapping("/jwks.json")
    public ResponseEntity<Map<String, Object>> getJwks() {
        JWKSet jwkSet = new JWKSet(jwtProvider.getPublicJwk());
        return ResponseEntity.ok()
                .cacheControl(CacheControl.maxAge(Duration.ofMinutes(15)).cachePublic()) //TODO move to yaml
                .body(jwkSet.toJSONObject()); // includes public key only, never private
    }
}