import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";

import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";

const input = z.object({
  partner_id: z.string().uuid(),
  email: z.string().trim().email().max(255),
  password: z.string().min(8).max(72),
  name: z.string().trim().min(1).max(100),
});

/** Super Admin only: creates a login for a partner and links it to the partner record. */
export const createPartnerLogin = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: unknown) => input.parse(data))
  .handler(async ({ data, context }) => {
    const { data: isSuper } = await context.supabase.rpc("is_super_admin");
    if (!isSuper) throw new Error("Only the Super Admin can create partner logins");

    const { data: actor } = await context.supabase
      .from("user_profiles")
      .select("id, company_id")
      .eq("auth_user_id", context.userId)
      .maybeSingle();
    if (!actor) throw new Error("not authorized");

    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
    const created = await supabaseAdmin.auth.admin.createUser({
      email: data.email,
      password: data.password,
      email_confirm: true,
    });
    if (created.error || !created.data.user) {
      throw new Error(created.error?.message ?? "could not create account");
    }
    const authUserId = created.data.user.id;
    const [first, ...rest] = data.name.split(" ");
    const { error: profileError } = await supabaseAdmin.from("user_profiles").insert({
      auth_user_id: authUserId,
      company_id: actor.company_id,
      first_name: first ?? data.name,
      last_name: rest.join(" ") || null,
      display_name: data.name,
      email: data.email,
      preferred_language: "ar",
    });
    if (profileError) {
      await supabaseAdmin.auth.admin.deleteUser(authUserId);
      throw new Error(profileError.message);
    }

    // Link through the audited Super Admin RPC (also grants the partner role).
    const { error: linkError } = await context.supabase.rpc("link_partner_account", {
      _partner_id: data.partner_id,
      _email: data.email,
    });
    if (linkError) throw new Error(linkError.message);
    return { ok: true };
  });
