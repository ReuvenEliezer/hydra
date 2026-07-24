package com.reuven.auth.service;

import com.reuven.Role;
import com.reuven.auth.exception.InvalidRefreshTokenException;
import com.reuven.auth.exception.RefreshTokenReuseException;
import com.reuven.auth.util.Sha256;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.io.ClassPathResource;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.script.DefaultRedisScript;
import org.springframework.data.redis.core.script.RedisScript;
import org.springframework.stereotype.Service;

import java.security.SecureRandom;
import java.time.Duration;
import java.util.Arrays;
import java.util.Base64;
import java.util.List;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * Redis-backed refresh token store implementing atomic rotation with a short
 * replay grace window (industry-standard approach, same as Auth0/Okta) and
 * family-wide reuse detection.
 *
 * <h2>All lifecycle transitions are single Lua scripts, not Java-orchestrated
 * multi-round-trips</h2>
 * Every operation that used to be several sequential {@code StringRedisTemplate}
 * calls (issue, rotate, revoke) is now one {@code EVAL}. Redis runs a script to
 * completion before processing anything else, so two properties fall out for
 * free instead of needing application-level locking:
 * <ul>
 *   <li><b>No interleaving between concurrent callers.</b> Two browser tabs
 *       racing to rotate the same token cannot both observe the token as
 *       "active" - whichever script invocation Redis runs first wins,
 *       deterministically, every time.</li>
 *   <li><b>No partial state on a mid-operation crash.</b> If the server dies
 *       between "mint the new token" and "open the grace window", from
 *       Redis's point of view that operation never started - there is no
 *       observable in-between state, ever.</li>
 * </ul>
 *
 * <h2>Key design - three namespaces on the hot path, plus one session index</h2>
 *
 * <pre>
 * rt:tok:{Sha256.hash(token)}      -> status-tagged slot      TTL = refreshTtl
 *   "Is this presented token currently valid, and whose is it?" One key
 *   answers this for BOTH a live token and a just-rotated one: the value is
 *   tagged 'A' (active, carries userId/tenantId/familyId/roles) or 'R'
 *   (rotated tombstone, carries just familyId). This merges what used to be
 *   two separate namespaces (active-token metadata, and a parallel lineage
 *   index kept alive purely to resolve dead hashes back to a familyId) into
 *   one - a tombstone left behind by rotation already contains everything
 *   reuse-detection needs; nothing else has to be written or expired
 *   separately to make replay-or-reuse resolution work.
 *
 * rt:family:{familyId}        -> current active token hash   TTL = refreshTtl
 *   "Which hash is this session's live token right now?" A single string
 *   pointer, not a set of every hash the family has ever had. That's what
 *   makes family revocation O(1) - two deletes (the pointer, and the one
 *   active slot it names) instead of an SMEMBERS-then-iterate over an
 *   unboundedly-growing set. Old, already-rotated hashes are never added
 *   here; they live only as tombstones in rt:tok and self-expire.
 *
 * rt:grace:{oldTokenHash}      -> familyId + literal newRawToken   TTL = graceTtl (short)
 *   "Was this exact token legitimately rotated moments ago?" Exists only in
 *   the narrow window after a rotation, to absorb two concurrent requests
 *   (e.g. two browser tabs) both holding the pre-rotation token. Carries the
 *   familyId alongside the literal new raw token so that ANY replaying
 *   caller - not just the one that happened to win the race - can resolve
 *   the actual current session state via the family pointer and hand back
 *   the exact same token pair, with zero extra Redis state created per
 *   replay.
 *
 * rt:user:{userId}             -> Set&lt;familyId&gt;      TTL = refreshTtl
 *   "Which sessions does this user have?" Only needed for admin/bulk
 *   "log out everywhere" - not on the rotation hot path, and bounded by
 *   concurrent session count rather than by rotation count, so it was never
 *   part of the unbounded-growth problem the other three namespaces solve.
 * </pre>
 *
 * <h2>Grace window semantics</h2>
 * On rotation, the presented (old) token's slot becomes a tombstone rather
 * than being deleted outright. If the same raw token is presented again
 * within {@code graceTtl}, that's treated as benign concurrency (NOT reuse)
 * and the exact same new token pair already minted by the winning request is
 * replayed back - critically, no further rotation happens on replay,
 * otherwise an attacker (or a buggy retry loop) could keep the session alive
 * indefinitely by hammering the old token inside the window. Once the grace
 * window closes, presenting that same old token is unambiguous reuse and
 * revokes the entire family.
 */
@Slf4j
@Service
public class RefreshTokenService {

    private static final String TOK_PREFIX = "rt:tok:";
    private static final String FAMILY_PREFIX = "rt:family:";
    private static final String GRACE_PREFIX = "rt:grace:";
    private static final String USER_PREFIX = "rt:user:";

    private static final char SEP = '\u0001';
    private static final int RAW_TOKEN_BYTES = 32; // 256 bits of entropy, opaque token (not a JWT on purpose)

    private static final RedisScript<String> ISSUE_SCRIPT = loadScript("refresh_issue");
    private static final RedisScript<String> ROTATE_SCRIPT = loadScript("refresh_rotate");
    private static final RedisScript<String> REVOKE_FAMILY_SCRIPT = loadScript("refresh_revoke_family");
    private static final RedisScript<String> REVOKE_ALL_SCRIPT = loadScript("refresh_revoke_all");

    private final StringRedisTemplate redis;
    private final SecureRandom secureRandom = new SecureRandom();
    private final long refreshTtlMillis;
    private final long graceTtlMillis;

    public RefreshTokenService(
            StringRedisTemplate redis,
            @Value("${refresh-token.ttl:P30D}") Duration refreshTtl,
            @Value("${refresh-token.grace-ttl:PT5S}") Duration graceTtl) {
        this.redis = redis;
        this.refreshTtlMillis = refreshTtl.toMillis();
        this.graceTtlMillis = graceTtl.toMillis();
    }

    /** Issues a brand-new token family - call this once, at login. */
    public String issue(UUID userId, UUID tenantId, List<Role> roles) {
        String familyId = UUID.randomUUID().toString();
        String rawToken = generateRawToken();
        String hash = Sha256.hash(rawToken);

        redis.execute(
                ISSUE_SCRIPT,
                List.of(TOK_PREFIX + hash, FAMILY_PREFIX + familyId, USER_PREFIX + userId),
                userId.toString(),
                tenantId.toString(),
                familyId,
                rolesToCsv(roles),
                hash,
                Long.toString(refreshTtlMillis));

        log.info("Issued new refresh token family {} for user {}", familyId, userId);
        return rawToken;
    }

    /**
     * Validates and atomically rotates a presented refresh token. Throws
     * {@link InvalidRefreshTokenException} if the token is entirely unknown, or
     * {@link RefreshTokenReuseException} if it was already rotated away outside the
     * grace window (triggers full-family revocation as a side effect).
     */
    public RotationResult rotate(String presentedRawToken) {
        String oldHash = Sha256.hash(presentedRawToken);
        // Generated speculatively: only consumed if this call turns out to be the
        // winner of the race. A replaying/reuse call discards it at zero cost
        // beyond one wasted SecureRandom draw.
        String newRawToken = generateRawToken();
        String newHash = Sha256.hash(newRawToken);

        String reply = redis.execute(
                ROTATE_SCRIPT,
                List.of(TOK_PREFIX + oldHash, TOK_PREFIX + newHash, GRACE_PREFIX + oldHash),
                newHash,
                newRawToken,
                Long.toString(refreshTtlMillis),
                Long.toString(graceTtlMillis));

        return parseRotateReply(reply);
    }

    /** Revokes only the family the presented token belongs to (normal, single-device logout). */
    public void logout(String presentedRawToken) {
        String presentedHash = Sha256.hash(presentedRawToken);
        redis.execute(REVOKE_FAMILY_SCRIPT, List.of(TOK_PREFIX + presentedHash));
        // Unknown token on logout is a no-op by script design - never leak validity info here.
    }

    /** Administrative "log out everywhere" for a user - revokes every session/family. */
    public void revokeAllForUser(UUID userId) {
        String reply = redis.execute(REVOKE_ALL_SCRIPT, List.of(USER_PREFIX + userId));
        int revokedCount = (reply == null || reply.isBlank()) ? 0 : Integer.parseInt(reply);
        log.info("Revoked {} refresh token families for user {}", revokedCount, userId);
    }

    // --- internals ---------------------------------------------------------

    private RotationResult parseRotateReply(String reply) {
        if (reply == null || reply.isBlank()) {
            throw new InvalidRefreshTokenException("Refresh token is not valid");
        }

        String[] parts = reply.split(String.valueOf(SEP), -1);
        String outcome = parts[0];

        return switch (outcome) {
            case "ROTATED", "REPLAY" -> new RotationResult(
                    parts[4],
                    UUID.fromString(parts[1]),
                    UUID.fromString(parts[2]),
                    csvToRoles(parts[3]));
            case "REUSE" -> {
                String familyId = parts[1];
                log.warn("Refresh token reuse detected for family {} - entire family revoked", familyId);
                throw new RefreshTokenReuseException("Refresh token reuse detected");
            }
            default -> throw new InvalidRefreshTokenException("Refresh token is not valid");
        };
    }

    private String generateRawToken() {
        byte[] buf = new byte[RAW_TOKEN_BYTES];
        secureRandom.nextBytes(buf);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(buf);
    }

    private static String rolesToCsv(List<Role> roles) {
        return roles.stream().map(Role::authority).collect(Collectors.joining(","));
    }

    private static List<Role> csvToRoles(String csv) {
        return csv.isBlank() ? List.of() : Arrays.stream(csv.split(",")).map(Role::fromAuthority).toList();
    }

    private static RedisScript<String> loadScript(String name) {
        DefaultRedisScript<String> script = new DefaultRedisScript<>();
        script.setLocation(new ClassPathResource("lua/" + name + ".lua"));
        script.setResultType(String.class);
        return script;
    }
}
