package com.reuven.auth.dto;

import com.reuven.Role;

import java.util.Set;
import java.util.UUID;

public interface UserSecurity {
    UUID getId();
    String getUsername();
    Set<Role> getRoles();
}