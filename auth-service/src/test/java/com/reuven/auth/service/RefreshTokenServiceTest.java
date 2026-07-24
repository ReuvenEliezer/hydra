package com.reuven.auth.service;

import com.redis.testcontainers.RedisContainer;
import com.reuven.Role;
import com.reuven.auth.exception.InvalidRefreshTokenException;
import com.reuven.auth.exception.RefreshTokenReuseException;
import com.reuven.auth.util.Sha256;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.connection.RedisStandaloneConfiguration;
import org.springframework.data.redis.connection.lettuce.LettuceConnectionFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.*;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Pure unit-level test of the atomic Lua-scripted Redis key design (token slot,
 * family pointer, grace window) against a real redis:8.8-alpine container - no
 * Spring context, so this runs in milliseconds compared to the full integration
 * test below.
 */
@Testcontainers
@DisplayName("RefreshTokenService")
class RefreshTokenServiceTest {

    @Container
    static RedisContainer redis = new RedisContainer(DockerImageName.parse("redis:8.8-alpine"))
            .withExposedPorts(6379);

    private StringRedisTemplate redisTemplate;
    private RefreshTokenService service;
    private LettuceConnectionFactory connectionFactory;

    private final UUID userId = UUID.randomUUID();
    private final UUID tenantId = UUID.randomUUID();
    private final List<Role> roles = List.of(Role.USER);

    @BeforeEach
    void setUp() {
        connectionFactory = new LettuceConnectionFactory(
                new RedisStandaloneConfiguration(redis.getHost(), redis.getMappedPort(6379)));
        connectionFactory.afterPropertiesSet();
        redisTemplate = new StringRedisTemplate(connectionFactory);
        redisTemplate.afterPropertiesSet();
        // Short grace window so the "outside grace" tests don't need a real 5s sleep.
        service = new RefreshTokenService(redisTemplate, Duration.ofDays(30), Duration.ofMillis(300));
    }

    @AfterEach
    void tearDown() {
        var conn = connectionFactory.getConnection();
        conn.serverCommands().flushDb();
        connectionFactory.destroy();
    }

    @Test
    @DisplayName("issue() then rotate() with the fresh token succeeds and invalidates the original")
    void rotate_withValidToken_succeedsAndInvalidatesOriginal() {
        String original = service.issue(userId, tenantId, roles);

        RotationResult result = service.rotate(original);

        assertThat(result.userId()).isEqualTo(userId);
        assertThat(result.tenantId()).isEqualTo(tenantId);
        assertThat(result.roles()).isEqualTo(roles);
        assertThat(result.rawRefreshToken()).isNotEqualTo(original);

        // The new token must itself be valid going forward...
        assertThat(service.rotate(result.rawRefreshToken())).isNotNull();
    }

    @Test
    @DisplayName("rotate() with an unknown token throws InvalidRefreshTokenException")
    void rotate_withUnknownToken_throwsInvalid() {
        assertThatThrownBy(() -> service.rotate("not-a-real-token"))
                .isInstanceOf(InvalidRefreshTokenException.class);
    }

    @Test
    @DisplayName("Concurrent rotate() replay within the grace window returns the same new token, idempotently")
    void rotate_replayedWithinGraceWindow_isIdempotent() {
        String original = service.issue(userId, tenantId, roles);

        RotationResult first = service.rotate(original);
        // Simulates a second browser tab firing the same refresh concurrently, just
        // after the first request already rotated the token.
        RotationResult replay = service.rotate(original);

        assertThat(replay.rawRefreshToken()).isEqualTo(first.rawRefreshToken());
        assertThat(replay.userId()).isEqualTo(userId);
    }

    @Test
    @DisplayName("rotate() presented again after the grace window has expired is treated as reuse")
    void rotate_presentedAfterGraceWindowExpires_isReuse() throws InterruptedException {
        String original = service.issue(userId, tenantId, roles);
        service.rotate(original);

        Thread.sleep(400); // grace TTL in this test is 300ms

        assertThatThrownBy(() -> service.rotate(original))
                .isInstanceOf(RefreshTokenReuseException.class);
    }

    @Test
    @DisplayName("Reuse detection revokes the entire family - even the latest, never-presented token stops working")
    void reuseDetected_revokesEntireFamily() throws InterruptedException {
        String gen1 = service.issue(userId, tenantId, roles);
        RotationResult gen2 = service.rotate(gen1);
        RotationResult gen3 = service.rotate(gen2.rawRefreshToken());

        Thread.sleep(400); // let gen1's grace window for gen2 lapse before replaying gen1

        assertThatThrownBy(() -> service.rotate(gen1))
                .isInstanceOf(RefreshTokenReuseException.class);

        // gen3 was never compromised, but the whole family must die on reuse signal.
        assertThatThrownBy(() -> service.rotate(gen3.rawRefreshToken()))
                .isInstanceOf(InvalidRefreshTokenException.class);
    }

    @Test
    @DisplayName("logout() revokes the token's family; a subsequent rotate() fails")
    void logout_revokesFamily() {
        String token = service.issue(userId, tenantId, roles);

        service.logout(token);

        assertThatThrownBy(() -> service.rotate(token))
                .isInstanceOf(InvalidRefreshTokenException.class);
    }

    @Test
    @DisplayName("logout() with an unknown token is a silent no-op, not an error")
    void logout_withUnknownToken_doesNotThrow() {
        service.logout("garbage-token-that-was-never-issued");
        // no exception
    }

    @Test
    @DisplayName("revokeAllForUser() kills every family/session belonging to that user")
    void revokeAllForUser_killsEverySession() {
        String session1 = service.issue(userId, tenantId, roles);
        String session2 = service.issue(userId, tenantId, roles); // e.g. a second device/browser

        service.revokeAllForUser(userId);

        assertThatThrownBy(() -> service.rotate(session1)).isInstanceOf(InvalidRefreshTokenException.class);
        assertThatThrownBy(() -> service.rotate(session2)).isInstanceOf(InvalidRefreshTokenException.class);
    }

    @Test
    @DisplayName("Two concurrent login sessions for the same user are fully independent")
    void independentSessions_doNotInterfere() {
        String session1 = service.issue(userId, tenantId, roles);
        String session2 = service.issue(userId, tenantId, roles);

        service.logout(session1);

        assertThatThrownBy(() -> service.rotate(session1)).isInstanceOf(InvalidRefreshTokenException.class);
        assertThat(service.rotate(session2)).isNotNull(); // unaffected
    }

    @Test
    @DisplayName("32 threads racing rotate() on the SAME token produce exactly one winner - no dual successor")
    void rotate_32ConcurrentCallers_exactlyOneWinnerNoDualSuccessor() throws InterruptedException, ExecutionException {
        String original = service.issue(userId, tenantId, roles);

        int threadCount = 32;
        ExecutorService pool = Executors.newFixedThreadPool(threadCount);
        CountDownLatch startingGate = new CountDownLatch(1);
        List<Future<RotationResult>> futures = new ArrayList<>();

        for (int i = 0; i < threadCount; i++) {
            futures.add(pool.submit((Callable<RotationResult>) () -> {
                startingGate.await();
                return service.rotate(original);
            }));
        }

        startingGate.countDown(); // release all 32 threads at once
        pool.shutdown();
        boolean completedInTime = pool.awaitTermination(30, TimeUnit.SECONDS);
        assertThat(completedInTime).as("all 32 rotate() calls must complete").isTrue();

        // Each Future::get is asserted individually on the MAIN test thread (not
        // inside the worker) so a failure surfaces as a normal AssertJ failure
        // with a clear message, the same idiom as assertThatThrownBy elsewhere in
        // this file - just the "should NOT throw" counterpart.
        List<RotationResult> results = new ArrayList<>();
        for (Future<RotationResult> future : futures) {
            assertThatCode(future::get)
                    .as("every concurrent caller must either win the race or receive a valid replay - never an exception")
                    .doesNotThrowAnyException();
            results.add(future.get());
        }
        assertThat(results).hasSize(threadCount);

        // The critical invariant: no matter which thread "won" the race, every one
        // of the 32 concurrent callers must have received the SAME new raw token.
        // Two or more distinct successors would mean the family forked - exactly
        // the double-refresh / dual-successor bug atomic GETDEL-based rotation
        // exists to prevent.
        Set<String> distinctSuccessors = results.stream()
                .map(RotationResult::rawRefreshToken)
                .collect(Collectors.toSet());
        assertThat(distinctSuccessors)
                .as("exactly one successor token must exist across all concurrent rotations")
                .hasSize(1);

        // And that single successor must itself still be a valid, live token going forward.
        String successor = distinctSuccessors.iterator().next();
        assertThat(service.rotate(successor)).isNotNull();
    }

    @Test
    @DisplayName("Redis key footprint after issue+rotate is small and bounded, not growing per historical hash")
    void rotate_leavesSmallBoundedRedisFootprint() {
        String original = service.issue(userId, tenantId, roles);
        RotationResult rotation = service.rotate(original);

        Set<String> allKeys = redisTemplate.keys("rt:*");
        // Expect exactly: rt:tok:{newHash} (active), rt:tok:{oldHash} (tombstone),
        // rt:family:{familyId} (pointer), rt:grace:{oldHash} (replay window),
        // rt:user:{userId} (session index). Five keys total for one session
        // regardless of how it got there - no per-generation Set that grows
        // without bound the way the old five-namespace design's family Set did.
        assertThat(allKeys).hasSize(5);

        long tokKeys = allKeys.stream().filter(k -> k.startsWith("rt:tok:")).count();
        long familyKeys = allKeys.stream().filter(k -> k.startsWith("rt:family:")).count();
        long graceKeys = allKeys.stream().filter(k -> k.startsWith("rt:grace:")).count();
        long userKeys = allKeys.stream().filter(k -> k.startsWith("rt:user:")).count();

        assertThat(tokKeys).isEqualTo(2); // active + tombstone
        assertThat(familyKeys).isEqualTo(1); // single pointer, not a Set
        assertThat(graceKeys).isEqualTo(1);
        assertThat(userKeys).isEqualTo(1);
        assertThat(rotation).isNotNull();
    }

    @Test
    @DisplayName("grace TTL is honored with millisecond precision, not rounded to whole seconds")
    void rotate_graceWindowExpiry_isMillisecondPrecise() throws InterruptedException {
        // This test's service is built with a 300ms grace TTL (see setUp()) - if
        // rotation used second-granularity expiry (e.g. Redis 'EX' instead of
        // 'PX'), 300ms would round down to 0 and the grace window would never
        // exist at all, so any replay attempt at 150ms would already see it as
        // reuse. Asserting the replay succeeds at 150ms and fails at 400ms proves
        // millisecond precision end to end.
        String original = service.issue(userId, tenantId, roles);
        RotationResult first = service.rotate(original);

        Thread.sleep(150); // well within the 300ms grace window
        RotationResult replay = service.rotate(original);
        assertThat(replay.rawRefreshToken())
                .as("replay inside the millisecond-precision grace window must still succeed")
                .isEqualTo(first.rawRefreshToken());

        Thread.sleep(400); // now well past the 300ms grace window
        assertThatThrownBy(() -> service.rotate(original))
                .as("presenting the same token again after the grace window has elapsed is reuse")
                .isInstanceOf(RefreshTokenReuseException.class);
    }

    @Test
    @DisplayName("issued token's Redis TTL matches the configured refresh TTL, not some default")
    void issue_setsPreciseRefreshTtl() {
        Duration configuredTtl = Duration.ofDays(30);
        String token = service.issue(userId, tenantId, roles);

        String hash = Sha256.hash(token);
        Long ttlMillis = redisTemplate.getExpire("rt:tok:" + hash, TimeUnit.MILLISECONDS);

        assertThat(ttlMillis).isNotNull();
        assertThat(ttlMillis).isGreaterThan(0L);
        // Allow generous slack for test execution time, but this must be close to
        // the full 30 days, not silently truncated to a default TTL.
        assertThat(ttlMillis).isCloseTo(configuredTtl.toMillis(), org.assertj.core.data.Offset.offset(60_000L));
    }
}
