package com.reuven.auth.dto;

import com.reuven.auth.entity.User;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.core.userdetails.UserDetails;
import java.util.Collection;
import java.util.Collections;
import java.util.UUID;
import java.util.stream.Collectors;


public class CustomUserDetails implements UserDetails {

    private final String userId; // The technical identifier (for internal use)
    private final String username; // The name for read-only
    private final String password;
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

    // Adding the missing Factory method
    public static CustomUserDetails fromEntity(User user) {
        return new CustomUserDetails(
                user.getId().toString(),
                user.getUsername(),
                user.getPasswordHash(),
                user.getTenant().getId(), // Fetching the ID from within the Tenant Object
                user.getRoles().stream()
                        .map(role -> new SimpleGrantedAuthority("ROLE_" + role.name()))
                        .toList(),
                true
        );
    }

    public String getUserId() {
        return userId;
    }

    // Getter methods for Tenant
    public UUID getTenantId() {
        return tenantId;
    }

    // Implementation of UserDetails methods
    @Override
    public Collection<? extends GrantedAuthority> getAuthorities() {
        return authorities;
    }

    @Override
    public String getPassword() {
        return password;
    }

    @Override
    public String getUsername() {
        return username;
    }

    // Here you can return a constant true if you don't have complex Account Expiry logic
    @Override
    public boolean isAccountNonExpired() { return true; }

    @Override
    public boolean isAccountNonLocked() { return true; }

    @Override
    public boolean isCredentialsNonExpired() { return true; }

    @Override
    public boolean isEnabled() { return this.enabled; }

    public static UUID getCurrentTenantId() {
        var authentication = SecurityContextHolder.getContext().getAuthentication();

        if (authentication != null && authentication.getPrincipal() instanceof CustomUserDetails) {
            return ((CustomUserDetails) authentication.getPrincipal()).getTenantId();
        }

        throw new IllegalStateException("No tenant ID found in security context");
    }
}