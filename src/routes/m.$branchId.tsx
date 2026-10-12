import { createFileRoute, notFound } from "@tanstack/react-router";
import { Coffee } from "lucide-react";
import { useState } from "react";

import { formatMoney } from "@/lib/format";
import { getPublicMenu } from "@/lib/public-menu.functions";

export const Route = createFileRoute("/m/$branchId")({
  loader: async ({ params }) => {
    // A malformed link is a missing menu, not a server error.
    const isUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
      params.branchId,
    );
    if (!isUuid) throw notFound();
    const menu = await getPublicMenu({ data: { branchId: params.branchId } });
    if (!menu) throw notFound();
    return menu;
  },
  head: ({ loaderData }) => {
    const name = loaderData?.company?.name ?? "20s Coffee";
    const branch = loaderData?.branch?.name;
    const title = branch ? `${name} — ${branch} menu` : `${name} — Menu`;
    const description = `Browse the drinks and food menu of ${name}${branch ? ` at ${branch}` : ""}, with up-to-date prices.`;
    return {
      meta: [
        { title },
        { name: "description", content: description },
        { property: "og:title", content: title },
        { property: "og:description", content: description },
        { property: "og:type", content: "website" },
        { name: "twitter:card", content: "summary_large_image" },
      ],
    };
  },
  errorComponent: () => <MenuMessage text="This menu is unavailable right now." />,
  notFoundComponent: () => <MenuMessage text="Menu not found." />,
  component: PublicMenuPage,
});

function MenuMessage({ text }: { text: string }) {
  return (
    <main className="flex min-h-screen items-center justify-center bg-background p-8">
      <p className="text-muted-foreground">{text}</p>
    </main>
  );
}

/** Guest menus keep their layout even when a photo is missing or expired. */
function ProductPhoto({ src, alt }: { src: string | null; alt: string }) {
  const [failed, setFailed] = useState(false);
  if (!src || failed) {
    return (
      <div className="flex size-16 shrink-0 items-center justify-center rounded-lg bg-secondary/60 text-muted-foreground">
        <Coffee className="size-7" aria-hidden />
      </div>
    );
  }
  return (
    <img
      src={src}
      alt={alt}
      loading="lazy"
      onError={() => setFailed(true)}
      className="aspect-square size-16 shrink-0 rounded-lg object-cover"
    />
  );
}

function PublicMenuPage() {
  const menu = Route.useLoaderData();
  const [lightbox, setLightbox] = useState<{ src: string; alt: string } | null>(null);
  if (!menu) return <MenuMessage text="Menu not found." />;

  const ar = menu.company.default_language === "ar";
  const lang: "en" | "ar" = ar ? "ar" : "en";
  const label = (en: string | null, arName: string | null | undefined) =>
    (ar ? (arName ?? en) : en) ?? "";
  const offers = menu.offers_enabled ? (menu.offers ?? []) : [];

  return (
    <main dir={ar ? "rtl" : "ltr"} className="min-h-screen bg-background pb-16">
      <header className="border-b bg-card">
        <div className="mx-auto flex max-w-3xl flex-col items-center gap-2 px-5 py-10 text-center">
          {menu.company.logo_url ? (
            <img
              src={menu.company.logo_url}
              alt={menu.company.name}
              className="size-16 rounded-full object-cover"
            />
          ) : null}
          <h1 className="text-3xl font-bold tracking-tight text-foreground">{menu.company.name}</h1>
          <p className="text-sm text-muted-foreground">{menu.branch.name}</p>
          {menu.branch.address ? (
            <p className="text-xs text-muted-foreground">{menu.branch.address}</p>
          ) : null}
          {menu.branch.phone ? (
            <a href={`tel:${menu.branch.phone}`} className="text-xs text-primary underline">
              {menu.branch.phone}
            </a>
          ) : null}
        </div>
      </header>

      {offers.length > 0 && (
        <section className="mx-auto max-w-3xl px-5 pt-8">
          <h2 className="mb-4 text-xl font-semibold text-primary">
            {ar ? "🔥 أقوى العروض والكومبو" : "🔥 Top offers & combos"}
          </h2>
          <div className="grid gap-4 sm:grid-cols-2">
            {offers.map((offer) => {
              const base = Number(offer.base_price);
              const price = Number(offer.offer_price);
              const saving = Math.max(0, base - price);
              const banner = offer.image_path ?? offer.product?.image_url ?? null;
              return (
                <article key={offer.id} className="overflow-hidden rounded-xl border bg-card">
                  {banner ? (
                    <button
                      type="button"
                      onClick={() => setLightbox({ src: banner, alt: offer.title })}
                      className="block w-full"
                    >
                      <img
                        src={banner}
                        alt={offer.title}
                        loading="lazy"
                        className="aspect-[16/9] w-full object-cover"
                      />
                    </button>
                  ) : null}
                  <div className="space-y-2 p-4">
                    <div className="flex items-start justify-between gap-3">
                      <h3 className="font-semibold text-foreground">{offer.title}</h3>
                      {saving > 0 ? (
                        <span className="whitespace-nowrap rounded-full bg-accent px-2 py-0.5 text-xs font-bold text-accent-foreground">
                          {ar ? "توفير" : "Save"} {formatMoney(saving, menu.company.currency, lang)}
                        </span>
                      ) : null}
                    </div>
                    {offer.items.length > 0 ? (
                      <ul className="space-y-0.5 text-sm text-muted-foreground">
                        {offer.items.map((item) => (
                          <li key={`${offer.id}-${item.product_id}`}>
                            {item.quantity}× {label(item.name, item.name_ar)}
                          </li>
                        ))}
                      </ul>
                    ) : offer.product ? (
                      <p className="text-sm text-muted-foreground">
                        {label(offer.product.name, offer.product.name_ar)}
                      </p>
                    ) : null}
                    <div className="flex items-baseline gap-2">
                      <span className="text-lg font-bold text-primary">
                        {formatMoney(price, menu.company.currency, lang)}
                      </span>
                      {base > price ? (
                        <span className="text-sm text-muted-foreground line-through">
                          {formatMoney(base, menu.company.currency, lang)}
                        </span>
                      ) : null}
                    </div>
                  </div>
                </article>
              );
            })}
          </div>
        </section>
      )}

      {lightbox ? (
        <div
          role="presentation"
          onClick={() => setLightbox(null)}
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 p-4"
        >
          <img
            src={lightbox.src}
            alt={lightbox.alt}
            className="max-h-full max-w-full rounded-lg object-contain"
          />
        </div>
      ) : null}


      <div className="mx-auto max-w-3xl px-5">
        {menu.categories.length === 0 ? (
          <p className="py-16 text-center text-muted-foreground">
            {ar ? "المنيو غير متاح حالياً." : "The menu is not available yet."}
          </p>
        ) : (
          menu.categories.map((category) => (
            <section key={category.id} className="py-8">
              <h2 className="mb-4 text-xl font-semibold text-primary">
                {label(category.name, category.name_ar)}
              </h2>
              <ul className="divide-y">
                {category.products.map((product) => (
                  <li key={product.id} className="flex items-start gap-4 py-4">
                    <ProductPhoto
                      src={product.image_url}
                      alt={label(product.name, product.name_ar)}
                    />

                    <div className="min-w-0 flex-1">
                      <div className="flex items-baseline justify-between gap-3">
                        <span className="font-medium text-foreground">
                          {label(product.name, product.name_ar)}
                        </span>
                        {menu.offers_enabled &&
                        product.offer_price != null &&
                        Number(product.offer_price) < Number(product.price) ? (
                          <span className="flex shrink-0 items-baseline gap-2 whitespace-nowrap">
                            <span className="text-sm text-muted-foreground line-through">
                              {formatMoney(product.price, menu.company.currency, lang)}
                            </span>
                            <span className="rounded-full bg-accent px-2 py-0.5 font-bold text-accent-foreground">
                              {formatMoney(product.offer_price, menu.company.currency, lang)}
                            </span>
                          </span>
                        ) : (
                          <span className="whitespace-nowrap font-semibold text-foreground">
                            {formatMoney(product.price, menu.company.currency, lang)}
                          </span>
                        )}
                      </div>
                      {product.description ? (
                        <p className="mt-1 text-sm text-muted-foreground">{product.description}</p>
                      ) : null}
                      {product.sizes.length > 0 ? (
                        <p className="mt-1 text-xs text-muted-foreground">
                          {product.sizes
                            .map(
                              (size) =>
                                `${label(size.name, size.name_ar)} ${formatMoney(
                                  Number(product.price) + Number(size.price_delta),
                                  menu.company.currency,
                                  lang,
                                )}`,
                            )
                            .join(" · ")}
                        </p>
                      ) : null}
                    </div>
                  </li>
                ))}
              </ul>
            </section>
          ))
        )}
      </div>
    </main>
  );
}
