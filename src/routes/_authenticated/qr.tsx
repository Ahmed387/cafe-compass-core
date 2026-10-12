import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { toast } from "sonner";

import { EmptyState, NoPermission, PageHeader } from "@/components/layout/AppShell";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { useAuth } from "@/lib/auth";
import { friendlyError } from "@/lib/format";
import { useI18n } from "@/lib/i18n";
import { printMenuPoster, qrDataUrl } from "@/lib/labels";

export const Route = createFileRoute("/_authenticated/qr")({
  head: () => ({
    meta: [
      { title: "QR menu — 20s Coffee" },
      {
        name: "description",
        content: "Print the QR code that opens the public 20s Coffee menu for guests.",
      },
      { property: "og:title", content: "QR menu — 20s Coffee" },
      { property: "og:description", content: "QR menu poster for your café." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: QrPage,
});

function QrPage() {
  const { t, lang } = useI18n();
  const { can, me, currentBranchId } = useAuth();
  const company = me?.company ?? null;
  const branches = me?.branches ?? [];
  const [selectedBranch, setSelectedBranch] = useState<string>(currentBranchId ?? "");
  const [preview, setPreview] = useState<string>("");

  const allowed = can("settings.view") || can("products.view");

  useEffect(() => {
    if (!selectedBranch && currentBranchId) setSelectedBranch(currentBranchId);
  }, [currentBranchId, selectedBranch]);

  const menuUrl =
    typeof window !== "undefined" && selectedBranch ? `${window.location.origin}/menu` : "";

  useEffect(() => {
    if (!menuUrl) return;
    let active = true;
    qrDataUrl(menuUrl)
      .then((url) => {
        if (active) setPreview(url);
      })
      .catch(() => setPreview(""));
    return () => {
      active = false;
    };
  }, [menuUrl]);


  if (!allowed) return <NoPermission message={t("common.noAccess")} />;

  const branchName = branches.find((b) => b.id === selectedBranch)?.name ?? "";

  const printPoster = async () => {
    try {
      const ok = await printMenuPoster({
        url: menuUrl,
        companyName: "20s SPECIALTY COFFEE",
        branchName,
        headline: t("qr.posterHeadline"),
        hint: t("qr.posterHint"),
        lang,
      });
      if (!ok) toast.error(t("qr.popupBlocked"));
    } catch (error) {
      toast.error(friendlyError(error, lang));
    }
  };

  return (
    <div className="space-y-6">
      <PageHeader title={t("qr.title")} description={t("qr.subtitle")} />

      <Card className="mx-auto w-full max-w-xl shadow-elegant">
        <CardHeader>
          <CardTitle>{t("qr.menuQr")}</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          {branches.length > 1 && (
            <div className="space-y-2">
              <Label>{t("common.branch")}</Label>
              <Select value={selectedBranch} onValueChange={setSelectedBranch}>
                <SelectTrigger>
                  <SelectValue placeholder={t("common.branch")} />
                </SelectTrigger>
                <SelectContent>
                  {branches.map((b) => (
                    <SelectItem key={b.id} value={b.id}>
                      {b.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          )}

          {preview ? (
            <div className="flex flex-col items-center gap-4 rounded-2xl bg-muted/40 p-6">
              <img src={preview} alt={t("qr.menuQr")} className="size-56 rounded-xl bg-card p-3 shadow-card" />
              <a
                href={menuUrl}
               
                rel="noreferrer"
                className="break-all text-xs text-primary underline"
              >
                {menuUrl}
              </a>
            </div>
          ) : (
            <EmptyState message={t("qr.selectBranch")} />
          )}

          <div className="flex flex-wrap justify-center gap-2">
            <Button onClick={printPoster} disabled={!menuUrl}>
              {t("qr.printPoster")}
            </Button>
            <Button
              variant="outline"
              disabled={!menuUrl}
              onClick={async () => {
                await navigator.clipboard?.writeText(menuUrl);
                toast.success(t("qr.linkCopied"));
              }}
            >
              {t("qr.copyLink")}
            </Button>
          </div>
        </CardContent>
      </Card>

    </div>
  );
}
