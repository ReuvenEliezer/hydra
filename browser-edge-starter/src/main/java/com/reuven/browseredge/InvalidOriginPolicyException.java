package com.reuven.browseredge;

/**
 * Thrown from {@link BrowserEdgeAutoConfiguration}'s bean factory method to fail context refresh
 * before the service binds its port (FR-010, FR-017, FR-018).
 * <p>
 * Every instance names the offending value and the reason: a generic message would make this
 * fail-closed behaviour undiagnosable in an environment where the operator cannot attach a
 * debugger, only read a startup log.
 */
public class InvalidOriginPolicyException extends RuntimeException {

    public InvalidOriginPolicyException(String message) {
        super(message);
    }
}
