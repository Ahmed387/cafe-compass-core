import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/lib/auth";

export type AppNotification = {
  id: string;
  title: string;
  body: string | null;
  severity: string;
  type: string;
  read_at: string | null;
  created_at: string;
  data: Record<string, unknown> | null;
};

export function useNotifications() {
  const { me } = useAuth();
  const queryClient = useQueryClient();

  const { data } = useQuery({
    queryKey: ["notifications", me?.profile.id],
    enabled: Boolean(me),
    queryFn: async () => {
      const { data, error } = await supabase
        .from("notifications")
        .select("id, title, body, severity, type, read_at, created_at, data")
        .order("created_at", { ascending: false })
        .limit(30);
      if (error) throw error;
      return (data ?? []) as AppNotification[];
    },
  });

  // The same event can be stored twice (once for the owner, once for a
  // permission audience), so collapse identical entries before display.
  const seen = new Set<string>();
  const notifications = (data ?? []).filter((n) => {
    const key = `${n.type}|${n.title}|${n.created_at}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });

  const invalidate = () => queryClient.invalidateQueries({ queryKey: ["notifications"] });

  const markAllRead = useMutation({
    mutationFn: async () => {
      const ids = notifications.filter((n) => !n.read_at).map((n) => n.id);
      if (!ids.length) return;
      const { error } = await supabase
        .from("notifications")
        .update({ read_at: new Date().toISOString() })
        .in("id", ids);
      if (error) throw error;
    },
    onSuccess: invalidate,
  });

  const dismiss = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from("notifications").delete().eq("id", id);
      if (error) throw error;
    },
    onSuccess: invalidate,
  });

  const markRead = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase
        .from("notifications")
        .update({ read_at: new Date().toISOString() })
        .eq("id", id);
      if (error) throw error;
    },
    onSuccess: invalidate,
  });

  const clearAll = useMutation({
    mutationFn: async () => {
      const ids = (data ?? []).map((n) => n.id);
      if (!ids.length) return;
      const { error } = await supabase.from("notifications").delete().in("id", ids);
      if (error) throw error;
    },
    onSuccess: invalidate,
  });

  return {
    notifications,
    unread: notifications.filter((n) => !n.read_at).length,
    markAllRead: () => markAllRead.mutate(),
    markRead: (id: string) => markRead.mutate(id),
    dismiss: (id: string) => dismiss.mutate(id),
    clearAll: () => clearAll.mutate(),
  };
}
