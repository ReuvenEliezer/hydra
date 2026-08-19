package com.reuven.schemadrift;

import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Deliberately lives OUTSIDE {@code com.reuven.orderservice} entirely — not merely in a
 * subpackage of it. {@code OrderServiceApplication}'s own default component/entity scan covers
 * every subpackage of {@code com.reuven.orderservice}, so a {@code drift} package nested under
 * it would leak {@link DriftWidget} into the real application's entity set and break its own
 * tests (which is exactly what happened the first time this was tried — see git history). This
 * package's isolation is the fix, not incidental.
 */
@SpringBootApplication
public class DriftTestApplication {
}
