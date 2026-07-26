package com.reuven.ratelimit;

import io.github.bucket4j.distributed.proxy.ProxyManager;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.data.redis.autoconfigure.DataRedisAutoConfiguration;
import org.springframework.context.annotation.Bean;

/**
 * Single activation point for the whole rate-limiting stack - discovered automatically
 * via {@code META-INF/spring/...AutoConfiguration.imports}, so no
 * {@code @ComponentScan(basePackages = "com.reuven")} is needed in any service's
 * {@code @SpringBootApplication} class. Onboarding a new service is: depend on this
 * module, expose a {@code RedisConnectionFactory} bean, add a
 * {@code rate-limit.limits.*} YAML block, annotate a controller method with
 * {@code @RateLimited}. Nothing here changes.
 *
 * <p>Layered opt-in, each layer gated on the previous one actually being present:
 * <ol>
 *   <li>{@code rate-limit.enabled=false} - this entire class is skipped (condition
 *   evaluated before {@code @Import} or any {@code @Bean} method is even parsed), so a
 *   service can hard-disable rate limiting with one property, including the Redis
 *   connection {@link RateLimitRedisAutoConfiguration} would otherwise open.</li>
 *   <li>A {@code RedisConnectionFactory} bean present - {@link RateLimitRedisAutoConfiguration}
 *   activates and the default {@link Bucket4jRateLimiterEngine} is registered.</li>
 *   <li>Any {@link RateLimiterEngine} bean present (the default one, or a service's
 *   own override - e.g. in-memory for a slice test) - {@link RateLimiterAspect} and
 *   {@link RateLimitExceptionHandler} activate.</li>
 * </ol>
 * A service with none of the prerequisites (order-service, today) pulls in this jar
 * with zero runtime effect - onboarding is additive, never a breaking change.
 */
@AutoConfiguration(after = {
        DataRedisAutoConfiguration.class,
        RateLimitRedisAutoConfiguration.class
})
@EnableConfigurationProperties(RateLimitProperties.class)
public class RateLimitAutoConfiguration {

    @Bean
    @ConditionalOnBean(ProxyManager.class)
    @ConditionalOnProperty(
            prefix = "rate-limit",
            name = "enabled",
            havingValue = "true",
            matchIfMissing = true
    )
    @ConditionalOnMissingBean(RateLimiterEngine.class)
    public RateLimiterEngine bucket4jRateLimiterEngine(
            ProxyManager<byte[]> proxyManager,
            RateLimitProperties properties,
            MeterRegistry meterRegistry) {

        return new Bucket4jRateLimiterEngine(proxyManager, properties, meterRegistry);
    }

    @Bean
    @ConditionalOnProperty(
            prefix = "rate-limit",
            name = "enabled",
            havingValue = "false"
    )
    @ConditionalOnMissingBean(RateLimiterEngine.class)
    public RateLimiterEngine noOpRateLimiterEngine() {
        return new NoOpRateLimiterEngine();
    }

    @Bean
    @ConditionalOnBean(RateLimiterEngine.class)
    @ConditionalOnMissingBean
    public RateLimiterAspect rateLimiterAspect(RateLimiterEngine engine) {
        return new RateLimiterAspect(engine);
    }

    @Bean
    @ConditionalOnBean(RateLimiterEngine.class)
    @ConditionalOnMissingBean
    public RateLimitExceptionHandler rateLimitExceptionHandler() {
        return new RateLimitExceptionHandler();
    }
}
