package com.reuven.integration.edge;

import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.wait.strategy.Wait;
import org.testcontainers.images.builder.Transferable;
import org.testcontainers.utility.DockerImageName;

import java.nio.charset.StandardCharsets;

/**
 * Two nginx stand-ins for the [transparent-edge contract](../../../../../../../../specs/002-cors-edge-hardening/contracts/transparent-edge-contract.md):
 * a correctly transparent one, which {@link TransparentEdgeConformanceTest} must pass against,
 * and a deliberately hostile one, which it must fail against (research R5).
 * <p>
 * nginx here is scaffolding, not an edge recommendation - it was picked because expressing both
 * "preserve Host" and "rewrite Host, inject headers" is a one-line configuration difference in
 * it. The suite itself takes a base URL and does not know what is serving it (spec Assumptions).
 * <p>
 * Both containers proxy to the upstream service running on the JVM host, reached via
 * {@code host.testcontainers.internal} - the caller must call
 * {@link org.testcontainers.Testcontainers#exposeHostPorts(int...)} for the upstream port before
 * starting either container.
 */
final class StandInProxies {

    private static final DockerImageName NGINX_IMAGE = DockerImageName.parse("nginx:1.27-alpine");
    private static final String CONF_PATH = "/etc/nginx/conf.d/default.conf";

    private StandInProxies() {
    }

    /** Preserves {@code Host} unmodified and adds no headers of its own. Must pass every clause. */
    static GenericContainer<?> transparent(int upstreamPort) {
        String conf = """
                server {
                    listen 80;
                    location / {
                        proxy_pass http://host.testcontainers.internal:%d;
                        proxy_set_header Host $http_host;
                    }
                }
                """.formatted(upstreamPort);
        return newContainer(conf);
    }

    /**
     * Rewrites {@code Host} to an upstream service name (Clause 1 violation) and injects its own
     * {@code Access-Control-Allow-Origin} (Clause 2 violation). Must fail those clauses - a suite
     * that cannot detect this cannot be trusted to detect a real broken edge (research R5).
     */
    static GenericContainer<?> hostile(int upstreamPort) {
        String conf = """
                server {
                    listen 80;
                    location / {
                        proxy_pass http://host.testcontainers.internal:%d;
                        proxy_set_header Host upstream-service;
                        add_header Access-Control-Allow-Origin '*' always;
                    }
                }
                """.formatted(upstreamPort);
        return newContainer(conf);
    }

    private static GenericContainer<?> newContainer(String conf) {
        return new GenericContainer<>(NGINX_IMAGE)
                .withExposedPorts(80)
                .withCopyToContainer(Transferable.of(conf.getBytes(StandardCharsets.UTF_8)), CONF_PATH)
                .waitingFor(Wait.forListeningPort());
    }
}
