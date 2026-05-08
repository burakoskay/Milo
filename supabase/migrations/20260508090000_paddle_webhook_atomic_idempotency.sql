-- Milo Paddle webhook hardening
-- Moves webhook idempotency into the subscription mutation transaction so a
-- transient RPC failure cannot permanently consume a Paddle event id.

ALTER TABLE public.paddle_webhook_events
    ADD COLUMN IF NOT EXISTS processed_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

DROP FUNCTION IF EXISTS public.update_user_subscription(UUID, TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS public.cancel_user_subscription(UUID, TIMESTAMPTZ);

CREATE OR REPLACE FUNCTION public.update_user_subscription(
    p_user_id UUID,
    p_status TEXT,
    p_customer_id TEXT,
    p_subscription_id TEXT,
    p_next_billing TIMESTAMPTZ,
    p_event_occurred_at TIMESTAMPTZ,
    p_event_id TEXT DEFAULT NULL,
    p_event_type TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF p_event_id IS NOT NULL THEN
        INSERT INTO paddle_webhook_events (event_id, event_type, occurred_at, processed_at)
        VALUES (p_event_id, p_event_type, p_event_occurred_at, NOW())
        ON CONFLICT (event_id) DO NOTHING;

        IF NOT FOUND THEN
            RETURN;
        END IF;
    END IF;

    IF p_status IS NULL OR p_status NOT IN ('active', 'trialing', 'past_due', 'paused', 'canceled') THEN
        RAISE EXCEPTION 'Invalid subscription status';
    END IF;

    UPDATE profiles
    SET subscription_status = CASE
            WHEN p_status IN ('active', 'trialing') THEN 'active'
            WHEN p_status = 'past_due' THEN 'past_due'
            ELSE 'canceled'
        END,
        paddle_customer_id = p_customer_id,
        paddle_subscription_id = p_subscription_id,
        next_billing_date = p_next_billing,
        paddle_last_event_at = COALESCE(p_event_occurred_at, NOW()),
        updated_at = NOW()
    WHERE id = p_user_id
        AND (
            p_event_occurred_at IS NULL
            OR paddle_last_event_at IS NULL
            OR p_event_occurred_at >= paddle_last_event_at
        );

    IF NOT FOUND THEN
        IF EXISTS (SELECT 1 FROM profiles WHERE id = p_user_id) THEN
            RETURN;
        END IF;
        RAISE EXCEPTION 'Profile not found';
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.update_user_subscription(UUID, TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_user_subscription(UUID, TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT)
    TO service_role;

CREATE OR REPLACE FUNCTION public.cancel_user_subscription(
    p_user_id UUID,
    p_event_occurred_at TIMESTAMPTZ,
    p_event_id TEXT DEFAULT NULL,
    p_event_type TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF p_event_id IS NOT NULL THEN
        INSERT INTO paddle_webhook_events (event_id, event_type, occurred_at, processed_at)
        VALUES (p_event_id, p_event_type, p_event_occurred_at, NOW())
        ON CONFLICT (event_id) DO NOTHING;

        IF NOT FOUND THEN
            RETURN;
        END IF;
    END IF;

    UPDATE profiles
    SET subscription_status = 'canceled',
        next_billing_date = NULL,
        paddle_last_event_at = COALESCE(p_event_occurred_at, NOW()),
        updated_at = NOW()
    WHERE id = p_user_id
        AND (
            p_event_occurred_at IS NULL
            OR paddle_last_event_at IS NULL
            OR p_event_occurred_at >= paddle_last_event_at
        );

    IF NOT FOUND THEN
        IF EXISTS (SELECT 1 FROM profiles WHERE id = p_user_id) THEN
            RETURN;
        END IF;
        RAISE EXCEPTION 'Profile not found';
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_user_subscription(UUID, TIMESTAMPTZ, TEXT, TEXT)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_user_subscription(UUID, TIMESTAMPTZ, TEXT, TEXT)
    TO service_role;
