package com.reuven.auth.dto;

import com.reuven.auth.entity.User;
import com.reuven.auth.service.TokenClaims;
import lombok.Getter;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.core.userdetails.UserDetails;

import java.util.Collection;
import java.util.List;
import java.util.UUID;

public class CustomUserDetails implements UserDetails {

    @Getter
    private final String userId; // The technical identifier (for internal use)
    private final String username; // The name for read-only
    private final String password;
    @Getter
    private final UUID tenantId; // The field important to us
    private final Collection<? extends GrantedAuthority> authorities;
    private final boolean enabled;

    public CustomUserDetails(String userId, String username, String password, UUID tenantId,
                             Collection<? extends GrantedAuthority> authorities,
                             boolean enabled) {
        this.userId = userId;
        this.username = username;
        this.password = password;
        this.tenantId = tenantId;
        this.authorities = authorities;
        this.enabled = enabled;
    }

    /**
     * Builds from validated JWT claims — no DB call.
     * Used by {@link com.reuven.auth.service.JwtAuthenticationFilter} on every request.
     * username and password are null intentionally: they're not present in the JWT
     * and are not needed after the token has already been validated.
     */
    public static CustomUserDetails fromTokenClaims(TokenClaims claims) {
        List<SimpleGrantedAuthority> authorities = claims.roles().stream()
                .map(role -> new SimpleGrantedAuthority(role.authority()))
                .toList();
        return new CustomUserDetails(
                claims.userId().toString(),
                null,
                null,
                claims.tenantId(),
                authorities,
                true
        );
    }

    /**
     * Builds from a fully-loaded User entity — used when a DB round-trip is
     * intentional (e.g. login, registration flows where the entity is already loaded).
     */
    public static CustomUserDetails fromEntity(User user) {
        List<SimpleGrantedAuthority> authorities = user.getRoles().stream()
                .map(role -> new SimpleGrantedAuthority(role.authority()))
                .toList();
        return new CustomUserDetails(
                user.getId().toString(),
                user.getUsername(),
                user.getPasswordHash(),
                user.getTenant().getId(), // Fetching the ID from within the Tenant Object
                authorities,
                true
        );
    }

    /** Extracts tenantId from the current request's SecurityContext. */
    public static UUID getCurrentTenantId() {
        var authentication = SecurityContextHolder.getContext().getAuthentication();
        if (authentication != null && authentication.getPrincipal() instanceof CustomUserDetails details) {
            return details.getTenantId();
        }
        throw new IllegalStateException("No tenant ID found in security context");
    }

    @Override public Collection<? extends GrantedAuthority> getAuthorities() { return authorities; }
    @Override public String getPassword()                                     { return password; }
    @Override public String getUsername()                                     { return username; }
    @Override public boolean isAccountNonExpired()                            { return true; }
    @Override public boolean isAccountNonLocked()                             { return true; }
    @Override public boolean isCredentialsNonExpired()                        { return true; }
    @Override public boolean isEnabled()                                      { return enabled; }
}
