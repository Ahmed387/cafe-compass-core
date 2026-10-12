import { CircleHelp } from "lucide-react";
import type { ReactNode } from "react";

import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip";
import { cn } from "@/lib/utils";

/** Small (?) icon that opens a friendly plain-language explanation on click/tap. */
export function InfoTip({ children, title, className }: { children: ReactNode; title?: ReactNode; className?: string }) {
  return (
    <Popover>
      <TooltipProvider delayDuration={250}>
        <Tooltip>
          <TooltipTrigger asChild>
            <PopoverTrigger asChild>
              <button
                type="button"
                aria-label="شرح"
                onClick={(e) => e.stopPropagation()}
                className={cn("inline-grid size-5 shrink-0 place-items-center rounded-full text-muted-foreground transition-colors hover:bg-muted hover:text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring", className)}
              >
                <CircleHelp className="size-3.5" />
              </button>
            </PopoverTrigger>
          </TooltipTrigger>
          <TooltipContent className="max-w-64 text-center leading-relaxed">
            {title && <span className="font-bold">{title} </span>}{children}
          </TooltipContent>
        </Tooltip>
      </TooltipProvider>
      <PopoverContent dir="rtl" className="w-72 text-sm leading-relaxed" onClick={(e) => e.stopPropagation()}>
        {title && <p className="mb-1 font-semibold text-foreground">{title}</p>}
        <div className="text-muted-foreground">{children}</div>
      </PopoverContent>
    </Popover>
  );
}
