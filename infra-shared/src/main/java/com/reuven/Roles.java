package com.reuven;

/**
 * {@code @PreAuthorize}/{@code authorizeHttpRequests}-facing role expressions.
 * Kept separate from {@link Role} because Spring Security annotation values
 * must be compile-time constant {@code String}s, not enum method calls - but
 * every literal below is built by concatenating the SAME authority-string
 * constants {@link Role} is built from, so the two can never drift apart.
 * Java folds concatenation of compile-time-constant Strings into a single
 * constant at compile time, so this concatenation is still legal inside an
 * annotation.
 */
public final class Roles {

    // Single source of truth for the actual authority strings. Role's
    // constructor uses these same constants.
    static final String SUPER_ADMIN_AUTHORITY = "ROLE_SUPER_ADMIN";
    static final String ADMIN_AUTHORITY = "ROLE_ADMIN";
    static final String USER_AUTHORITY = "ROLE_USER";

    public static final String USER =
            "hasAnyAuthority('" + USER_AUTHORITY + "','" + ADMIN_AUTHORITY + "','" + SUPER_ADMIN_AUTHORITY + "')";

    public static final String ADMIN =
            "hasAnyAuthority('" + ADMIN_AUTHORITY + "','" + SUPER_ADMIN_AUTHORITY + "')";

    public static final String SUPER_ADMIN_ONLY =
            "hasAuthority('" + SUPER_ADMIN_AUTHORITY + "')";

    private Roles() {}
}
