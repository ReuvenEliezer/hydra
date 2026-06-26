package com.reuven;

public final class Roles {

    public static final String USER =
            "hasAnyAuthority('ROLE_USER','ROLE_ADMIN','ROLE_SUPER_ADMIN')";

    public static final String ADMIN =
            "hasAnyAuthority('ROLE_ADMIN','ROLE_SUPER_ADMIN')";
}