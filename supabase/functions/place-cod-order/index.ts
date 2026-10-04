import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const allowedOrigins = new Set([
  "https://widajewls.com",
  "https://www.widajewls.com",
  "https://widajewls-store.pages.dev",
  "https://widajewls-store.widajewls.workers.dev",
]);

const getCorsHeaders = (req: Request) => {
  const origin = req.headers.get("Origin") || "";
  const allowOrigin = allowedOrigins.has(origin) ? origin : "https://widajewls.com";
  return {
    "Access-Control-Allow-Origin": allowOrigin,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
    "Content-Type": "application/json",
  };
};

const json = (req: Request, body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: getCorsHeaders(req) });

Deno.serve(async (req) => {
  const corsHeaders = getCorsHeaders(req);
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json(req, { error: "Method not allowed." }, 405);

  const turnstileSecret = Deno.env.get("TURNSTILE_SECRET_KEY");
  if (!turnstileSecret) {
    console.error("TURNSTILE_SECRET_KEY is not configured.");
    return json(req, { error: "Checkout protection is not configured yet." }, 503);
  }

  let body: {
    turnstile_token?: string;
    purchase_event_id?: string;
    event_source_url?: string;
    order?: {
      p_customer_name: string;
      p_phone: string;
      p_city: string;
      p_address: string;
      p_notes?: string | null;
      p_items: unknown[];
      p_idempotency_key: string;
      p_discount_code?: string | null;
    };
  };

  try {
    body = await req.json();
  } catch {
    return json(req, { error: "Invalid request." }, 400);
  }

  const token = String(body?.turnstile_token || "");
  if (!token) return json(req, { error: "Please complete the security check." }, 400);

  const remoteip = req.headers.get("CF-Connecting-IP") || "";
  const verifyBody = new URLSearchParams({
    secret: turnstileSecret,
    response: token,
  });
  if (remoteip) verifyBody.set("remoteip", remoteip);

  const verifyResponse = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: verifyBody.toString(),
  });

  if (!verifyResponse.ok) {
    console.error("Turnstile verification HTTP failure:", verifyResponse.status);
    return json(req, { error: "Security check failed. Please try again." }, 403);
  }

  const verification = await verifyResponse.json();
  if (!verification.success) {
    console.warn("Turnstile rejected checkout:", verification["error-codes"] || []);
    return json(req, { error: "Security check failed. Please try again." }, 403);
  }

  const order = body?.order;
  if (!order || !Array.isArray(order.p_items)) {
    return json(req, { error: "Invalid order." }, 400);
  }

  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  if (!serviceRoleKey || !supabaseUrl) {
    console.error("Supabase server environment is incomplete.");
    return json(req, { error: "Checkout service is temporarily unavailable." }, 503);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data, error } = await supabase.rpc("place_cod_order", {
    p_customer_name: order.p_customer_name,
    p_phone: order.p_phone,
    p_city: order.p_city,
    p_address: order.p_address,
    p_notes: order.p_notes ?? null,
    p_items: order.p_items,
    p_idempotency_key: order.p_idempotency_key,
    p_discount_code: order.p_discount_code ?? null,
  });

  if (error) {
    console.error("COD order RPC error:", error);
    return json(req, { error: error.message || "Could not place your order." }, 400);
  }

  const result = Array.isArray(data) ? data[0] : data;
  const metaToken = Deno.env.get("META_CAPI_ACCESS_TOKEN");
  const metaPixelId = Deno.env.get("META_PIXEL_ID") || "";
  const purchaseEventId = String(body.purchase_event_id || "").trim();

  async function sendMetaPurchase() {
    if (metaToken && metaPixelId && purchaseEventId && result?.total != null) {
    try {
      const sha256 = async (value: string) => {
        const bytes = new TextEncoder().encode(value);
        const hash = await crypto.subtle.digest("SHA-256", bytes);
        return Array.from(new Uint8Array(hash)).map(b => b.toString(16).padStart(2, "0")).join("");
      };

      const normalizeName = (value: string) =>
        value.trim().toLowerCase().normalize("NFKD").replace(/[\\u0300-\\u036f]/g, "").replace(/[^a-z0-9\\s]/g, "").replace(/\\s+/g, " ");

      const rawPhone = String(order.p_phone || "").replace(/\\D/g, "");
      const phoneDigits = rawPhone.startsWith("212") ? rawPhone : rawPhone.replace(/^0/, "212");
      const normalizedPhone = phoneDigits ? "+" + phoneDigits : "";
      const nameParts = normalizeName(String(order.p_customer_name || "")).split(" ").filter(Boolean);

      const userData: Record<string, unknown> = {
        client_ip_address: remoteip || undefined,
        client_user_agent: req.headers.get("user-agent") || undefined,
      };
      if (normalizedPhone) userData.ph = [await sha256(normalizedPhone)];
      if (nameParts[0]) userData.fn = [await sha256(nameParts[0])];
      if (nameParts.length > 1) userData.ln = [await sha256(nameParts.slice(1).join(" "))];

      const capiPayload = {
        data: [{
          event_name: "Purchase",
          event_time: Math.floor(Date.now() / 1000),
          event_id: purchaseEventId,
          action_source: "website",
          event_source_url: String(body.event_source_url || "https://widajewls.com/#/checkout"),
          user_data: userData,
          custom_data: {
            currency: "MAD",
            value: Number(result.total),
            content_ids: Array.isArray(order.p_items)
              ? order.p_items.map((item: any) => String(item?.product_id || "")).filter(Boolean)
              : [],
            content_type: "product",
            num_items: Array.isArray(order.p_items)
              ? order.p_items.reduce((sum: number, item: any) => sum + Number(item?.quantity || 0), 0)
              : 0,
            order_id: String(result.order_number || ""),
          },
        }],
        access_token: metaToken,
      };

      const capiResponse = await fetch(
        "https://graph.facebook.com/v24.0/" + encodeURIComponent(metaPixelId) + "/events",
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(capiPayload),
        }
      );

      const capiResult = await capiResponse.json().catch(() => ({}));
      if (!capiResponse.ok || capiResult.error) {
        console.error("Meta CAPI Purchase failed:", capiResponse.status, capiResult);
      } else {
        console.log("Meta CAPI Purchase sent:", {
          events_received: capiResult.events_received,
          fbtrace_id: capiResult.fbtrace_id,
          event_id: purchaseEventId,
        });
      }
    } catch (capiError) {
      console.error("Meta CAPI Purchase exception:", capiError);
    }
  } else {
    console.warn("Meta CAPI Purchase skipped: missing configuration or purchase_event_id.");
  }
  }

  if (typeof EdgeRuntime !== "undefined" && typeof EdgeRuntime.waitUntil === "function") {
    EdgeRuntime.waitUntil(sendMetaPurchase());
  } else {
    await sendMetaPurchase();
  }

  return json(req, { data: result, purchase_event_id: purchaseEventId });
});