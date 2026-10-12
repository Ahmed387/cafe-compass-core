import { Minus, Plus, RotateCcw, X } from "lucide-react";
import { useCallback, useEffect, useState, type ReactNode } from "react";

import { useI18n } from "@/lib/i18n";

const MIN_ZOOM = 1;
const MAX_ZOOM = 4;

/**
 * Shared full-screen image viewer.
 * - closes on backdrop click and on Escape
 * - zoom in / out / reset controls (also mouse wheel)
 */
export function ImageLightbox({
  src,
  alt,
  open,
  onClose,
}: {
  src: string | null | undefined;
  alt?: string | undefined;
  open: boolean;
  onClose: () => void;
}) {
  const { t } = useI18n();
  const [zoom, setZoom] = useState(1);

  const clamp = (value: number) => Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, value));

  useEffect(() => {
    if (open) setZoom(1);
  }, [open, src]);

  useEffect(() => {
    if (!open) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
      if (event.key === "+" || event.key === "=") setZoom((z) => clamp(z + 0.5));
      if (event.key === "-") setZoom((z) => clamp(z - 0.5));
    };
    window.addEventListener("keydown", onKey);
    const previous = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      window.removeEventListener("keydown", onKey);
      document.body.style.overflow = previous;
    };
  }, [open, onClose]);

  if (!open || !src) return null;

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label={alt ?? t("img.viewer")}
      className="fixed inset-0 z-[100] flex animate-fade-in items-center justify-center bg-foreground/80 p-4 backdrop-blur-sm"
      onClick={onClose}
    >
      <div
        className="absolute top-4 end-4 flex items-center gap-1.5"
        onClick={(event) => event.stopPropagation()}
      >
        <LightboxButton label={t("img.zoomOut")} onClick={() => setZoom((z) => clamp(z - 0.5))}>
          <Minus className="size-4" />
        </LightboxButton>
        <span className="rounded-lg bg-background/90 px-2 py-1 text-xs font-semibold tabular-nums">
          {Math.round(zoom * 100)}%
        </span>
        <LightboxButton label={t("img.zoomIn")} onClick={() => setZoom((z) => clamp(z + 0.5))}>
          <Plus className="size-4" />
        </LightboxButton>
        <LightboxButton label={t("img.reset")} onClick={() => setZoom(1)}>
          <RotateCcw className="size-4" />
        </LightboxButton>
        <LightboxButton label={t("common.close")} onClick={onClose}>
          <X className="size-4" />
        </LightboxButton>
      </div>

      <img
        src={src}
        alt={alt ?? ""}
        onClick={(event) => event.stopPropagation()}
        onWheel={(event) => {
          event.preventDefault();
          setZoom((z) => clamp(z + (event.deltaY < 0 ? 0.25 : -0.25)));
        }}
        style={{ transform: `scale(${zoom})` }}
        className="max-h-[85vh] max-w-[92vw] animate-scale-in rounded-xl object-contain shadow-2xl transition-transform duration-200"
      />
    </div>
  );
}

function LightboxButton({
  label,
  onClick,
  children,
}: {
  label: string;
  onClick: () => void;
  children: ReactNode;
}) {
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      onClick={onClick}
      className="flex size-9 items-center justify-center rounded-lg bg-background/90 text-foreground shadow-lg transition-colors hover:bg-background"
    >
      {children}
    </button>
  );
}

/**
 * Clickable thumbnail that opens the shared lightbox.
 * Renders a neutral placeholder when there is no image.
 */
export function ImageThumb({
  src,
  alt,
  className = "size-10",
  imgClassName,
  placeholder,
}: {
  src: string | null | undefined;
  alt?: string | undefined;
  className?: string;
  imgClassName?: string | undefined;
  placeholder?: ReactNode;
}) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);

  const onOpen = useCallback(() => setOpen(true), []);

  if (!src) {
    return (
      <div
        className={`overflow-hidden rounded-lg border border-border bg-muted ${className}`}
        aria-hidden
      >
        {placeholder}
      </div>
    );
  }

  return (
    <>
      <button
        type="button"
        onClick={(event) => {
          event.stopPropagation();
          onOpen();
        }}
        aria-label={t("img.open")}
        title={t("img.open")}
        className={`group overflow-hidden rounded-lg border border-border bg-muted transition-transform duration-200 hover:scale-105 hover:shadow-lg ${className}`}
      >
        <img
          src={src}
          alt={alt ?? ""}
          loading="lazy"
          className={imgClassName ?? "size-full object-cover"}
        />
      </button>
      <ImageLightbox src={src} alt={alt} open={open} onClose={() => setOpen(false)} />
    </>
  );
}
