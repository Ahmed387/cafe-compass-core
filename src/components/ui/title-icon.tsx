import type { LucideIcon } from "lucide-react";
import type { ReactNode } from "react";

import { plainText, titleIcon } from "@/lib/ui-icons";

/**
 * Title content for dialogs and sheets: a text-only title gets a small icon chip
 * in the current module's colours, picked from its wording. Titles that already
 * render their own markup are left untouched.
 */
export function TitleWithIcon({
  children,
  fallback,
}: {
  children: ReactNode;
  fallback?: LucideIcon;
}) {
  const text = plainText(children);
  const Icon = text ? (titleIcon(text) ?? fallback) : null;
  if (!Icon) return <>{children}</>;
  return (
    <>
      <span className="icon-chip-soft size-8 animate-pop-in" aria-hidden>
        <Icon className="size-4" />
      </span>
      <span className="min-w-0">{children}</span>
    </>
  );
}
