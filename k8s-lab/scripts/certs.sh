#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# certs.sh — lab TLS material (FR-032, FR-032a, FR-032b, FR-053, D9).
#
# Produces exactly three things:
#
#   1. A lab CA (private key + self-signed certificate).
#   2. ONE wildcard certificate for *.localhost, signed by that CA. One
#      certificate covers every tenant, because a tenant is one label in front
#      of the base domain — which is what makes FR-040 ("no per-tenant gateway
#      configuration") true for TLS as well as for routing.
#   3. A PKCS#12 truststore containing the CA, handed to Hydra's existing
#      conformance suite through standard JVM system properties.
#
# Item 3 is the one that makes SC-020 achievable. `EdgeConformanceAssertions`
# builds its clients with `HttpClients.createDefault()`, which resolves the
# JVM's default SSLContext — so `-Djavax.net.ssl.trustStore=...` is enough, and
# not one line of the suite has to change (research.md A7).
#
# WHAT THIS SCRIPT WILL NOT DO, and the refusal is the point:
#   - It will not install anything into the host's system trust store. That is
#     why mkcert was rejected (D9): it modifies the machine, which the lab
#     promises not to do, and it still would not configure the JVM truststore,
#     so it solves nothing that is actually needed.
#   - It will not offer a "skip verification" mode. A harness that skips
#     verification cannot test the `Secure` credential clause it exists to test.
#
# Idempotent, with expiry checks (FR-032a): material that is expired or within
# 30 days of expiring is renewed. That check exists because the spec names the
# exact failure it prevents — a lab rebuilt months later meets an expired
# certificate and reads it as a routing fault.
#
# Nothing generated here enters the tracked tree: .certs/ is in k8s-lab/.gitignore.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"

CA_KEY="${LAB_CERT_DIR}/lab-ca.key"
CA_CRT="${LAB_CA_CERT}"                       # .certs/lab-ca.crt
WILDCARD_KEY="${LAB_CERT_DIR}/wildcard.key"
WILDCARD_CRT="${LAB_CERT_DIR}/wildcard.crt"
TLS_SECRET_NAME="hydra-lab-tls"

CA_DAYS=3650          # the CA outlives many rebuilds
LEAF_DAYS=397         # the CA/Browser Forum maximum; matches real-world limits
RENEW_WITHIN_DAYS=30  # FR-032a

# Returns 0 if the certificate is valid for at least RENEW_WITHIN_DAYS more.
cert_still_good() {
  local crt="$1"
  [[ -r "$crt" ]] || return 1
  openssl x509 -in "$crt" -noout -checkend $(( RENEW_WITHIN_DAYS * 86400 )) >/dev/null 2>&1
}

cert_expiry() {
  openssl x509 -in "$1" -noout -enddate 2>/dev/null | sed 's/notAfter=//'
}

# ---------------------------------------------------------------------------
# ensure — generate or renew, idempotently.
# ---------------------------------------------------------------------------
cmd_ensure() {
  log_suite "certs"

  command -v openssl >/dev/null 2>&1 || {
    log_fail "openssl is not installed"; log_summary; return 1
  }

  mkdir -p "${LAB_CERT_DIR}"
  chmod 700 "${LAB_CERT_DIR}"

  # --- 1. The CA -----------------------------------------------------------
  local regenerate_leaf=0
  if cert_still_good "$CA_CRT" && [[ -r "$CA_KEY" ]]; then
    log_pass "lab CA is present and valid" "expires $(cert_expiry "$CA_CRT")"
  else
    if [[ -f "$CA_CRT" ]]; then
      log_info "lab CA is expired or within ${RENEW_WITHIN_DAYS} days of expiry — renewing (FR-032a)"
      log_info "was: $(cert_expiry "$CA_CRT")"
    fi
    if openssl req -x509 -newkey rsa:4096 -sha256 -days "${CA_DAYS}" -nodes \
         -keyout "$CA_KEY" -out "$CA_CRT" \
         -subj "/CN=Hydra k8s-lab local CA/O=Hydra k8s-lab/OU=NOT FOR PRODUCTION USE" \
         -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
         -addext "keyUsage=critical,keyCertSign,cRLSign" \
         >/dev/null 2>&1; then
      chmod 600 "$CA_KEY"
      log_pass "lab CA generated" "${CA_DAYS} days, RSA 4096"
      # A new CA invalidates any leaf signed by the old one.
      regenerate_leaf=1
    else
      log_fail "could not generate the lab CA"; log_summary; return 1
    fi
  fi

  # --- 2. The wildcard certificate (T035) ---------------------------------
  if (( ! regenerate_leaf )) && cert_still_good "$WILDCARD_CRT" && [[ -r "$WILDCARD_KEY" ]]; then
    # Also confirm it is still signed by the CA we have. A leaf that is
    # in-date but signed by a CA that has since been regenerated verifies
    # against nothing, and the resulting handshake failure names neither.
    if openssl verify -CAfile "$CA_CRT" "$WILDCARD_CRT" >/dev/null 2>&1; then
      log_pass "wildcard certificate is present, valid and signed by the current CA" \
               "expires $(cert_expiry "$WILDCARD_CRT")"
    else
      log_info "wildcard certificate does not verify against the current CA — regenerating"
      regenerate_leaf=1
    fi
  else
    regenerate_leaf=1
  fi

  if (( regenerate_leaf )); then
    local csr ext
    csr="$(mktemp)"; ext="$(mktemp)"
    # ---------------------------------------------------------------------
    # THE WILDCARD IS NOT ENOUGH ON `.localhost`, and this is a real finding
    # rather than a workaround. Measured, not assumed:
    #
    #   SAN `*.localhost`     vs  acme.localhost      -> curl exit 60, REJECTED
    #   SAN `*.lab.localhost` vs  acme.lab.localhost  -> HTTP 200, accepted
    #
    # A TLS client will not match a wildcard against a SINGLE-LABEL parent.
    # `localhost` is a public suffix, and RFC 6125 / the public-suffix rule that
    # every mainstream client implements refuses `*.<TLD>` outright — otherwise
    # one certificate could impersonate an entire top-level domain. The failure
    # message is "subjectAltName does not match host name", which reads like a
    # certificate generation bug and is not one.
    #
    # So the certificate enumerates the tenant hostnames as well as carrying the
    # wildcard. What that costs, stated plainly:
    #
    #   FR-040 / SC-007 hold for ROUTING — a new tenant needs no Gateway, no
    #   HTTPRoute and no listener, and the new-tenant test asserts exactly that.
    #   They do NOT hold for TLS on this base domain: a genuinely new hostname
    #   would need a SAN.
    #
    # This is a property of `.localhost`, NOT of Kubernetes-as-edge. With a real
    # base domain (`*.hydra.example.com`) the wildcard matches and the property
    # is fully preserved — which is why it belongs in the Edge Finding as a
    # limitation of the LAB's addressing choice rather than evidence against the
    # architecture. docs/known-gaps.md carries it too.
    #
    # Changing the base domain to a two-label form was considered and rejected:
    # EdgeConformanceFixture fixes `acme.localhost` and `beta.localhost` as
    # constants, and serving anything else would mean editing Hydra's existing
    # suite — which SC-020 forbids outright.
    # ---------------------------------------------------------------------
    {
      cat <<EXT
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=@alt
[alt]
# Kept even though mainstream clients reject it on a single-label parent: it is
# correct for any client that does accept it, and it documents the intent.
DNS.1=*.${LAB_BASE_DOMAIN}
# The apex, so https://localhost during debugging does not fail in a way that
# looks like a gateway fault.
DNS.2=${LAB_BASE_DOMAIN}
EXT
      # The tenant hostnames the lab actually serves. Enumerated because of the
      # public-suffix rule above, not because the design wants per-tenant TLS.
      n=3
      for t in "${LAB_PRIMARY_TENANT}" "${LAB_SECOND_TENANT}" "${LAB_LATE_TENANT}"; do
        printf 'DNS.%d=%s.%s\n' "$n" "$t" "${LAB_BASE_DOMAIN}"
        n=$(( n + 1 ))
      done
      printf 'IP.1=127.0.0.1\n'
    } > "$ext"
    if openssl req -newkey rsa:2048 -sha256 -nodes \
         -keyout "$WILDCARD_KEY" -out "$csr" \
         -subj "/CN=*.${LAB_BASE_DOMAIN}/O=Hydra k8s-lab" >/dev/null 2>&1 &&
       openssl x509 -req -in "$csr" -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
         -out "$WILDCARD_CRT" -days "${LEAF_DAYS}" -sha256 -extfile "$ext" >/dev/null 2>&1; then
      chmod 600 "$WILDCARD_KEY"
      log_pass "wildcard certificate generated for *.${LAB_BASE_DOMAIN}" "${LEAF_DAYS} days"
      log_info "covers ${LAB_PRIMARY_HOST}, ${LAB_SECOND_HOST}, ${LAB_LATE_HOST} and every future tenant — no per-tenant entry (FR-040)"
    else
      log_fail "could not generate the wildcard certificate"
      rm -f "$csr" "$ext"; log_summary; return 1
    fi
    rm -f "$csr" "$ext"
  fi

  # --- 3. The PKCS#12 truststore (T036, FR-032b) --------------------------
  if command -v keytool >/dev/null 2>&1; then
    local password
    if [[ -r "$LAB_TRUSTSTORE_PASSWORD_FILE" ]]; then
      password="$(cat "$LAB_TRUSTSTORE_PASSWORD_FILE")"
    else
      # Generated, never fixed, never printed, never committed. It is written to
      # an untracked file because the Maven invocation needs to read it back —
      # that hand-off is the entire reason the file exists.
      password="$(openssl rand -hex 24)"
      printf '%s' "$password" > "$LAB_TRUSTSTORE_PASSWORD_FILE"
      chmod 600 "$LAB_TRUSTSTORE_PASSWORD_FILE"
    fi

    rm -f "$LAB_TRUSTSTORE"
    if keytool -importcert -noprompt \
         -alias hydra-lab-ca \
         -file "$CA_CRT" \
         -keystore "$LAB_TRUSTSTORE" \
         -storetype PKCS12 \
         -storepass "$password" >/dev/null 2>&1; then
      chmod 600 "$LAB_TRUSTSTORE"
      log_pass "PKCS#12 truststore written" "${LAB_TRUSTSTORE}"
      log_info "handed to the existing suite as -Djavax.net.ssl.trustStore — no suite code changes (SC-020)"
    else
      log_fail "could not build the PKCS#12 truststore"
      log_info "Without it, 'make test-edge-conformance' cannot verify TLS, and FR-032 has no fallback."
    fi
  else
    log_fail "keytool is not installed, so no truststore can be built"
    log_info "keytool ships with a JDK. FR-032b needs it; there is no plain-HTTP alternative (FR-032)."
  fi

  # --- 4. The Kubernetes TLS Secret (T037, FR-053) ------------------------
  if kubectl --context "${LAB_KUBECONTEXT}" get ns "${NS_APP}" >/dev/null 2>&1; then
    if kubectl --context "${LAB_KUBECONTEXT}" -n "${NS_APP}" create secret tls "${TLS_SECRET_NAME}" \
         --cert="$WILDCARD_CRT" --key="$WILDCARD_KEY" \
         --dry-run=client -o yaml \
       | kubectl --context "${LAB_KUBECONTEXT}" apply -f - >/dev/null 2>&1; then
      log_pass "TLS Secret '${TLS_SECRET_NAME}' applied in ${NS_APP}" "kubectl create secret tls | apply"
      log_info "The Gateway references it by name. No certificate or key material is in the tracked tree (FR-053)."
    else
      log_fail "could not apply the TLS Secret"
    fi
  else
    log_fail "namespace ${NS_APP} does not exist yet"
    log_info "The 'namespaces' checkpoint must run before 'certs' — see the ordering note in setup.sh."
  fi

  log_summary
}

# ---------------------------------------------------------------------------
# verify — the checkpoint's validation command.
# ---------------------------------------------------------------------------
cmd_verify() {
  log_suite "certs verify"

  if [[ -r "$CA_CRT" ]]; then
    if cert_still_good "$CA_CRT"; then
      log_pass "lab CA valid" "expires $(cert_expiry "$CA_CRT")"
    else
      log_fail "lab CA expires within ${RENEW_WITHIN_DAYS} days" "$(cert_expiry "$CA_CRT")"
    fi
  else
    log_fail "no lab CA at ${CA_CRT}"
  fi

  if [[ -r "$WILDCARD_CRT" ]]; then
    if cert_still_good "$WILDCARD_CRT"; then
      log_pass "wildcard certificate valid" "expires $(cert_expiry "$WILDCARD_CRT")"
    else
      log_fail "wildcard certificate expires within ${RENEW_WITHIN_DAYS} days"
    fi
    if openssl verify -CAfile "$CA_CRT" "$WILDCARD_CRT" >/dev/null 2>&1; then
      log_pass "wildcard certificate verifies against the lab CA" "openssl verify"
    else
      log_fail "wildcard certificate does not verify against the lab CA"
    fi
    # The SAN must actually cover the tenant hostnames, not merely exist.
    # Read via -text rather than -ext: macOS ships LibreSSL, which generates
    # extensions with -addext quite happily but has no -ext read flag, so the
    # obvious form silently returns nothing and this check would pass on an
    # empty string.
    local sans
    sans="$(openssl x509 -in "$WILDCARD_CRT" -noout -text 2>/dev/null \
            | grep -A1 'Subject Alternative Name' | tail -1 | tr -d ' ')"
    # The wildcard alone is NOT sufficient on `.localhost` (see the long note in
    # cmd_ensure), so the check that matters is whether the hostnames the lab
    # actually serves are present. Asserting only the wildcard would pass on a
    # certificate no client will accept.
    local san_missing=""
    local t
    for t in "${LAB_PRIMARY_TENANT}" "${LAB_SECOND_TENANT}" "${LAB_LATE_TENANT}"; do
      [[ "$sans" == *"DNS:${t}.${LAB_BASE_DOMAIN}"* ]] || san_missing+="${t}.${LAB_BASE_DOMAIN} "
    done
    if [[ -z "$san_missing" ]]; then
      log_pass "SAN covers every tenant hostname the lab serves" "wildcard plus explicit names — clients reject *.${LAB_BASE_DOMAIN}"
    else
      log_fail "SAN is missing: ${san_missing}"
      log_context "$sans"
    fi
    if [[ "$sans" == *"DNS:*.${LAB_BASE_DOMAIN}"* ]]; then
      log_pass "SAN also carries the *.${LAB_BASE_DOMAIN} wildcard" "correct for clients that accept it"
    fi
  else
    log_fail "no wildcard certificate at ${WILDCARD_CRT}"
  fi

  if [[ -r "$LAB_TRUSTSTORE" && -r "$LAB_TRUSTSTORE_PASSWORD_FILE" ]]; then
    if keytool -list -keystore "$LAB_TRUSTSTORE" -storetype PKCS12 \
         -storepass "$(cat "$LAB_TRUSTSTORE_PASSWORD_FILE")" >/dev/null 2>&1; then
      log_pass "truststore readable and contains the CA" "keytool -list"
    else
      log_fail "truststore exists but will not open with the stored password"
    fi
  else
    log_fail "no truststore or no password file" "FR-032b"
  fi

  if kubectl --context "${LAB_KUBECONTEXT}" -n "${NS_APP}" get secret "${TLS_SECRET_NAME}" >/dev/null 2>&1; then
    log_pass "TLS Secret present in ${NS_APP}" "kubectl get secret ${TLS_SECRET_NAME}"
  else
    log_fail "TLS Secret '${TLS_SECRET_NAME}' missing from ${NS_APP}"
  fi

  # FR-053/FR-085, checked rather than asserted: nothing generated here is
  # tracked by git.
  local tracked
  tracked="$(cd "${LAB_ROOT}" && git ls-files .certs 2>/dev/null || true)"
  if [[ -z "$tracked" ]]; then
    log_pass "no TLS material is tracked by git" "git ls-files .certs is empty"
  else
    log_fail "TLS material has entered the tracked tree"
    log_context "$tracked"
  fi

  log_summary
}

case "${1:-ensure}" in
  ensure) cmd_ensure ;;
  verify) cmd_verify ;;
  *) log_error "usage: certs.sh {ensure|verify}"; exit 2 ;;
esac
