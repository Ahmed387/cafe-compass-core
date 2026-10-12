import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";

import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import { ROOT_ADMIN_EMAIL } from "@/lib/root-admin";

const fileInput = z.object({
  name: z.string().min(1),
  mime: z.string().min(1),
  data: z.string().min(1), // base64, no data-url prefix
});

const createUserInput = z.object({
  email: z.string().email(),
  password: z.string().min(8),
  first_name: z.string().min(1),
  last_name: z.string().optional().default(""),
  phone: z.string().optional().default(""),
  employee_code: z.string().optional().default(""),
  preferred_language: z.enum(["ar", "en"]).default("en"),
  role_ids: z.array(z.string().uuid()).default([]),
  branch_ids: z.array(z.string().uuid()).default([]),
  id_front: fileInput,
  id_back: fileInput,
});

/** Creates a login account plus its company profile, roles and branch access. */
export const createCompanyUser = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: unknown) => createUserInput.parse(data))
  .handler(async ({ data, context }) => {
    const { data: allowed } = await context.supabase.rpc("has_permission", {
      _key: "users.create",
    });
    if (!allowed) throw new Error("not authorized");

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

    const { data: profile, error: profileError } = await supabaseAdmin
      .from("user_profiles")
      .insert({
        auth_user_id: authUserId,
        company_id: actor.company_id,
        first_name: data.first_name,
        last_name: data.last_name || null,
        display_name: `${data.first_name} ${data.last_name ?? ""}`.trim(),
        email: data.email,
        phone: data.phone || null,
        employee_code: data.employee_code || null,
        preferred_language: data.preferred_language,
      })
      .select("id")
      .single();
    if (profileError) {
      await supabaseAdmin.auth.admin.deleteUser(authUserId);
      throw new Error(profileError.message);
    }

    if (data.role_ids.length) {
      await supabaseAdmin
        .from("user_roles")
        .insert(data.role_ids.map((role_id) => ({ user_id: profile.id, role_id })));
    }
    if (data.branch_ids.length) {
      await supabaseAdmin.from("user_branches").insert(
        data.branch_ids.map((branch_id, index) => ({
          user_id: profile.id,
          branch_id,
          is_default: index === 0,
        })),
      );
    }

    // Mandatory ID card attachments (front + back).
    const documents = [
      { kind: "id_front" as const, file: data.id_front },
      { kind: "id_back" as const, file: data.id_back },
    ];
    for (const doc of documents) {
      const extension = doc.file.name.split(".").pop()?.toLowerCase() || "jpg";
      const path = `${actor.company_id}/${profile.id}/${doc.kind}-${Date.now()}.${extension}`;
      const bytes = Buffer.from(doc.file.data, "base64");
      const upload = await supabaseAdmin.storage
        .from("staff-documents")
        .upload(path, bytes, { contentType: doc.file.mime, upsert: true });
      if (upload.error) throw new Error(upload.error.message);
      const inserted = await supabaseAdmin.from("user_documents").insert({
        company_id: actor.company_id,
        user_id: profile.id,
        kind: doc.kind,
        file_path: path,
        mime_type: doc.file.mime,
        created_by: actor.id,
      });
      if (inserted.error) throw new Error(inserted.error.message);
    }

    await supabaseAdmin.from("audit_logs").insert({
      company_id: actor.company_id,
      user_id: actor.id,
      action: "user.create",
      module: "users",
      entity_type: "user_profiles",
      entity_id: profile.id,
      new_values: { email: data.email, role_ids: data.role_ids, branch_ids: data.branch_ids },
    });

    return { id: profile.id };
  });

const createEmployeeInput = z.object({
  first_name: z.string().min(1),
  last_name: z.string().optional().default(""),
  phone: z.string().optional().default(""),
  employee_code: z.string().optional().default(""),
  id_front: fileInput,
  id_back: fileInput,
});

/** Creates an HR-only employee record (no login account) for staff who never use the cashier. */
export const createEmployeeRecord = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: unknown) => createEmployeeInput.parse(data))
  .handler(async ({ data, context }) => {
    const { data: allowed } = await context.supabase.rpc("has_permission", {
      _key: "users.create",
    });
    if (!allowed) throw new Error("not authorized");

    const { data: actor } = await context.supabase
      .from("user_profiles")
      .select("id, company_id")
      .eq("auth_user_id", context.userId)
      .maybeSingle();
    if (!actor) throw new Error("not authorized");

    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");

    const { data: profile, error: profileError } = await supabaseAdmin
      .from("user_profiles")
      .insert({
        auth_user_id: null,
        company_id: actor.company_id,
        first_name: data.first_name,
        last_name: data.last_name || null,
        display_name: `${data.first_name} ${data.last_name ?? ""}`.trim(),
        email: null,
        phone: data.phone || null,
        employee_code: data.employee_code || null,
        preferred_language: "ar",
      })
      .select("id")
      .single();
    if (profileError) throw new Error(profileError.message);

    for (const doc of [
      { kind: "id_front" as const, file: data.id_front },
      { kind: "id_back" as const, file: data.id_back },
    ]) {
      const extension = doc.file.name.split(".").pop()?.toLowerCase() || "jpg";
      const path = `${actor.company_id}/${profile.id}/${doc.kind}-${Date.now()}.${extension}`;
      const upload = await supabaseAdmin.storage
        .from("staff-documents")
        .upload(path, Buffer.from(doc.file.data, "base64"), {
          contentType: doc.file.mime,
          upsert: true,
        });
      if (upload.error) throw new Error(upload.error.message);
      const inserted = await supabaseAdmin.from("user_documents").insert({
        company_id: actor.company_id,
        user_id: profile.id,
        kind: doc.kind,
        file_path: path,
        mime_type: doc.file.mime,
        created_by: actor.id,
      });
      if (inserted.error) throw new Error(inserted.error.message);
    }

    await supabaseAdmin.from("audit_logs").insert({
      company_id: actor.company_id,
      user_id: actor.id,
      action: "employee.create",
      module: "users",
      entity_type: "user_profiles",
      entity_id: profile.id,
      new_values: { first_name: data.first_name, login: false },
    });

    return { id: profile.id };
  });

/** Enables or disables a user's access without deleting any records. */
export const setUserActive = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: unknown) =>
    z.object({ user_id: z.string().uuid(), is_active: z.boolean() }).parse(data),
  )
  .handler(async ({ data, context }) => {
    const { data: allowed } = await context.supabase.rpc("has_permission", {
      _key: "users.disable",
    });
    if (!allowed) throw new Error("not authorized");

    const { data: actor } = await context.supabase
      .from("user_profiles")
      .select("id, company_id")
      .eq("auth_user_id", context.userId)
      .maybeSingle();
    if (!actor) throw new Error("not authorized");

    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");

    const { data: target } = await supabaseAdmin
      .from("user_profiles")
      .select("id, company_id, is_active, auth_user_id")
      .eq("id", data.user_id)
      .maybeSingle();
    if (!target || target.company_id !== actor.company_id) throw new Error("not found");
    if (target.auth_user_id === context.userId) throw new Error("cannot disable your own account");

    const { error } = await supabaseAdmin
      .from("user_profiles")
      .update({ is_active: data.is_active })
      .eq("id", data.user_id);
    if (error) throw new Error(error.message);

    await supabaseAdmin.from("audit_logs").insert({
      company_id: actor.company_id,
      user_id: actor.id,
      action: data.is_active ? "user.enable" : "user.disable",
      module: "users",
      entity_type: "user_profiles",
      entity_id: data.user_id,
      old_values: { is_active: target.is_active },
      new_values: { is_active: data.is_active },
    });

    return { ok: true };
  });
/** Returns short-lived signed links for an employee's ID attachments. */
export const getUserDocuments = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: unknown) => z.object({ user_id: z.string().uuid() }).parse(data))
  .handler(async ({ data, context }) => {
    const { data: rows, error } = await context.supabase
      .from("user_documents")
      .select("id, kind, file_path, mime_type, created_at")
      .eq("user_id", data.user_id)
      .order("created_at");
    if (error) throw new Error(error.message);

    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
    const out: Array<{ id: string; kind: string; url: string | null; created_at: string }> = [];
    for (const row of rows ?? []) {
      const signed = await supabaseAdmin.storage
        .from("staff-documents")
        .createSignedUrl(row.file_path, 600);
      out.push({
        id: row.id,
        kind: row.kind,
        url: signed.data?.signedUrl ?? null,
        created_at: row.created_at,
      });
    }
    return out;
  });

/** Adds or replaces one ID attachment for an existing employee. */
export const uploadUserDocument = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: unknown) =>
    z
      .object({
        user_id: z.string().uuid(),
        kind: z.enum(["id_front", "id_back", "other"]),
        file: fileInput,
      })
      .parse(data),
  )
  .handler(async ({ data, context }) => {
    const { data: allowed } = await context.supabase.rpc("has_permission", {
      _key: "users.update",
    });
    if (!allowed) throw new Error("not authorized");

    const { data: actor } = await context.supabase
      .from("user_profiles")
      .select("id, company_id")
      .eq("auth_user_id", context.userId)
      .maybeSingle();
    if (!actor) throw new Error("not authorized");

    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
    const { data: target } = await supabaseAdmin
      .from("user_profiles")
      .select("id, company_id")
      .eq("id", data.user_id)
      .maybeSingle();
    if (!target || target.company_id !== actor.company_id) throw new Error("not found");

    const extension = data.file.name.split(".").pop()?.toLowerCase() || "jpg";
    const path = `${actor.company_id}/${data.user_id}/${data.kind}-${Date.now()}.${extension}`;
    const upload = await supabaseAdmin.storage
      .from("staff-documents")
      .upload(path, Buffer.from(data.file.data, "base64"), {
        contentType: data.file.mime,
        upsert: true,
      });
    if (upload.error) throw new Error(upload.error.message);

    if (data.kind !== "other") {
      await supabaseAdmin
        .from("user_documents")
        .delete()
        .eq("user_id", data.user_id)
        .eq("kind", data.kind);
    }
    const inserted = await supabaseAdmin.from("user_documents").insert({
      company_id: actor.company_id,
      user_id: data.user_id,
      kind: data.kind,
      file_path: path,
      mime_type: data.file.mime,
      created_by: actor.id,
    });
    if (inserted.error) throw new Error(inserted.error.message);
    return { ok: true };
  });

/** Permanently removes a user (Super Admin only) after the database clears every safety check. */
export const deleteCompanyUser = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: unknown) => z.object({ user_id: z.string().uuid() }).parse(data))
  .handler(async ({ data, context }) => {
    // All authorization, owner protection and financial-history checks live in the RPC.
    // Users with history are archived (deactivated, roles removed) instead of deleted.
    const { data: result, error } = await context.supabase.rpc("remove_user_by_admin" as never, {
      p_target_user_id: data.user_id,
    } as never);
    if (error) throw new Error((error as { message: string }).message);
    const r = result as unknown as { mode: "deleted" | "archived"; auth_user_id: string | null };

    if (r.auth_user_id) {
      const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
      if (r.mode === "deleted") await supabaseAdmin.auth.admin.deleteUser(r.auth_user_id);
      else await supabaseAdmin.auth.admin.updateUserById(r.auth_user_id, { ban_duration: "876000h" });
    }
    return { ok: true, mode: r.mode };
  });

/** Sets a new login password for a teammate; requires the users.edit permission. */
export const setUserPassword = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: unknown) =>
    z.object({ user_id: z.string().uuid(), password: z.string().min(8) }).parse(data),
  )
  .handler(async ({ data, context }) => {
    const { data: allowed } = await context.supabase.rpc("has_permission", {
      _key: "users.edit",
    });
    if (!allowed) throw new Error("not authorized");

    const { data: actor } = await context.supabase
      .from("user_profiles")
      .select("id, company_id")
      .eq("auth_user_id", context.userId)
      .maybeSingle();
    if (!actor) throw new Error("not authorized");

    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");

    const { data: target } = await supabaseAdmin
      .from("user_profiles")
      .select("id, company_id, auth_user_id")
      .eq("id", data.user_id)
      .maybeSingle();
    if (!target || target.company_id !== actor.company_id) throw new Error("not found");
    if (!target.auth_user_id) throw new Error("this teammate has no login account");

    const { error } = await supabaseAdmin.auth.admin.updateUserById(target.auth_user_id, {
      password: data.password,
    });
    if (error) throw new Error(error.message);

    await supabaseAdmin.from("audit_logs").insert({
      company_id: actor.company_id,
      user_id: actor.id,
      action: "user.password_reset",
      module: "users",
      entity_type: "user_profiles",
      entity_id: data.user_id,
    });

    return { ok: true };
  });

/** Removes one employee attachment: the database row (audited RPC) and its stored file. */
export const deleteUserDocument = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: unknown) => z.object({ doc_id: z.string().uuid() }).parse(data))
  .handler(async ({ data, context }) => {
    const { data: path, error } = await context.supabase.rpc("delete_user_document", {
      _doc_id: data.doc_id,
    });
    if (error) throw new Error(error.message);
    if (path) {
      const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
      await supabaseAdmin.storage.from("staff-documents").remove([path as string]);
    }
    return { ok: true };
  });

/**
 * Super Admin: change a teammate's email. Updates the login account (already confirmed,
 * so they can sign in straight away) and the profile together. The root owner is protected.
 */
export const setUserEmail = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: unknown) =>
    z.object({ user_id: z.string().uuid(), email: z.string().trim().toLowerCase().email() }).parse(data),
  )
  .handler(async ({ data, context }) => {
    const { data: isSuper } = await context.supabase.rpc("is_super_admin");
    if (!isSuper) throw new Error("not authorized");

    const { data: actor } = await context.supabase
      .from("user_profiles")
      .select("id, company_id")
      .eq("auth_user_id", context.userId)
      .maybeSingle();
    if (!actor) throw new Error("not authorized");

    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
    const { data: target } = await supabaseAdmin
      .from("user_profiles")
      .select("id, company_id, auth_user_id, email")
      .eq("id", data.user_id)
      .maybeSingle();
    if (!target || target.company_id !== actor.company_id) throw new Error("not found");
    if ((target.email ?? "").toLowerCase() === ROOT_ADMIN_EMAIL) throw new Error("The owner account email can't be changed here");
    if ((target.email ?? "").toLowerCase() === data.email) return { ok: true };

    const { data: taken } = await supabaseAdmin
      .from("user_profiles")
      .select("id")
      .eq("company_id", actor.company_id)
      .ilike("email", data.email)
      .neq("id", target.id)
      .maybeSingle();
    if (taken) throw new Error("This email is already used by another teammate");

    if (target.auth_user_id) {
      const { error } = await supabaseAdmin.auth.admin.updateUserById(target.auth_user_id, {
        email: data.email,
        email_confirm: true,
      });
      if (error) throw new Error(error.message);
    }
    const { error: profileError } = await supabaseAdmin
      .from("user_profiles")
      .update({ email: data.email, updated_at: new Date().toISOString() })
      .eq("id", target.id);
    if (profileError) throw new Error(profileError.message);

    await supabaseAdmin.from("audit_logs").insert({
      company_id: actor.company_id,
      user_id: actor.id,
      action: "user.email_change",
      module: "users",
      entity_type: "user_profiles",
      entity_id: target.id,
      old_values: { email: target.email },
      new_values: { email: data.email },
    });
    return { ok: true };
  });
