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

    // שליפה לפי שם משתמש וטננט (לצורך לוגיקה עסקית ולוגין)
    // ה-tenantId כאן הוא ה-UUID של הטננט (כפי שהגדרנו בישות Tenant)
    Optional<User> findByTenantIdAndUsername(UUID tenantId, String username);

    @EntityGraph(attributePaths = {"roles"})
    Optional<User> findWithRolesByTenantIdAndUsername(UUID tenantId, String username);

    // בדיקת קיום משתמש (למניעת שכפול בזמן הרשמה)
    boolean existsByTenantIdAndUsername(UUID tenantId, String username);

    @EntityGraph(attributePaths = {"roles"})
    Optional<User> findWithRolesById(UUID id);

    @Query("SELECT u.id as id, u.username as username, r as roles FROM User u JOIN u.roles r WHERE u.id = :id")
    UserSecurity findSecurityInfoById(UUID id);

}
