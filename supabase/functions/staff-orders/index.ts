import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-staff-session",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...cors, "Content-Type": "application/json" }
});
const encoder = new TextEncoder();
const hex = (bytes: Uint8Array) => Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("");
const randomHex = (length: number) => {
  const bytes = new Uint8Array(length); crypto.getRandomValues(bytes); return hex(bytes);
};
async function sha256(value: string) {
  return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value))));
}
async function pinHash(pin: string, salt: string) {
  const key = await crypto.subtle.importKey("raw", encoder.encode(pin), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", salt: encoder.encode(salt), iterations: 210000, hash: "SHA-256" }, key, 256
  );
  return hex(new Uint8Array(bits));
}
const validPin = (value: string) => /^\d{6}$/.test(value);
const validId = (value: string) => /^[0-9a-f-]{36}$/i.test(value);

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const db = createClient(url, serviceKey, { auth: { persistSession: false } });
  let body: any;
  try { body = await req.json(); } catch { return reply({ error: "Invalid JSON" }, 400); }
  const action = String(body?.action || "");

  // PIN login is the only unauthenticated action. Staff PINs are never Supabase Auth passwords.
  if (action === "login_pin") {
    const username = String(body?.username || "").trim().toLowerCase();
    const pin = String(body?.pin || "");
    if (!/^[a-z0-9._-]{3,24}$/.test(username) || !validPin(pin)) {
      return reply({ error: "Enter your username and 6-digit PIN." }, 400);
    }
    const { data: staff } = await db.from("staff_accounts")
      .select("user_id,username,display_name,active,pin_hash,pin_salt,failed_attempts,locked_until")
      .eq("username", username).maybeSingle();
    const now = Date.now();
    if (!staff || !staff.active || !staff.pin_hash || !staff.pin_salt ||
        (staff.locked_until && new Date(staff.locked_until).getTime() > now)) {
      return reply({ error: "Incorrect username or PIN, or account temporarily locked." }, 401);
    }
    const candidate = await pinHash(pin, staff.pin_salt);
    if (candidate !== staff.pin_hash) {
      const attempts = Number(staff.failed_attempts || 0) + 1;
      const lockedUntil = attempts >= 5 ? new Date(now + 15 * 60 * 1000).toISOString() : null;
      await db.from("staff_accounts").update({
        failed_attempts: lockedUntil ? 0 : attempts,
        locked_until: lockedUntil,
        updated_at: new Date().toISOString()
      }).eq("user_id", staff.user_id);
      return reply({ error: "Incorrect username or PIN, or account temporarily locked." }, 401);
    }
    await db.from("staff_accounts").update({
      failed_attempts: 0, locked_until: null, updated_at: new Date().toISOString()
    }).eq("user_id", staff.user_id);
    const sessionToken = randomHex(32);
    const expiresAt = new Date(now + 12 * 60 * 60 * 1000).toISOString();
    const { error: sessionError } = await db.from("staff_sessions").insert({
      user_id: staff.user_id, token_hash: await sha256(sessionToken), expires_at: expiresAt
    });
    if (sessionError) return reply({ error: "Could not start staff session. Try again." }, 500);
    return reply({ success: true, token: sessionToken, expires_at: expiresAt, staff: {
      user_id: staff.user_id, username: staff.username, display_name: staff.display_name
    }});
  }

  // Admin actions use a normal Supabase Auth JWT, checked manually because verify_jwt is off.
  const authorization = req.headers.get("Authorization") || "";
  const bearer = authorization.startsWith("Bearer ") ? authorization.slice(7) : "";
  let adminId: string | null = null;
  if (bearer) {
    const authClient = createClient(url, anonKey, { auth: { persistSession: false } });
    const { data: authData, error: authError } = await authClient.auth.getUser(bearer);
    if (!authError && authData.user) {
      const { data: profile } = await db.from("profiles").select("role")
        .eq("id", authData.user.id).maybeSingle();
      if (profile?.role === "admin") adminId = authData.user.id;
    }
  }

  // Staff actions use a separate random, revocable, expiring session token.
  const staffToken = req.headers.get("x-staff-session") || "";
  let staffActor: { id: string; display_name: string } | null = null;
  if (staffToken && staffToken.length === 64) {
    const { data: session } = await db.from("staff_sessions")
      .select("id,user_id,expires_at").eq("token_hash", await sha256(staffToken))
      .gt("expires_at", new Date().toISOString()).maybeSingle();
    if (session) {
      const { data: staff } = await db.from("staff_accounts")
        .select("user_id,display_name,active").eq("user_id", session.user_id).maybeSingle();
      if (staff?.active) staffActor = { id: staff.user_id, display_name: staff.display_name };
      else await db.from("staff_sessions").delete().eq("id", session.id);
    }
  }

  const isAdmin = !!adminId;
  if (action === "logout_pin") {
    if (!staffActor || !staffToken) return reply({ success: true });
    await db.from("staff_sessions").delete().eq("token_hash", await sha256(staffToken));
    return reply({ success: true });
  }
  if (action === "list_orders" || action === "handle_order") {
    if (!isAdmin && !staffActor) return reply({ error: "Staff session expired. Please sign in again." }, 401);
    if (action === "list_orders") {
      // Load the complete order history in stable pages for accurate repeat-customer counts.
      const data: any[] = [];
      const pageSize = 1000;
      for (let from = 0; ; from += pageSize) {
        const { data: page, error } = await db.from("orders")
          .select("id,order_number,customer_name,phone,city,address,total,status,created_at,order_items(id,product_name,quantity,line_total,variant_name)")
          .order("created_at", { ascending: false })
          .order("id", { ascending: false })
          .range(from, from + pageSize - 1);
        if (error) return reply({ error: "Could not load orders" }, 500);
        data.push(...(page || []));
        if (!page || page.length < pageSize) break;
      }
      const { data: followups, error: followupError } = await db.from("order_followups")
        .select("order_id,workflow_status,follow_up_at,updated_at")
        .eq("workflow_status", "call_later");
      if (followupError) return reply({ error: "Could not load follow-up orders" }, 500);
      return reply({ orders: data || [], followups: followups || [] });
    }
    const orderId = String(body?.order_id || "");
    const operation = String(body?.operation || "");
    if (!validId(orderId)) return reply({ error: "Invalid order" }, 400);
    if (!["confirm", "cancel", "call_later", "clear_call_later"].includes(operation)) return reply({ error: "Invalid action" }, 400);
    const { data: order } = await db.from("orders").select("id").eq("id", orderId).maybeSingle();
    if (!order) return reply({ error: "Order not found" }, 404);
    if (operation === "clear_call_later") {
      const { error } = await db.from("order_followups").delete().eq("order_id", orderId).eq("workflow_status", "call_later");
      if (error) return reply({ error: "Could not clear follow-up reminder" }, 500);
      return reply({ success: true, action: "follow_up_completed" });
    } else if (operation === "confirm" || operation === "cancel") {
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
    const actorId = isAdmin ? adminId! : staffActor!.id;
    const auditAction = operation === "confirm" ? "confirmed" : operation === "cancel" ? "cancelled" : "call_later";
    const { error: auditError } = await db.from("staff_order_audit").insert({
      order_id: orderId, staff_user_id: isAdmin ? null : actorId, actor_user_id: actorId,
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
    if (!validPin(pin)) return reply({ error: "PIN must be exactly 6 numbers." }, 400);
    const salt = randomHex(16), hash = await pinHash(pin, salt);
    const hiddenPassword = randomHex(32) + "Aa1!";
    const { data: created, error: createError } = await db.auth.admin.createUser({
      email: username + "@staff.widajewls.com", password: hiddenPassword, email_confirm: true,
      user_metadata: { full_name: displayName, account_type: "wida_staff" }
    });
    if (createError || !created.user) return reply({ error: createError?.message || "Could not create staff login" }, 400);
    const userId = created.user.id;
    const { error: profileError } = await db.from("profiles").upsert(
      { id: userId, full_name: displayName, role: "staff" }, { onConflict: "id" }
    );
    if (profileError) { await db.auth.admin.deleteUser(userId); return reply({ error: "Could not create staff profile" }, 500); }
    const { error: staffError } = await db.from("staff_accounts").insert({
      user_id: userId, username, display_name: displayName, created_by: adminId,
      pin_hash: hash, pin_salt: salt, failed_attempts: 0, locked_until: null
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
    if (!validId(userId) || !validPin(pin)) return reply({ error: "Enter a valid staff account and a 6-digit PIN." }, 400);
    const { data: target } = await db.from("staff_accounts").select("user_id").eq("user_id", userId).maybeSingle();
    if (!target) return reply({ error: "Staff account not found" }, 404);
    const salt = randomHex(16), hash = await pinHash(pin, salt);
    const { error } = await db.from("staff_accounts").update({
      pin_hash: hash, pin_salt: salt, failed_attempts: 0, locked_until: null, updated_at: new Date().toISOString()
    }).eq("user_id", userId);
    if (error) return reply({ error: "Could not reset PIN" }, 500);
    await db.from("staff_sessions").delete().eq("user_id", userId);
    return reply({ success: true });
  }
  if (action === "set_staff_active") {
    const userId = String(body?.user_id || ""), active = body?.active === true;
    const { data: target } = await db.from("staff_accounts").select("user_id").eq("user_id", userId).maybeSingle();
    if (!target) return reply({ error: "Staff account not found" }, 404);
    const { error } = await db.from("staff_accounts").update({ active, updated_at: new Date().toISOString() }).eq("user_id", userId);
    if (error) return reply({ error: "Could not update staff account" }, 500);
    if (!active) await db.from("staff_sessions").delete().eq("user_id", userId);
    return reply({ success: true, active });
  }
  return reply({ error: "Unknown action" }, 400);
});