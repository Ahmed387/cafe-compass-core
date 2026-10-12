import * as React from "react";
import * as TabsPrimitive from "@radix-ui/react-tabs";

import { plainText, topicIcon } from "@/lib/ui-icons";
import { cn } from "@/lib/utils";

const Tabs = TabsPrimitive.Root;

const TabsList = React.forwardRef<
  React.ElementRef<typeof TabsPrimitive.List>,
  React.ComponentPropsWithoutRef<typeof TabsPrimitive.List>
>(({ className, ...props }, ref) => (
  <TabsPrimitive.List
    ref={ref}
    className={cn(
      "inline-flex h-10 items-center justify-center gap-0.5 rounded-xl border border-border/60 bg-muted/70 p-1 text-muted-foreground shadow-inner shadow-black/[0.02]",
      className,
    )}
    {...props}
  />
));
TabsList.displayName = TabsPrimitive.List.displayName;

const TabsTrigger = React.forwardRef<
  React.ElementRef<typeof TabsPrimitive.Trigger>,
  React.ComponentPropsWithoutRef<typeof TabsPrimitive.Trigger>
>(({ className, children, ...props }, ref) => {
  const text = plainText(children);
  const Icon = text ? topicIcon(text) : null;
  return (
    <TabsPrimitive.Trigger
      ref={ref}
      className={cn(
        "group/tab inline-flex items-center justify-center gap-1.5 whitespace-nowrap rounded-lg px-3 py-1 text-sm font-medium ring-offset-background cursor-pointer transition-all duration-300 ease-[var(--ease-out)] hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 disabled:pointer-events-none disabled:opacity-50 disabled:cursor-not-allowed data-[state=active]:bg-card data-[state=active]:font-semibold data-[state=active]:text-foreground data-[state=active]:shadow-sm data-[state=active]:ring-1 data-[state=active]:ring-border/60",
        className,
      )}
      {...props}
    >
      {Icon && (
        <Icon
          aria-hidden
          className="hidden size-3.5 transition-all duration-300 group-data-[state=active]/tab:scale-110 group-data-[state=active]/tab:text-[color-mix(in_oklab,var(--module-from)_85%,var(--foreground))] sm:inline"
        />
      )}
      {children}
    </TabsPrimitive.Trigger>
  );
});
TabsTrigger.displayName = TabsPrimitive.Trigger.displayName;

const TabsContent = React.forwardRef<
  React.ElementRef<typeof TabsPrimitive.Content>,
  React.ComponentPropsWithoutRef<typeof TabsPrimitive.Content>
>(({ className, ...props }, ref) => (
  <TabsPrimitive.Content
    ref={ref}
    className={cn(
      "mt-2 ring-offset-background data-[state=active]:animate-tab-in focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2",
      className,
    )}
    {...props}
  />
));
TabsContent.displayName = TabsPrimitive.Content.displayName;

export { Tabs, TabsList, TabsTrigger, TabsContent };
