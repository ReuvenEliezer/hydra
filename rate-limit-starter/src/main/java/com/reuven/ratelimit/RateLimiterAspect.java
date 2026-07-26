package com.reuven.ratelimit;

import jakarta.servlet.http.HttpServletRequest;
import lombok.RequiredArgsConstructor;
import org.aspectj.lang.JoinPoint;
import org.aspectj.lang.annotation.Aspect;
import org.aspectj.lang.annotation.Before;
import org.aspectj.lang.reflect.MethodSignature;
import org.springframework.core.DefaultParameterNameDiscoverer;
import org.springframework.core.ParameterNameDiscoverer;
import org.springframework.expression.EvaluationContext;
import org.springframework.expression.Expression;
import org.springframework.expression.ExpressionParser;
import org.springframework.expression.spel.standard.SpelExpressionParser;
import org.springframework.expression.spel.support.StandardEvaluationContext;

import java.lang.reflect.Method;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Pure infrastructure: knows nothing about which endpoints exist or what they protect.
 * For every {@code @RateLimited} on the intercepted method, evaluates its {@code key()}
 * SpEL against the method's arguments and hands {@code (limit(), identifier)} to whatever
 * {@link RateLimiterEngine} the owning service wired up.
 *
 * <p><b>Ordering / fail-fast semantics:</b> dimensions are checked in declaration order and
 * the first exhausted one throws immediately - later dimensions on the same method are never
 * evaluated for that request (mirrors the sequential {@code checkX(); checkY();} style this
 * replaced). If a request should be scored against every dimension regardless of earlier
 * failures, that's a deliberate behavior change to make explicitly, not a side effect of
 * refactoring this aspect - so it isn't done implicitly here.
 *
 * <p><b>Runs as {@code @Before}, not {@code @Around}:</b> this is a pure gate. Throwing
 * from {@code @Before} advice already prevents the join point (and therefore the controller
 * body, and everything the service layer would otherwise do) from executing - there's
 * nothing an {@code @Around} advice would add here, only the overhead/complexity of manual
 * {@code proceed()} control.
 */
@Aspect
@RequiredArgsConstructor
public class RateLimiterAspect {

    private static final ParameterNameDiscoverer PARAMETER_NAMES = new DefaultParameterNameDiscoverer();
    private static final ExpressionParser PARSER = new SpelExpressionParser();

    private final RateLimiterEngine engine;

    /**
     * Parsing a SpEL string is a real per-request CPU cost (tokenizing + AST allocation).
     * Expressions are static per annotation instance, so parse once per distinct source
     * string and cache the compiled {@link Expression} for the process lifetime - unbounded
     * is fine here since the key set is bounded by the number of {@code @RateLimited}
     * annotations actually declared in the codebase, not by request volume.
     */
    private final ConcurrentHashMap<String, Expression> expressionCache = new ConcurrentHashMap<>();

    @Before("@annotation(com.reuven.ratelimit.RateLimited) || @annotation(com.reuven.ratelimit.RateLimited.List)")
    public void enforce(JoinPoint joinPoint) {
        MethodSignature signature = (MethodSignature) joinPoint.getSignature();
        Method method = signature.getMethod();
        EvaluationContext context = buildContext(method, joinPoint.getArgs());

        // getAnnotationsByType transparently unwraps the @Repeatable container (RateLimited.List)
        // whether the method carries one @RateLimited or several stacked ones.
        for (RateLimited rateLimited : method.getAnnotationsByType(RateLimited.class)) {
            String identifier = evaluate(rateLimited.key(), context);
            engine.consume(rateLimited.limit(), identifier);
        }
    }

    private EvaluationContext buildContext(Method method, Object[] args) {
        StandardEvaluationContext context = new StandardEvaluationContext();
        String[] parameterNames = PARAMETER_NAMES.getParameterNames(method);
        for (int i = 0; parameterNames != null && i < parameterNames.length; i++) {
            context.setVariable(parameterNames[i], args[i]);
            if (args[i] instanceof HttpServletRequest httpRequest) {
                // Stable alias independent of the controller's own parameter name, so
                // key expressions can standardize on #httpRequest across every service.
                context.setVariable("httpRequest", httpRequest);
            }
        }
        return context;
    }

    private String evaluate(String spel, EvaluationContext context) {
        Expression expression = expressionCache.computeIfAbsent(spel, PARSER::parseExpression);
        Object value = expression.getValue(context);
        if (value == null) {
            throw new IllegalStateException("Rate-limit key expression evaluated to null: '" + spel + "'");
        }
        return value.toString();
    }
}
