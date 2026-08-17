package com.reuven.auth.repository;

import com.reuven.auth.dto.UserSecurity;
import com.reuven.auth.entity.User;
import org.springframework.data.jpa.repository.EntityGraph;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.stereotype.Repository;

import java.util.Optional;
import java.util.UUID;

public interface UserRepository extends JpaRepository<User, UUID> {

    // Lookup by username and tenant (for business logic and login)
    // tenantId here is the tenant's UUID (as defined in the Tenant entity)
    Optional<User> findByTenantIdAndUsername(UUID tenantId, String username);

    @EntityGraph(attributePaths = {"roles"})
    Optional<User> findWithRolesByTenantIdAndUsername(UUID tenantId, String username);

    // Check whether a user exists (to prevent duplicates during registration)
    boolean existsByTenantIdAndUsername(UUID tenantId, String username);

    @EntityGraph(attributePaths = {"roles"})
    Optional<User> findWithRolesById(UUID id);

    @Query("SELECT u.id as id, u.username as username, r as roles FROM User u JOIN u.roles r WHERE u.id = :id")
    UserSecurity findSecurityInfoById(UUID id);

}
