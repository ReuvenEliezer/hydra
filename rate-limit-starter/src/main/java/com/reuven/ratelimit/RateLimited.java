package com.reuven.ratelimit;

import java.lang.annotation.ElementType;
import java.lang.annotation.Repeatable;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * Declares one rate-limit dimension on a controller method. Pure declaration -
 * carries no knowledge of Bucket4j, Redis, or any other backend; {@link RateLimiterAspect}
 * only knows how to read it and {@link RateLimiterEngine} only knows how to enforce it.
 *
 * <p>{@code @Repeatable} so one endpoint can be gated on several independent dimensions
 * (e.g. per-IP AND per-username) - stack the annotation, no {@code .List} wrapper needed
 * at the call site. Each dimension is enforced against its own bucket, so exhausting one
 * never affects another.
 *
 * <p>Onboarding a new protected endpoint anywhere in the system is: add
 * {@code @RateLimited} to the method, add a matching {@code rate-limit.limits.<name>}
 * entry to that service's own application.yaml. No changes to this package.
 *
 * @see RateLimiterAspect
 */
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
@Repeatable(RateLimited.List.class)
public @interface RateLimited {

    /**
     * Key into the owning service's {@code rate-limit.limits.*} config map - selects
     * which capacity/window applies. Deliberately a plain lookup key, not a nested
     * config path, so each service's {@code RateLimiterEngine} owns its own config shape.
     */
    String limit();

    /**
     * SpEL, evaluated against the annotated method's parameters (by their real parameter
     * names, e.g. {@code #request.username()}) plus a standardized {@code #httpRequest}
     * alias bound to whichever parameter is a {@code HttpServletRequest}, regardless of
     * its declared parameter name. Must evaluate to a non-null identifier.
     */
    String key();

    /** Container required by {@code @Repeatable} - not referenced directly at call sites. */
    @Target(ElementType.METHOD)
    @Retention(RetentionPolicy.RUNTIME)
    @interface List {
        RateLimited[] value();
    }
}
