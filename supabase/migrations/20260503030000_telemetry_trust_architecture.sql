CREATE EXTENSION IF NOT EXISTS pgcrypto;

ALTER TABLE public.telemetry_signatures
    ADD COLUMN IF NOT EXISTS rule_id TEXT,
    ADD COLUMN IF NOT EXISTS schema_version INTEGER DEFAULT 2,
    ADD COLUMN IF NOT EXISTS signature_set_version TEXT DEFAULT 'bootstrap-v2',
    ADD COLUMN IF NOT EXISTS category TEXT DEFAULT 'bloat',
    ADD COLUMN IF NOT EXISTS display_name TEXT,
    ADD COLUMN IF NOT EXISTS launchd_label TEXT,
    ADD COLUMN IF NOT EXISTS launchd_domain TEXT DEFAULT 'gui',
    ADD COLUMN IF NOT EXISTS bundle_id TEXT,
    ADD COLUMN IF NOT EXISTS executable_path_pattern TEXT,
    ADD COLUMN IF NOT EXISTS team_id TEXT,
    ADD COLUMN IF NOT EXISTS signing_identifier TEXT,
    ADD COLUMN IF NOT EXISTS min_macos TEXT,
    ADD COLUMN IF NOT EXISTS max_macos TEXT,
    ADD COLUMN IF NOT EXISTS termination_strategy TEXT DEFAULT 'signal',
    ADD COLUMN IF NOT EXISTS severity SMALLINT DEFAULT 1,
    ADD COLUMN IF NOT EXISTS verified BOOLEAN DEFAULT false,
    ADD COLUMN IF NOT EXISTS source_url TEXT,
    ADD COLUMN IF NOT EXISTS source_commit TEXT,
    ADD COLUMN IF NOT EXISTS deprecated_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS revoked_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

UPDATE public.telemetry_signatures
SET rule_id = LOWER(REGEXP_REPLACE(vendor || '-' || process_name || '-v2', '[^a-zA-Z0-9._-]+', '-', 'g'))
WHERE rule_id IS NULL;

UPDATE public.telemetry_signatures
SET display_name = process_name
WHERE display_name IS NULL;

UPDATE public.telemetry_signatures
SET category = CASE
        WHEN LOWER(vendor) LIKE '%apple%intelligence%' THEN 'intelligence'
        ELSE 'bloat'
    END,
    signature_set_version = COALESCE(signature_set_version, 'bootstrap-v2'),
    schema_version = 2,
    launchd_domain = COALESCE(launchd_domain, 'gui'),
    termination_strategy = COALESCE(termination_strategy, 'signal'),
    severity = COALESCE(severity, 1),
    verified = false,
    updated_at = COALESCE(updated_at, NOW());

DELETE FROM public.telemetry_signatures
WHERE team_id IS NULL
    AND signing_identifier IS NULL
    AND bundle_id IS NULL;

ALTER TABLE public.telemetry_signatures
    ALTER COLUMN rule_id SET NOT NULL,
    ALTER COLUMN schema_version SET NOT NULL,
    ALTER COLUMN signature_set_version SET NOT NULL,
    ALTER COLUMN category SET NOT NULL,
    ALTER COLUMN display_name SET NOT NULL,
    ALTER COLUMN process_name SET NOT NULL,
    ALTER COLUMN launchd_domain SET NOT NULL,
    ALTER COLUMN termination_strategy SET NOT NULL,
    ALTER COLUMN severity SET NOT NULL,
    ALTER COLUMN verified SET NOT NULL,
    ALTER COLUMN updated_at SET NOT NULL;

ALTER TABLE public.telemetry_signatures
    DROP CONSTRAINT IF EXISTS telemetry_signatures_vendor_process_name_key;

CREATE UNIQUE INDEX IF NOT EXISTS telemetry_signatures_rule_id_key
    ON public.telemetry_signatures(rule_id);

CREATE UNIQUE INDEX IF NOT EXISTS telemetry_signatures_signature_set_rule_id_key
    ON public.telemetry_signatures(signature_set_version, rule_id);

DO $$
BEGIN
    ALTER TABLE public.telemetry_signatures
        ADD CONSTRAINT telemetry_signatures_rule_id_check
        CHECK (rule_id ~ '^[a-z0-9][a-z0-9._-]{2,127}$');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    ALTER TABLE public.telemetry_signatures
        ADD CONSTRAINT telemetry_signatures_schema_version_check
        CHECK (schema_version = 2);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    ALTER TABLE public.telemetry_signatures
        ADD CONSTRAINT telemetry_signatures_category_check
        CHECK (category IN ('bloat', 'intelligence'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    ALTER TABLE public.telemetry_signatures
        ADD CONSTRAINT telemetry_signatures_launchd_label_check
        CHECK (launchd_label IS NULL OR launchd_label ~ '^[A-Za-z0-9._-]{1,256}$');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    ALTER TABLE public.telemetry_signatures
        ADD CONSTRAINT telemetry_signatures_launchd_domain_check
        CHECK (launchd_domain IN ('gui', 'system', 'both'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    ALTER TABLE public.telemetry_signatures
        ADD CONSTRAINT telemetry_signatures_bundle_id_check
        CHECK (bundle_id IS NULL OR bundle_id ~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,255}$');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    ALTER TABLE public.telemetry_signatures
        ADD CONSTRAINT telemetry_signatures_team_id_check
        CHECK (team_id IS NULL OR team_id ~ '^[A-Z0-9]{10}$');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    ALTER TABLE public.telemetry_signatures
        ADD CONSTRAINT telemetry_signatures_signing_identifier_check
        CHECK (signing_identifier IS NULL OR signing_identifier ~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,255}$');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    ALTER TABLE public.telemetry_signatures
        ADD CONSTRAINT telemetry_signatures_macos_check
        CHECK (
            (min_macos IS NULL OR min_macos ~ '^[0-9]{1,2}(\.[0-9]{1,2}){0,2}$')
            AND (max_macos IS NULL OR max_macos ~ '^[0-9]{1,2}(\.[0-9]{1,2}){0,2}$')
        );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    ALTER TABLE public.telemetry_signatures
        ADD CONSTRAINT telemetry_signatures_termination_strategy_check
        CHECK (termination_strategy IN ('signal', 'launchctl_bootout', 'launchctl_disable', 'none'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    ALTER TABLE public.telemetry_signatures
        ADD CONSTRAINT telemetry_signatures_severity_check
        CHECK (severity BETWEEN 0 AND 3);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    ALTER TABLE public.telemetry_signatures
        ADD CONSTRAINT telemetry_signatures_strong_identity_check
        CHECK (team_id IS NOT NULL OR signing_identifier IS NOT NULL OR bundle_id IS NOT NULL);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS public.telemetry_signature_revocations (
    signature_set_version TEXT PRIMARY KEY,
    reason TEXT NOT NULL,
    revoked_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.telemetry_signature_revocations ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
    CREATE POLICY "Signature revocations are public to read"
        ON public.telemetry_signature_revocations FOR SELECT
        USING (true);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

INSERT INTO public.telemetry_signatures (
    rule_id,
    schema_version,
    signature_set_version,
    vendor,
    category,
    display_name,
    process_name,
    launchd_label,
    launchd_domain,
    executable_path_pattern,
    signing_identifier,
    termination_strategy,
    severity,
    verified
)
VALUES
    ('apple-intelligence-intelligenceplatformd-v2', 2, 'bootstrap-v2', 'Apple', 'intelligence', 'intelligenceplatformd', 'intelligenceplatformd', 'com.apple.intelligenceplatformd', 'both', '/System/Library/*/intelligenceplatformd', 'com.apple.intelligenceplatformd', 'launchctl_disable', 2, true),
    ('apple-intelligence-siriknowledged-v2', 2, 'bootstrap-v2', 'Apple', 'intelligence', 'siriknowledged', 'siriknowledged', 'com.apple.siriknowledged', 'gui', '/System/Library/*/siriknowledged', 'com.apple.siriknowledged', 'launchctl_disable', 2, true),
    ('apple-intelligence-siriinferenced-v2', 2, 'bootstrap-v2', 'Apple', 'intelligence', 'siriinferenced', 'siriinferenced', 'com.apple.siriinferenced', 'both', '/System/Library/*/siriinferenced', 'com.apple.siriinferenced', 'launchctl_disable', 2, true),
    ('apple-intelligence-intelligencecontextd-v2', 2, 'bootstrap-v2', 'Apple', 'intelligence', 'intelligencecontextd', 'intelligencecontextd', 'com.apple.intelligencecontextd', 'both', '/System/Library/*/intelligencecontextd', 'com.apple.intelligencecontextd', 'launchctl_disable', 2, true)
ON CONFLICT (rule_id) DO UPDATE
SET signature_set_version = EXCLUDED.signature_set_version,
    vendor = EXCLUDED.vendor,
    category = EXCLUDED.category,
    display_name = EXCLUDED.display_name,
    process_name = EXCLUDED.process_name,
    launchd_label = EXCLUDED.launchd_label,
    launchd_domain = EXCLUDED.launchd_domain,
    executable_path_pattern = EXCLUDED.executable_path_pattern,
    signing_identifier = EXCLUDED.signing_identifier,
    termination_strategy = EXCLUDED.termination_strategy,
    severity = EXCLUDED.severity,
    verified = EXCLUDED.verified,
    updated_at = NOW();
