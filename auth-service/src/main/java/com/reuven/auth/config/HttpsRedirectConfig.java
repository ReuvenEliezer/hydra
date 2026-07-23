package com.reuven.auth.config;

import org.apache.catalina.connector.Connector;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.tomcat.servlet.TomcatServletWebServerFactory;
import org.springframework.boot.web.server.WebServerFactoryCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Adds a second, plain-HTTP Tomcat connector that does nothing but 301-redirect to
 * the HTTPS connector configured via {@code server.ssl.*} / {@code server.port}.
 * <p>
 * Gated on {@code server.http-redirect.enabled} (NOT on a profile name) so the
 * behavior is explicit and never accidentally active in local/test runs, where
 * MockMvc/RestAssured talk plain HTTP and a forced redirect would break every test.
 * Set this property (and {@code server.ssl.enabled=true}) only for real deployments.
 * <p>
 * NOTE: Spring Boot 4 reorganized the embedded-server packages (servers now live under
 * dedicated boot-tomcat/boot-jetty modules instead of org.springframework.boot.web.embedded.*).
 * The two imports below are written against the Boot 4.1 reorganization as documented
 * at time of writing; this sandbox has no Maven access to verify against your exact
 * BOM, so if your resolved spring-boot-tomcat version uses slightly different package
 * names, fix just those two import lines.
 */
@Configuration
@ConditionalOnProperty(name = "server.http-redirect.enabled", havingValue = "true")
public class HttpsRedirectConfig {

    private final int httpPort;
    private final int httpsPort;

    public HttpsRedirectConfig(@Value("${server.http-redirect.port:8080}") int httpPort,
                               @Value("${server.port:8443}") int httpsPort){
        this.httpPort = httpPort;
        this.httpsPort= httpsPort;
    }

    @Bean
    public WebServerFactoryCustomizer<TomcatServletWebServerFactory> httpToHttpsRedirectCustomizer() {
        return factory -> {
            Connector httpConnector = new Connector(TomcatServletWebServerFactory.DEFAULT_PROTOCOL);
            httpConnector.setScheme("http");
            httpConnector.setPort(httpPort);
            httpConnector.setSecure(false);
            httpConnector.setRedirectPort(httpsPort);
            factory.addAdditionalConnectors(httpConnector);

            // setRedirectPort alone only tells Tomcat WHERE to send a request that needs
            // upgrading - this security-constraint is what actually forces every request
            // arriving on the plain HTTP connector to be upgraded (CONFIDENTIAL transport
            // guarantee triggers the 301 redirect to the HTTPS connector above).
            factory.addContextCustomizers(context -> {
                org.apache.tomcat.util.descriptor.web.SecurityCollection collection =
                        new org.apache.tomcat.util.descriptor.web.SecurityCollection();
                collection.addPattern("/*");
                org.apache.tomcat.util.descriptor.web.SecurityConstraint constraint =
                        new org.apache.tomcat.util.descriptor.web.SecurityConstraint();
                constraint.setUserConstraint("CONFIDENTIAL");
                constraint.addCollection(collection);
                context.addConstraint(constraint);
            });
        };
    }
}
