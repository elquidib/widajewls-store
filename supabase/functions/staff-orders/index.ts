import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const validPin = (value: string) => value.length === 6 && Array.from(value).every(c => c >= "0" && c <= "9");

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);
  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const authorization = req.headers.get("Authorization") || "";
  const token = authorization.startsWith("Bearer ") ? authorization.slice(7) : authorization;
  if (!token) return reply({ error: "Authentication required" }, 401);
  const authClient = createClient(url, anonKey, { auth: { persistSession: false } });
  const { data: authData, error: authError } = await authClient.auth.getUser(token);
  if (authError || !authData.user) return reply({ error: "Invalid session" }, 401);
  const actor = authData.user;
  const db = createClient(url, serviceKey, { auth: { persistSession: false } });
  const { data: profile } = await db.from("profiles").select("role,full_name").eq("id", actor.id).maybeSingle();
  if (!profile || !["admin", "staff"].includes(profile.role)) return reply({ error: "Not authorized" }, 403);
  const isAdmin = profile.role === "admin";
  if (!isAdmin) {
    const { data: staff } = await db.from("staff_accounts").select("active").eq("user_id", actor.id).maybeSingle();
    if (!staff?.active) return reply({ error: "Staff account disabled" }, 403);
  }
  let body: any;
  try { body = await req.json(); } catch { return reply({ error: "Invalid JSON" }, 400); }
  const action = String(body?.action || "");
  if (action === "list_orders") {
    const { data, error } = await db.from("orders")
      .select("id,order_number,customer_name,phone,city,address,total,status,created_at,order_items(id,product_name,quantity,line_total,variant_name)")
      .order("created_at", { ascending: false }).limit(250);
    if (error) return reply({ error: "Could not load orders" }, 500);
    return reply({ orders: data || [] });
  }
  if (action === "handle_order") {
    const orderId = String(body?.order_id || "");
    const operation = String(body?.operation || "");
    if (!/^[0-9a-f-]{36}$/i.test(orderId)) return reply({ error: "Invalid order" }, 400);
    if (!["confirm", "cancel", "call_later"].includes(operation)) return reply({ error: "Invalid action" }, 400);
    const { data: order } = await db.from("orders").select("id").eq("id", orderId).maybeSingle();
    if (!order) return reply({ error: "Order not found" }, 404);
    if (operation === "confirm" || operation === "cancel") {
      const status = operation === "confirm" ? "confirmed" : "cancelled";
      const { error } = await db.from("orders").update({ status, updated_at: new Date().toISOString() }).eq("id", orderId);
      if (error) return reply({ error: "Could not update order status" }, 500);
    } else {
      const when = body?.follow_up_at ? new Date(body.follow_up_at) : new Date(Date.now() + 2 * 60 * 60 * 1000);
      if (Number.isNaN(when.getTime())) return reply({ error: "Invalid reminder time" }, 400);
      const { error } = await db.from("order_followups").upsert({
        order_id: orderId, workflow_status: "call_later",
        follow_up_at: when.toISOString(), updated_at: new Date().toISOString()
      }, { onConflict: "order_id" });
      if (error) return reply({ error: "Could not save call-back reminder" }, 500);
    }
    const auditAction = operation === "confirm" ? "confirmed" : operation === "cancel" ? "cancelled" : "call_later";
    const { error: auditError } = await db.from("staff_order_audit").insert({
      order_id: orderId, staff_user_id: isAdmin ? null : actor.id, actor_user_id: actor.id,
      action: auditAction, details: operation === "call_later" ? { follow_up_at: body?.follow_up_at || null } : {}
    });
    if (auditError) return reply({ error: "Action saved but audit logging failed. Contact admin." }, 500);
    return reply({ success: true, action: auditAction });
  }
  if (!isAdmin) return reply({ error: "Admin permission required" }, 403);
  if (action === "list_staff") {
    const { data, error } = await db.from("staff_accounts")
      .select("user_id,username,display_name,active,created_at").order("created_at", { ascending: false });
    if (error) return reply({ error: "Could not load staff" }, 500);
    return reply({ staff: data || [] });
  }
  if (action === "create_staff") {
    const username = String(body?.username || "").trim().toLowerCase();
    const displayName = String(body?.display_name || "").trim();
    const pin = String(body?.pin || "");
    if (!/^[a-z0-9._-]{3,24}$/.test(username)) return reply({ error: "Username must be 3–24 characters: letters, numbers, dot, dash or underscore." }, 400);
    if (displayName.length < 1 || displayName.length > 80) return reply({ error: "Enter a staff name (max 80 characters)." }, 400);
    if (!validPin(pin)) return reply({ error: "PIN must contain exactly 6 digits." }, 400);
    const { data: created, error: createError } = await db.auth.admin.createUser({
      email: username + "@staff.widajewls.invalid", password: pin, email_confirm: true,
      user_metadata: { full_name: displayName, account_type: "wida_staff" }
    });
    if (createError || !created.user) return reply({ error: createError?.message || "Could not create staff login" }, 400);
    const userId = created.user.id;
    const { error: profileError } = await db.from("profiles").upsert(
      { id: userId, full_name: displayName, role: "staff" }, { onConflict: "id" }
    );
    if (profileError) { await db.auth.admin.deleteUser(userId); return reply({ error: "Could not create staff profile" }, 500); }
    const { error: staffError } = await db.from("staff_accounts").insert({
      user_id: userId, username, display_name: displayName, created_by: actor.id
    });
    if (staffError) {
      await db.from("profiles").delete().eq("id", userId);
      await db.auth.admin.deleteUser(userId);
      return reply({ error: staffError.code === "23505" ? "That username is already taken." : "Could not save staff account." }, 400);
    }
    return reply({ success: true, staff: { user_id: userId, username, display_name: displayName, active: true } });
  }
  if (action === "reset_pin") {
    const userId = String(body?.user_id || ""), pin = String(body?.pin || "");
    if (!/^[0-9a-f-]{36}$/i.test(userId) || !validPin(pin)) return reply({ error: "Enter a valid staff account and six-digit PIN." }, 400);
    const { data: target } = await db.from("staff_accounts").select("user_id").eq("user_id", userId).maybeSingle();
    if (!target) return reply({ error: "Staff account not found" }, 404);
    const { error } = await db.auth.admin.updateUserById(userId, { password: pin });
    if (error) return reply({ error: "Could not reset PIN" }, 500);
    return reply({ success: true });
  }
  if (action === "set_staff_active") {
    const userId = String(body?.user_id || ""), active = body?.active === true;
    const { data: target } = await db.from("staff_accounts").select("user_id").eq("user_id", userId).maybeSingle();
    if (!target) return reply({ error: "Staff account not found" }, 404);
    const { error } = await db.from("staff_accounts").update({ active, updated_at: new Date().toISOString() }).eq("user_id", userId);
    if (error) return reply({ error: "Could not update staff account" }, 500);
    const { error: authUpdateError } = await db.auth.admin.updateUserById(userId, { ban_duration: active ? "none" : "876000h" });
    if (authUpdateError) return reply({ error: "Staff status saved but login restriction update failed." }, 500);
    return reply({ success: true, active });
  }
  return reply({ error: "Unknown action" }, 400);
});