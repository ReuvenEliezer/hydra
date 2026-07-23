package com.reuven.auth.service;

import com.reuven.auth.dto.CustomUserDetails;
import com.reuven.auth.entity.EntityStatus;
import com.reuven.auth.entity.User;
import com.reuven.auth.repository.UserRepository;
import lombok.RequiredArgsConstructor;
import org.jspecify.annotations.NonNull;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.userdetails.UserDetailsService;
import org.springframework.security.core.userdetails.UsernameNotFoundException;
import org.springframework.stereotype.Service;

import java.util.List;
import java.util.UUID;

@Service
@RequiredArgsConstructor
public class CustomUserDetailsService implements UserDetailsService {

    private final UserRepository userRepository;


    @Override
    public CustomUserDetails loadUserByUsername(@NonNull String userId) throws UsernameNotFoundException {
        try {
            UUID userUuid = UUID.fromString(userId);
            return loadUserById(userUuid);
        } catch (IllegalArgumentException e) {
            // If by chance something enters that is not a UUID, we can throw a clear error
            throw new UsernameNotFoundException("Invalid User ID format: " + userId);
        }
    }

    private CustomUserDetails loadUserById(@NonNull UUID userUuid) {
        User user = userRepository.findWithRolesById(userUuid)
                .orElseThrow(() -> new UsernameNotFoundException("User not found with userUuid: " + userUuid));

        // 1. Prepare Authorities (roles + ROLE_ prefix)
        List<SimpleGrantedAuthority> authorities = user.getRoles().stream()
                .map(role -> new SimpleGrantedAuthority(role.authority()))
                .toList();

        // 2. Return our CustomUserDetails instead of the standard User
        return new CustomUserDetails(
                user.getId().toString(),
                user.getUsername(),
                user.getPasswordHash(),
                user.getTenant().getId(), // Fetching the Tenant ID from the Entity
                authorities,
                user.getStatus() == EntityStatus.ACTIVE
        );
    }
}