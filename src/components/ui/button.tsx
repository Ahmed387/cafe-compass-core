import * as React from "react";
import { Slot } from "@radix-ui/react-slot";
import { cva, type VariantProps } from "class-variance-authority";
import type { LucideIcon } from "lucide-react";

import { actionIcon, plainText } from "@/lib/ui-icons";
import { cn } from "@/lib/utils";

const buttonVariants = cva(
  "inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-lg text-sm font-medium cursor-pointer select-none transition-all focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/60 focus-visible:ring-offset-1 focus-visible:ring-offset-background disabled:pointer-events-none disabled:opacity-50 disabled:cursor-not-allowed [&_svg]:pointer-events-none [&_svg]:size-4 [&_svg]:shrink-0",
  {
    variants: {
      variant: {
        default:
          "bg-primary bg-gradient-brand text-primary-foreground shadow-sm shadow-primary/25 hover:-translate-y-px hover:shadow-md hover:shadow-primary/30 hover:brightness-110",
        destructive:
          "bg-destructive text-destructive-foreground shadow-sm shadow-destructive/25 hover:-translate-y-px hover:bg-destructive/90 hover:shadow-md hover:shadow-destructive/30",
        outline:
          "border border-input bg-card shadow-xs hover:border-primary/40 hover:bg-tint hover:text-tint-foreground",
        secondary: "bg-secondary text-secondary-foreground shadow-xs hover:bg-secondary/70",
        ghost: "hover:bg-tint hover:text-tint-foreground",
        link: "text-primary underline-offset-4 hover:underline",
      },
      size: {
        default: "h-9 px-4 py-2",
        sm: "h-8 rounded-md px-3 text-xs [&_svg]:size-3.5",
        lg: "h-11 rounded-xl px-8 text-base",
        icon: "h-9 w-9",
      },
    },
    defaultVariants: {
      variant: "default",
      size: "default",
    },
  },
);

export interface ButtonProps
  extends React.ButtonHTMLAttributes<HTMLButtonElement>, VariantProps<typeof buttonVariants> {
  asChild?: boolean;
  /**
   * Leading icon. Text-only buttons get one automatically from their label
   * ("Save" → disk, "حذف" → trash, "Saving…" → spinner); pass `false` to opt out.
   */
  icon?: LucideIcon | false;
}

const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant, size, asChild = false, icon, children, ...props }, ref) => {
    const Comp = asChild ? Slot : "button";
    let lead: React.ReactNode = null;
    if (!asChild && size !== "icon" && variant !== "link" && icon !== false) {
      if (icon) {
        const Icon = icon;
        lead = <Icon aria-hidden />;
      } else {
        const text = plainText(children);
        const found = text ? actionIcon(text) : null;
        if (found) {
          const Icon = found.icon;
          lead = (
            <Icon
              aria-hidden
              className={cn(found.spin && "animate-spin", found.flip && "rtl:-scale-x-100")}
            />
          );
        }
      }
    }
    return (
      <Comp
        data-slot="button"
        className={cn(buttonVariants({ variant, size, className }))}
        ref={ref}
        {...props}
      >
        {asChild ? (
          children
        ) : (
          <>
            {lead}
            {children}
          </>
        )}
      </Comp>
    );
  },
);
Button.displayName = "Button";

export { Button, buttonVariants };
