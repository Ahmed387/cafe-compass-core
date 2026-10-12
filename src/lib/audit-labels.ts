/** Shared, human-friendly wording for audit-log rows (page + dashboard card). */
export type Translate = (key: string) => string;

export function humanizeAudit(value: string) {
  return value
    .replace(/[._]/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase())
    .trim();
}

export function auditLabels(t: Translate) {
  const viaKey = (key: string, fallback: string) => {
    const label = t(key);
    return label === key ? humanizeAudit(fallback) : label;
  };

  return {
    action: (action: string) => viaKey(`audit.act.${action}`, action),
    module: (module: string) => viaKey(`audit.mod.${module}`, module),
    entity: (entity: string | null, id: string | null) => {
      if (!entity) return "—";
      const name = viaKey(`audit.ent.${entity}`, entity);
      return id ? `${name} · ${id.slice(0, 8)}` : name;
    },
    tone: (action: string) => {
      if (/(cancel|void|refund|delete|waste|close|disable)/.test(action))
        return "destructive" as const;
      if (/(create|open|receive|approve|clock_in|login|adjust|enable)/.test(action))
        return "secondary" as const;
      return "outline" as const;
    },
  };
}
