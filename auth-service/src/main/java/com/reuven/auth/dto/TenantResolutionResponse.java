package com.reuven.auth.dto;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.reuven.auth.service.TenantResolution;

/**
 * The public tenant-lookup response - what an anonymous browser is told about the address it
 * loaded (FR-014).
 * <p>
 * <strong>No field here may ever carry the tenant UUID</strong>, in any state. The internal
 * {@link TenantResolution} does carry it because the login path needs a tenant to look a user up
 * in; this type is the boundary where it is dropped. That asymmetry is the entire mechanism
 * behind SC-006, and it is asserted directly ("the serialized body contains no UUID-shaped
 * string, in every state") rather than left to review. The same rule rules out anything else the
 * browser could echo back as a tenant override - there is deliberately no branding, no logo, no
 * identifier field.
 * <p>
 * {@code displayName} is present only on {@code recognized}: FR-014 authorizes showing an
 * organization's name at an address that works, not at one that is switched off or unknown.
 * {@code @JsonInclude(NON_NULL)} is what makes it <em>absent</em> in those states rather than
 * {@code null} or {@code ""} - a client checking {@code "displayName" in body} and one checking
 * truthiness must reach the same conclusion.
 * <p>
 * Note this service runs Jackson 3 ({@code tools.jackson.*}, see {@code GeneralConfig.jsonMapper})
 * while the annotation still lives under {@code com.fasterxml.jackson.annotation} - the same
 * pairing {@link AuthResponse} already relies on.
 */
@JsonInclude(JsonInclude.Include.NON_NULL)
public record TenantResolutionResponse(String status, String displayName) {

    public static final String RECOGNIZED = "recognized";
    public static final String INACTIVE = "inactive";
    public static final String UNKNOWN = "unknown";

    public static TenantResolutionResponse from(TenantResolution resolution) {
        return switch (resolution.status()) {
            case RECOGNIZED -> new TenantResolutionResponse(RECOGNIZED, resolution.displayName());
            case INACTIVE -> new TenantResolutionResponse(INACTIVE, null);
            case UNKNOWN -> new TenantResolutionResponse(UNKNOWN, null);
        };
    }
}
