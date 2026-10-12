import type { LucideIcon } from "lucide-react";
import type { ReactNode } from "react";

import { topicIcon } from "@/lib/ui-icons";
import { cn } from "@/lib/utils";

/** Section heading inside a page: module-coloured icon chip + bold title. */
export function SectionTitle({
  children,
  icon,
  as: Tag = "h2",
  className,
}: {
  children: string;
  icon?: LucideIcon;
  as?: "h2" | "h3" | "p";
  className?: string;
}) {
  const Icon = icon ?? topicIcon(children);
  return (
    <Tag className={cn("flex items-center gap-2 font-bold", className)}>
      {Icon && (
        <span className="icon-chip-soft size-7" aria-hidden>
          <Icon className="size-3.5" />
        </span>
      )}
      <span className="min-w-0">{children}</span>
    </Tag>
  );
}

export function SectionHint({ children }: { children: ReactNode }) {
  return <p className="text-xs text-muted-foreground">{children}</p>;
}
