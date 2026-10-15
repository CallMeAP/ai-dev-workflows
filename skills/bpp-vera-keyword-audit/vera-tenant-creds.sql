-- VERA keyword audit: one credential set per GoUser with a VERA token, for every tenant (read-only).
-- Run against PROD; export the result as CSV WITH header to
--   ~/Downloads/.vera-audit/creds.csv   (then: chmod 600 that file)
-- psql variant:
--   \copy (<this query without the trailing semicolon>) TO '~/Downloads/.vera-audit/creds.csv' WITH (FORMAT csv, HEADER)
-- Mirrors VeraSessionCredentialsResolver: a tenant counts only if all five tenant fields are set; each
-- non-deleted GoUser of that tenant with a VERA user token yields one row (tenant fields repeat per row).
-- user_idx = 1 is the tenant's oldest such GoUser. Used to verify that every GoUser of a tenant sees the
-- same VERA catalog before the tenant is audited once.
-- Output contains PROD SECRETS. Never paste it anywhere; delete the file after the audit.
SELECT row_number() OVER (ORDER BY t.created_at, t.id, g.created_at, g.id)        AS idx,
       dense_rank() OVER (ORDER BY t.created_at, t.id)                             AS tenant_idx,
       row_number() OVER (PARTITION BY t.id ORDER BY g.created_at, g.id)           AS user_idx,
       t.id                  AS tenant_id,
       t.tenant_name         AS tenant_name,
       g.id                  AS go_user_id,
       tl.vera_username      AS vera_username,
       tl.vera_password      AS vera_password,
       tl.vera_api_key       AS vera_api_key,
       tl.vera_client_secret AS vera_client_secret,
       tl.vera_client_id     AS vera_client_id,
       gl.vera_user_token    AS vera_user_token
FROM tenants t
JOIN tenant_external_services_links tl
  ON tl.tenant_id = t.id AND tl.is_soft_deleted = false
JOIN go_users g
  ON g.tenant_id = t.id AND g.is_soft_deleted = false
JOIN go_user_external_services_links gl
  ON gl.go_user_id = g.id AND gl.is_soft_deleted = false
WHERE t.is_soft_deleted = false
  AND NULLIF(btrim(tl.vera_username), '')      IS NOT NULL
  AND NULLIF(btrim(tl.vera_password), '')      IS NOT NULL
  AND NULLIF(btrim(tl.vera_api_key), '')       IS NOT NULL
  AND NULLIF(btrim(tl.vera_client_secret), '') IS NOT NULL
  AND NULLIF(btrim(tl.vera_client_id), '')     IS NOT NULL
  AND NULLIF(btrim(gl.vera_user_token), '')    IS NOT NULL
ORDER BY idx;
