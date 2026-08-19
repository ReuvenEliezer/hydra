package com.reuven.integration;

import java.io.File;
import java.net.URISyntaxException;
import java.net.URL;

/**
 * {@code integration-tests} depends on both {@code auth-service} and {@code order-service}, so
 * any test class in this module that boots even ONE of their real Spring contexts still has
 * BOTH modules' {@code db/changelog/db.changelog-master.yaml} on the JVM's classpath — both
 * services deliberately share that default Liquibase location (006-liquibase-schema-migration,
 * research.md R2 revised). Liquibase's own resource resolution (unlike Spring's lenient
 * single-winner config-file loading) treats more than one physical match for a {@code
 * classpath:} location as a hard error: {@code ChangeLogParseException: ... Found 2 files with
 * the path 'classpath:/db/changelog/db.changelog-master.yaml'}. This is true even for a fixture
 * that only ever starts ONE of the two services (see {@code EdgeConformanceFixture}) — the
 * ambiguity is a property of the classpath, not of which {@code SpringApplication} is running.
 * <p>
 * The fix is a concrete {@code file:}/{@code jar:file:} URL, not a {@code classpath:} one:
 * {@code DefaultResourceLoader} resolves any URL-shaped location as a direct {@link
 * org.springframework.core.io.UrlResource}, never touching classloader/classpath resource
 * scanning at all, so it is immune to the duplicate-match check by construction. Production is
 * entirely unaffected — each service runs in its own JVM/container there, so the classpath never
 * has a second candidate to collide with in the first place.
 */
public final class OwnChangelogFileUrl {

    private OwnChangelogFileUrl() {
    }

    private static final String CHANGELOG_PATH = "db/changelog/db.changelog-master.yaml";

    /**
     * Builds a URL pointing at {@code db/changelog/db.changelog-master.yaml} inside the given
     * application class's OWN code source — introspected from the classpath entry Java actually
     * loaded that class from, never a hardcoded relative path, so this holds regardless of
     * working directory.
     * <p>
     * The code source is a {@code target/classes} directory when running from an IDE or {@code
     * mvn test} without a prior {@code package}/{@code install}, but a packaged jar once the
     * module has been built — the two need different URL shapes ({@code file:.../} vs. {@code
     * jar:file:...!/}), so which one it is has to be checked rather than assumed.
     */
    public static String forApplication(Class<?> applicationClass) {
        URL codeSourceUrl = applicationClass.getProtectionDomain().getCodeSource().getLocation();
        try {
            File codeSourceFile = new File(codeSourceUrl.toURI());
            if (codeSourceFile.isDirectory()) {
                return codeSourceUrl.toExternalForm() + CHANGELOG_PATH;
            }
            return "jar:" + codeSourceUrl.toExternalForm() + "!/" + CHANGELOG_PATH;
        } catch (URISyntaxException e) {
            throw new IllegalStateException(
                    "Could not resolve code source location for " + applicationClass, e);
        }
    }
}
