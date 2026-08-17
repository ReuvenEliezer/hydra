package com.reuven.auth.service;

import com.reuven.Role;
import com.reuven.auth.dto.AuthResponse;
import com.reuven.auth.dto.CustomUserDetails;
import com.reuven.auth.dto.LoginRequest;
import com.reuven.auth.dto.RegisterRequest;
import com.reuven.auth.entity.EntityStatus;
import com.reuven.auth.entity.Tenant;
import com.reuven.auth.entity.User;
import com.reuven.auth.exception.BusinessRuleException;
import com.reuven.auth.exception.ResourceNotFoundException;
import com.reuven.auth.repository.TenantRepository;
import com.reuven.auth.repository.UserRepository;
import lombok.extern.slf4j.Slf4j;
import org.springframework.security.authentication.BadCredentialsException;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;

@Slf4j
@Service
@Transactional(readOnly = true)
public class AuthService {

    private final UserRepository userRepository;
    private final TenantRepository tenantRepository;
    private final PasswordEncoder passwordEncoder;
    private final JwtProvider jwtProvider;
    private final RefreshTokenService refreshTokenService;

    public AuthService(UserRepository userRepository,
                       TenantRepository tenantRepository,
                       PasswordEncoder passwordEncoder,
                       JwtProvider jwtProvider,
                       RefreshTokenService refreshTokenService) {

        this.userRepository = userRepository;
        this.tenantRepository = tenantRepository;
        this.passwordEncoder = passwordEncoder;
        this.jwtProvider = jwtProvider;
        this.refreshTokenService = refreshTokenService;
    }

    @Transactional
    public AuthResponse registerAdmin(RegisterRequest request, UUID tenantId, Role requesterRole) {
        if (requesterRole != Role.SUPER_ADMIN) {
            throw new BusinessRuleException("Only Super Admin can register tenant admins");
        }

        Tenant tenant = tenantRepository.findById(tenantId)
                .orElseThrow(() -> new ResourceNotFoundException("Tenant not found: " + tenantId));

        if (!EntityStatus.ACTIVE.equals(tenant.getStatus())) {
            throw new BusinessRuleException("Cannot register user for inactive tenant");
        }

        if (userRepository.existsByTenantIdAndUsername(tenantId, request.username())) {
            throw new BusinessRuleException("Username already taken in this tenant");
        }

        User admin = new User(tenant, request.username(),
                passwordEncoder.encode(request.password()), Role.ADMIN, EntityStatus.ACTIVE);
        userRepository.save(admin);

        log.info("Admin '{}' created for tenant {}", request.username(), tenantId);
        return new AuthResponse(admin.getId(), null, "TENANT_ADMIN_CREATED");
    }

    @Transactional
    public AuthResponse registerUser(RegisterRequest request, CustomUserDetails currentUser) {
        User admin = userRepository.findById(UUID.fromString(currentUser.getUserId()))
                .orElseThrow(() -> new BusinessRuleException("Admin not found"));

        UUID tenantId = currentUser.getTenantId();
        if (!admin.getTenant().getId().equals(tenantId)) {
            throw new BusinessRuleException("Forbidden: You cannot modify other tenants");
        }

        Tenant tenant = tenantRepository.findById(tenantId)
                .orElseThrow(() -> new ResourceNotFoundException("Tenant not found"));

        if (userRepository.existsByTenantIdAndUsername(tenantId, request.username())) {
            throw new BusinessRuleException("Username already taken in this tenant");
        }

        User newUser = new User(tenant, request.username(),
                passwordEncoder.encode(request.password()), Role.USER, EntityStatus.ACTIVE);
        User save = userRepository.save(newUser);

        log.info("User '{}' created in tenant {}", request.username(), tenantId);
        return new AuthResponse(save.getId(), null, "USER_CREATED");
    }

    /**
     * Authenticates {@code request} within {@code tenantId}.
     * <p>
     * {@code tenantId} is the tenant the controller <em>resolved from the request's own
     * {@code Host}</em> - it is never supplied by the caller of the HTTP API. That distinction is
     * the whole point of the feature: the browser has no way to name a tenant, so it has no way to
     * aim a credential at one. By the time execution reaches here the address is already known to
     * resolve to an {@code ACTIVE} tenant, so every failure below is genuinely a credential
     * failure and collapsing them into one message costs the user nothing.
     */
    public LoginResult login(LoginRequest request, UUID tenantId) {
        // Use a generic message to prevent username enumeration
        User user = userRepository.findWithRolesByTenantIdAndUsername(tenantId, request.username())
                .orElseThrow(() -> new BadCredentialsException("Invalid credentials"));

        if (!EntityStatus.ACTIVE.equals(user.getStatus())) {
            throw new BadCredentialsException("Invalid credentials");
        }

        if (!passwordEncoder.matches(request.password(), user.getPasswordHash())) {
            throw new BadCredentialsException("Invalid credentials");
        }

        String accessToken = jwtProvider.generateToken(user);
        List<Role> roles = List.copyOf(user.getRoles());
        String rawRefreshToken = refreshTokenService.issue(user.getId(), tenantId, user.getUsername(), roles);

        log.info("User '{}' logged in for tenant {}", request.username(), tenantId);
        return new LoginResult(new AuthResponse(user.getId(), accessToken), rawRefreshToken);
    }

    /** Pairs the access-token response body with the raw refresh token, which the
     *  controller (not this service) turns into an httpOnly cookie. Keeping that
     *  split here means AuthService stays in charge of the transactional unit of
     *  "issue both tokens together", while CookieUtil/HTTP concerns stay in the web layer. */
    public record LoginResult(AuthResponse body, String rawRefreshToken) {
    }
}