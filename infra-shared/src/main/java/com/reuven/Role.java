package com.reuven;

/**
 * The single, strongly-typed definition of a role, shared by every service
 * (auth-service issues these in the JWT "roles" claim; order-service - and any
 * future service - consumes them via Spring Security authorities). Previously
 * each service independently hand-wrote the "ROLE_" + name() convention in
 * three or four different places, which is exactly the kind of thing that
 * quietly drifts: rename a role in one spot and every other spot silently
 * keeps working against the stale string. Everything now flows through this
 * one enum instead of loose {@code String}/{@code List<String>} role values.
 *
 * @see Roles for the {@code @PreAuthorize}/authorizeHttpRequests-facing SpEL
 *      expression constants built from the same authority strings.
 */
public enum Role {

    SUPER_ADMIN(Roles.SUPER_ADMIN_AUTHORITY),
    ADMIN(Roles.ADMIN_AUTHORITY),
    USER(Roles.USER_AUTHORITY);

    private final String authority;

    Role(String authority) {
        this.authority = authority;
    }

    /** The Spring Security authority string this role maps to, e.g. {@code "ROLE_ADMIN"}. */
    public String authority() {
        return authority;
    }

    /**
     * Reverses {@link #authority()} - used wherever a role has to cross a
     * string-typed wire boundary (a JWT claim, a Redis value) and needs to
     * come back out the other side as a {@code Role} rather than staying a
     * bare {@code String} for the rest of its life in the code.
     */
    public static Role fromAuthority(String authority) {
        for (Role role : values()) {
            if (role.authority.equals(authority)) {
                return role;
            }
        }
        throw new IllegalArgumentException("Unknown authority: " + authority);
    }
}
