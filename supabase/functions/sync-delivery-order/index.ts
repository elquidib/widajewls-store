import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "https://widajewls.com",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
};

function reply(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) return reply({ error: "Authentication required" }, 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceKey) return reply({ error: "Server configuration is incomplete" }, 500);

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) return reply({ error: "Invalid session" }, 401);

  const adminClient = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: profile, error: profileError } = await adminClient
    .from("profiles").select("role").eq("id", userData.user.id).maybeSingle();
  if (profileError || profile?.role !== "admin") return reply({ error: "Admin access required" }, 403);

  let orderId: string;
  try {
    const payload = await req.json();
    orderId = String(payload?.order_id || "");
    if (!orderId) return reply({ error: "order_id is required" }, 400);
  } catch {
    return reply({ error: "Invalid JSON body" }, 400);
  }

  const { data: order, error: orderError } = await adminClient
    .from("orders")
    .select("id, order_number, customer_name, phone, city, address, notes, total, status, created_at, delivery_sheet_exported_at")
    .eq("id", orderId).maybeSingle();
  if (orderError || !order) return reply({ error: "Order not found" }, 404);

  // Never export unconfirmed orders. Once exported, later status changes update the same row.
  if (order.status !== "confirmed" && !order.delivery_sheet_exported_at) {
    return reply({ ok: true, skipped: true, reason: "Order has not been confirmed yet" });
  }

  const { data: configRows, error: configError } = await adminClient
    .from("integration_settings").select("key, value")
    .in("key", ["google_sheets_webhook_url", "google_sheets_token"]);
  if (configError) return reply({ error: "Could not load delivery integration settings" }, 500);
  const config = Object.fromEntries((configRows || []).map((row) => [row.key, row.value]));
  const webhookUrl = config.google_sheets_webhook_url;
  const token = config.google_sheets_token;
  if (!webhookUrl || !token) {
    return reply({ error: "Google Sheets is not connected yet. Finish the setup steps first." }, 424);
  }

  const { data: items, error: itemsError } = await adminClient
    .from("order_items").select("product_name, quantity, line_total")
    .eq("order_id", order.id);
  if (itemsError) return reply({ error: "Could not load order items" }, 500);

  const exportOrder = {
    order_number: order.order_number,
    created_at: order.created_at,
    customer_name: order.customer_name,
    phone: order.phone,
    city: order.city || "",
    address: order.address || "",
    notes: order.notes || "",
    total: Number(order.total || 0),
    status: order.status,
    items: (items || []).map((item) => ({
      product_name: item.product_name || "",
      quantity: Number(item.quantity || 0),
      line_total: Number(item.line_total || 0),
    })),
  };

  try {
    const response = await fetch(webhookUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ token, order: exportOrder }),
      signal: AbortSignal.timeout(15000),
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok || result?.ok !== true) {
      const message = String(result?.error || `Google Sheets returned HTTP ${response.status}`).slice(0, 500);
      await adminClient.from("orders").update({ delivery_sheet_sync_error: message }).eq("id", order.id);
      return reply({ error: message, synced: false }, 502);
    }
    const { error: markError } = await adminClient.from("orders")
      .update({ delivery_sheet_exported_at: new Date().toISOString(), delivery_sheet_sync_error: null })
      .eq("id", order.id);
    if (markError) return reply({ error: "Sheet updated, but sync marker could not be saved", synced: true }, 500);
    return reply({ ok: true, synced: true, order_number: order.order_number });
  } catch (error) {
    const message = (error instanceof Error ? error.message : "Delivery sheet request failed").slice(0, 500);
    await adminClient.from("orders").update({ delivery_sheet_sync_error: message }).eq("id", order.id);
    return reply({ error: "Could not reach Google Sheets. The order status was saved; retry the sync after checking the connection." }, 502);
  }
});
