package com.reuven.auth.dto;

import com.reuven.auth.entity.UserRole;

import java.util.Set;
import java.util.UUID;

public interface UserSecurity {
    UUID getId();
    String getUsername();
    Set<UserRole> getRoles();
}