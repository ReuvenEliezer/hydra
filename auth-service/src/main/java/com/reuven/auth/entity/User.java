package com.reuven.auth.entity;

import com.reuven.Role;
import jakarta.persistence.*;
import lombok.Getter;

import java.util.HashSet;
import java.util.Set;
import java.util.UUID;

@Getter
@Entity
@Table(
        name = "users",
        uniqueConstraints = {
                @UniqueConstraint(name = "uq_users_tenant_username", columnNames = {"tenant_id", "username"})
        }
)
public class User {

    // Getters and Setters
    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    @Column(name = "id", updatable = false, nullable = false)
    private UUID id;

    @ManyToOne(fetch = FetchType.LAZY) // Removed the cascade
    @JoinColumn(name = "tenant_id", nullable = false, foreignKey = @ForeignKey(name = "fk_users_tenant"))
    private Tenant tenant;

    @Column(nullable = false, length = 50)
    private String username;

    @Column(name = "password_hash", nullable = false, length = 255)
    private String passwordHash;

    @ElementCollection(fetch = FetchType.LAZY)
    @CollectionTable(name = "user_roles", joinColumns = @JoinColumn(name = "user_id"))
    @Column(name = "role")
    @Enumerated(EnumType.STRING)
    private Set<Role> roles = new HashSet<>();

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private EntityStatus status;

    public User() {}

    public User(Tenant tenant, String username, String passwordHash, Role roles, EntityStatus status) {
        this(tenant, username, passwordHash, Set.of(roles), status);
    }

    public User(Tenant tenant, String username, String passwordHash, Set<Role> roles, EntityStatus status) {
        this.tenant = tenant;
        this.username = username;
        this.passwordHash = passwordHash;
        this.roles = roles;
        this.status = status;
    }

    public void setTenant(Tenant tenant) { this.tenant = tenant; }

    public void setUsername(String username) { this.username = username; }

    public void setPasswordHash(String passwordHash) { this.passwordHash = passwordHash; }

    public void addRole(Role role) { this.roles.add(role); }

    public void setStatus(EntityStatus status) {
        this.status = status;
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof User user)) return false;
        return id != null && id.equals(user.getId());
    }

    @Override
    public int hashCode() {
        return getClass().hashCode(); // Constant for stability in Set/Map before and after save
    }
}