package com.reuven.orderservice;

import com.reuven.JwtClaimNames;
import com.reuven.Role;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.test.web.servlet.MockMvc;

import java.util.List;
import java.util.UUID;

import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;


@AutoConfigureMockMvc
@SpringBootTest
class OrderServiceApplicationTests {

    @Autowired
    private MockMvc mockMvc;


    @Test
    void shouldReturnOrdersWhenAuthenticated() throws Exception {
        mockMvc.perform(get("/api/orders")
                        .with(jwt()
                                .jwt(jwt -> jwt
                                        .claim(JwtClaimNames.TENANT_ID, UUID.randomUUID())
                                )
                                .authorities(
                                        new SimpleGrantedAuthority(Role.USER.authority())
                                )))
                .andExpect(status().isOk());
    }

//    {
//        "sub": "123",
//            "roles": [
//        "ROLE_USER",
//                "ROLE_ADMIN"
//  ]
//    }

    @Test
    void shouldReturn401WhenNoToken() throws Exception {
        mockMvc.perform(get("/api/orders"))
                .andExpect(status().isUnauthorized());
    }
}
