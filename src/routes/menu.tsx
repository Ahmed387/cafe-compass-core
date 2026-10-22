import { createFileRoute } from "@tanstack/react-router";
import { ChevronDown, Coffee, Languages, Search } from "lucide-react";
import { useEffect, useMemo, useState } from "react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import bambooSilhouette from "@/assets/venue/bamboo-silhouette.jpg";
import entrance from "@/assets/venue/entrance.jpg";
import kiosk from "@/assets/venue/kiosk.jpg";
import terrace from "@/assets/venue/terrace.jpg";
import { MenuMusic } from "@/components/menu/MenuMusic";
import { formatMoney } from "@/lib/format";
import { CAN_SURCHARGE, softOpeningImage } from "@/lib/soft-opening-catalog";
import { getMenuOffers, getSoftOpeningCatalog } from "@/lib/soft-opening.functions";

export const Route = createFileRoute("/menu")({
  loader: async () => {
    const [categories, offers] = await Promise.all([getSoftOpeningCatalog(), getMenuOffers().catch(() => [])]);
    return { categories, offers };
  },
  head: () => ({
    meta: [
      { title: "المنيو — 20s Specialty Coffee" },
      { name: "description", content: "تصفح قائمة مشروبات ومأكولات 20s Specialty Coffee وأسعارها بالعربي والإنجليزي." },
      { property: "og:title", content: "المنيو — 20s Specialty Coffee" },
      { property: "og:description", content: "قائمة المشروبات والحلويات الكاملة من 20s Specialty Coffee." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  errorComponent: SoftMenuError,
  notFoundComponent: SoftMenuError,
  component: SoftMenuPage,
});

function SoftMenuError() {
  return <main className="soft-menu-theme flex min-h-screen items-center justify-center bg-soft-night p-8 text-soft-foreground"><p>المنيو غير متاح الآن، حاول مرة أخرى بعد قليل.</p></main>;
}

// The first photo is the hero background; the rest of the venue follows it.
const VENUE_PHOTOS = [
  { src: bambooSilhouette, ar: "ظل على حيطة البامبو في 20s", en: "A silhouette on the 20s bamboo wall" },
  { src: entrance, ar: "بوابة 20s Specialty Coffee المضيئة", en: "The lit 20s Specialty Coffee gate" },
  { src: kiosk, ar: "بار 20s على الكورنيش السياحي بالمنيا الجديدة", en: "The 20s bar at the New Minya tourist corniche" },
  { src: terrace, ar: "التراس تحت الشجرة بإضاءة دافئة", en: "The terrace under the tree in warm light" },
];
const SLIDE_MS = 7000;

/** Cinematic hero: each venue photo drifts right to left, then cross-fades to the next. */
function VenueSlideshow({ ar }: { ar: boolean }) {
  const [index, setIndex] = useState(0);
  // The outgoing photo keeps drifting while it fades, so it never snaps back.
  const [prev, setPrev] = useState(-1);
  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const id = window.setInterval(() => {
      setIndex((i) => {
        setPrev(i);
        return (i + 1) % VENUE_PHOTOS.length;
      });
    }, SLIDE_MS);
    return () => window.clearInterval(id);
  }, []);
  return (
    <div className="absolute inset-0 overflow-hidden" aria-roledescription="carousel">
      {VENUE_PHOTOS.map((photo, i) => (
        <img
          key={photo.src}
          src={photo.src}
          alt={i === index ? (ar ? photo.ar : photo.en) : ""}
          aria-hidden={i !== index}
          fetchPriority={i === 0 ? "high" : "low"}
          loading={i === 0 ? "eager" : "lazy"}
          className={`absolute inset-0 size-full object-cover transition-opacity duration-[1500ms] ${i === index || i === prev ? "soft-menu-drift" : ""} ${i === index ? "opacity-100" : "opacity-0"}`}
        />
      ))}
    </div>
  );
}

/** An endless strip of the venue photos moving right to left. */
function VenueStrip({ ar }: { ar: boolean }) {
  return (
    <section dir="ltr" aria-label={ar ? "صور المكان" : "The venue"} className="overflow-hidden border-y border-soft-border bg-soft-night py-6">
      <div className="soft-menu-marquee flex w-max gap-4">
        {[...VENUE_PHOTOS, ...VENUE_PHOTOS, ...VENUE_PHOTOS, ...VENUE_PHOTOS].map((photo, i) => (
          <img
            key={i}
            src={photo.src}
            alt={i < VENUE_PHOTOS.length ? (ar ? photo.ar : photo.en) : ""}
            aria-hidden={i >= VENUE_PHOTOS.length}
            loading="lazy"
            className="h-56 w-44 shrink-0 rounded-md object-cover shadow-soft-card sm:h-72 sm:w-60"
          />
        ))}
      </div>
    </section>
  );
}

function SoftMenuPage() {
  const { categories, offers } = Route.useLoaderData();
  const [query, setQuery] = useState("");
  const [lang, setLang] = useState<"ar" | "en">("ar");
  const ar = lang === "ar";
  const L = (o: { name_ar: string; name_en: string }) => (ar ? o.name_ar : o.name_en);
  const S = (o: { name_ar: string; name_en: string }) => (ar ? o.name_en : o.name_ar);
  const [active, setActive] = useState(categories[0]?.slug ?? "");
  const needle = query.trim().toLocaleLowerCase("ar");
  const visible = useMemo(() => categories.map((category) => ({ ...category, items: category.items.filter((item) => !needle || `${item.name_ar} ${item.name_en}`.toLocaleLowerCase("ar").includes(needle)) })).filter((category) => category.items.length > 0), [categories, needle]);

  useEffect(() => {
    const elements = categories.map((category) => document.getElementById(category.slug)).filter((element): element is HTMLElement => Boolean(element));
    const observer = new IntersectionObserver((entries) => {
      const current = entries.filter((entry) => entry.isIntersecting).sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];
      if (current?.target.id) setActive(current.target.id);
    }, { rootMargin: "-25% 0px -60%", threshold: [0.05, 0.3, 0.6] });
    elements.forEach((element) => observer.observe(element));
    return () => observer.disconnect();
  }, [categories]);

  const browse = () => document.getElementById("catalog")?.scrollIntoView({ behavior: "smooth" });
  const goTo = (slug: string) => document.getElementById(slug)?.scrollIntoView({ behavior: "smooth", block: "start" });

  return (
    <main dir={ar ? "rtl" : "ltr"} className="soft-menu-theme min-h-screen bg-soft-night text-soft-foreground">
      <section className="relative flex min-h-[92svh] items-end overflow-hidden">
        <VenueSlideshow ar={ar} />
        <div className="absolute inset-0 bg-soft-hero" />
        <div className="soft-menu-shimmer absolute inset-0" aria-hidden />
        <Button size="sm" variant="outline" onClick={() => setLang(ar ? "en" : "ar")} className="absolute end-4 top-4 z-10 border-soft-gold/50 bg-soft-night/70 text-soft-gold backdrop-blur hover:bg-soft-surface"><Languages className="size-4" />{ar ? "English" : "العربية"}</Button>
        <div className="relative mx-auto w-full max-w-5xl px-5 pb-14 pt-32 sm:px-8 sm:pb-20">
          <div className="mb-5 inline-flex items-center gap-2 rounded-full border border-soft-gold/50 bg-soft-night/70 px-4 py-2 text-xs font-bold text-soft-gold backdrop-blur"><span className="size-2 animate-pulse rounded-full bg-soft-accent" />20s SPECIALTY COFFEE</div>
          <h1 className="max-w-3xl text-5xl font-extrabold leading-tight sm:text-7xl">20s Coffee</h1>
          <p className="mt-3 max-w-xl text-lg text-soft-muted sm:text-xl">{ar ? "لحظتك الهادئة تبدأ من أول رشفة." : "Your calm moment starts with the first sip."}</p>
          <Button onClick={browse} size="lg" className="mt-8 bg-soft-accent text-soft-accent-foreground shadow-soft-glow hover:bg-soft-accent/90"><Coffee className="size-5" />{ar ? "تصفح قائمة المشروبات والمأكولات" : "Browse drinks & food"}<ChevronDown className="size-5" /></Button>
        </div>
      </section>

      <VenueStrip ar={ar} />

      {offers.length > 0 && (
        <section aria-labelledby="menu-offers" className="mx-auto max-w-6xl px-4 pt-10 sm:px-6">
          <h2 id="menu-offers" className="mb-4 text-2xl font-bold text-soft-gold sm:text-3xl">{ar ? "عروض النهارده" : "Today's offers"}</h2>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
            {offers.map((offer) => (
              <article key={offer.id} className="rounded-md border border-soft-accent/50 bg-soft-surface p-4 shadow-soft-card">
                <h3 className="font-bold">{offer.title}</h3>
                {(offer.product_name_ar || offer.product_name) && <p className="mt-1 text-xs text-soft-muted">{ar ? offer.product_name_ar || offer.product_name : offer.product_name}</p>}
                <p className="mt-3 flex items-baseline gap-2">
                  <span className="text-xl font-extrabold text-soft-accent">{formatMoney(offer.offer_price, "EGP", lang)}</span>
                  {offer.base_price > offer.offer_price && <span className="text-sm text-soft-muted line-through">{formatMoney(offer.base_price, "EGP", lang)}</span>}
                </p>
                {offer.ends_at && <p className="mt-1 text-[11px] text-soft-muted">{ar ? `لحد ${offer.ends_at}` : `Until ${offer.ends_at}`}</p>}
              </article>
            ))}
          </div>
        </section>
      )}

      <section id="catalog" className="scroll-mt-0">
        <div className="sticky top-0 z-30 border-b border-soft-border bg-soft-night/95 backdrop-blur-xl">
          <div className="mx-auto max-w-6xl px-4 py-3">
            <div className="relative mb-3"><Search className="absolute start-3 top-1/2 size-4 -translate-y-1/2 text-soft-muted" /><Input value={query} onChange={(event) => setQuery(event.target.value)} placeholder={ar ? "ابحث عن مشروبك المفضل..." : "Search your favorite drink..."} className="border-soft-border bg-soft-surface pe-4 ps-10 text-soft-foreground placeholder:text-soft-muted" /></div>
            <div className="flex gap-2 overflow-x-auto pb-1">
              {categories.map((category) => <Button key={category.id} size="sm" variant="outline" className={active === category.slug ? "border-soft-accent bg-soft-accent text-soft-accent-foreground" : "border-soft-border bg-soft-surface text-soft-foreground hover:bg-soft-surface-raised"} onClick={() => goTo(category.slug)}>{L(category)}</Button>)}
            </div>
          </div>
        </div>

        <div className="mx-auto max-w-6xl space-y-14 px-4 py-10 sm:px-6">
          {visible.map((category) => (
            <section key={category.id} id={category.slug} className="scroll-mt-36">
              <div className="mb-5 flex items-end justify-between border-b border-soft-border pb-3"><div><h2 className="text-2xl font-bold text-soft-gold sm:text-3xl">{L(category)}</h2><p className="mt-1 text-sm text-soft-muted">{S(category)}</p></div><span className="text-xs text-soft-muted">{category.items.length} {ar ? "أصناف" : "items"}</span></div>
              <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
                {category.items.map((item) => (
                  <article key={item.id} className={`group overflow-hidden rounded-md border border-soft-border bg-soft-surface shadow-soft-card transition duration-300 hover:-translate-y-1 hover:border-soft-accent/60 ${item.is_available === false ? "opacity-60 grayscale" : ""}`}>
                    <div className="relative aspect-square overflow-hidden">{item.is_available === false && <span className="absolute end-2 top-2 z-10 rounded-full bg-destructive px-2.5 py-1 text-xs font-bold text-destructive-foreground shadow-sm">{ar ? "نفد مؤقتاً" : "Sold out"}</span>}<img src={softOpeningImage(item.image_key, item.serve_type)} alt={L(item)} loading="lazy" className="size-full object-cover transition duration-500 group-hover:scale-105" /><div className="absolute inset-x-0 bottom-0 h-1/2 bg-soft-card-fade" />{item.serve_type !== "none" && <div aria-hidden className="pointer-events-none absolute left-1/2 top-[42%] flex size-[19%] -translate-x-1/2 -translate-y-1/2 flex-col items-center justify-center" dir="ltr"><span className="font-black leading-none text-black text-[clamp(9px,2.9vw,15px)]" style={{ textShadow: "0 0 2px rgba(255,255,255,0.9), 0 0 5px rgba(255,255,255,0.65)" }}>20s</span><span className="mt-[2px] text-[clamp(3px,0.85vw,5px)] font-bold uppercase leading-none tracking-[0.14em] text-black" style={{ textShadow: "0 0 2px rgba(255,255,255,0.9), 0 0 5px rgba(255,255,255,0.65)" }}>Specialty Coffee</span></div>}</div>
                    <div className="p-3"><h3 className="font-bold leading-snug">{L(item)}</h3><p className="mt-1 truncate text-xs text-soft-muted">{S(item)}</p>{item.variants.length ? <div className="mt-3 flex flex-wrap gap-1.5">{item.variants.map((variant) => <span key={variant.id} className="rounded-full border border-soft-border bg-soft-surface-raised px-2 py-1 text-xs"><b>{L(variant)}</b> · {formatMoney(variant.price, "EGP", lang)}</span>)}</div> : <p className="mt-3 font-extrabold text-soft-accent">{formatMoney(item.price, "EGP", lang)}</p>}{item.addons.length > 0 && <p className="mt-2 text-xs text-soft-muted">{item.addons.map((a) => `+ ${L(a)} ${a.price}`).join(" · ")}</p>}{item.serve_type === "cold" && <p className="mt-2 inline-block rounded-full border border-soft-gold/40 px-2 py-0.5 text-[11px] text-soft-gold">{ar ? `متاح في كان +${CAN_SURCHARGE}` : `Available in can +${CAN_SURCHARGE}`}</p>}</div>
                  </article>
                ))}
              </div>
            </section>
          ))}
          {visible.length === 0 && <div className="py-20 text-center text-soft-muted">{ar ? "لا توجد نتائج مطابقة لبحثك." : "No matching items."}</div>}
        </div>
      </section>
      <footer className="border-t border-soft-border px-5 py-10 text-center"><p className="font-display text-xl font-bold text-soft-gold">20s SPECIALTY COFFEE</p><p className="mt-2 text-xs text-soft-muted">{ar ? "الأسعار بالجنيه المصري" : "Prices in Egyptian pounds"}</p></footer>
      <MenuMusic ar={ar} />
    </main>
  );
}