import { Music, Pause, Volume2, VolumeX } from "lucide-react";
import { useEffect, useRef, useState } from "react";

import { AmbientMusic } from "@/lib/ambient-music";

const PREF_KEY = "menu-music";

function readPref() {
  try {
    return window.localStorage.getItem(PREF_KEY);
  } catch {
    return null;
  }
}

function writePref(value: "on" | "off") {
  try {
    window.localStorage.setItem(PREF_KEY, value);
  } catch {
    // Private mode: the choice just isn't remembered.
  }
}

/**
 * Calm background music while the menu is open. Browsers only allow sound after
 * the visitor touches the page, so it starts on the first tap (unless they turned
 * it off before) and can be paused or muted from the floating control.
 */
export function MenuMusic({ ar }: { ar: boolean }) {
  const music = useRef<AmbientMusic | null>(null);
  const [playing, setPlaying] = useState(false);
  const [muted, setMuted] = useState(false);

  const play = async () => {
    music.current ??= new AmbientMusic();
    try {
      await music.current.start();
      music.current.setMuted(muted);
      setPlaying(true);
      writePref("on");
    } catch {
      setPlaying(false);
    }
  };

  const pause = () => {
    music.current?.stop();
    setPlaying(false);
    writePref("off");
  };

  useEffect(() => {
    if (readPref() === "off") return;
    const kick = () => {
      void play();
      remove();
    };
    const events = ["pointerdown", "keydown", "touchend"] as const;
    const remove = () => events.forEach((name) => window.removeEventListener(name, kick));
    events.forEach((name) => window.addEventListener(name, kick, { once: true }));
    return remove;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => () => music.current?.dispose(), []);

  // Stop when the tab is hidden, resume when the visitor comes back.
  useEffect(() => {
    const onVisibility = () => {
      if (!music.current || !playing) return;
      if (document.hidden) music.current.stop();
      else void music.current.start();
    };
    document.addEventListener("visibilitychange", onVisibility);
    return () => document.removeEventListener("visibilitychange", onVisibility);
  }, [playing]);

  const toggleMute = () => {
    const next = !muted;
    setMuted(next);
    music.current?.setMuted(next);
  };

  const pill =
    "inline-flex items-center gap-2 rounded-full border border-soft-gold/50 bg-soft-night/80 px-3 py-2 text-xs font-bold text-soft-gold shadow-soft-card backdrop-blur transition hover:bg-soft-surface";

  return (
    <div className="fixed bottom-4 start-4 z-40 flex gap-2" onPointerDown={(event) => event.stopPropagation()}>
      {playing ? (
        <>
          <button type="button" className={pill} onClick={pause} aria-label={ar ? "إيقاف الموسيقى" : "Pause music"}>
            <Pause className="size-4" aria-hidden />
            {ar ? "إيقاف" : "Pause"}
          </button>
          <button type="button" className={pill} onClick={toggleMute} aria-label={muted ? (ar ? "تشغيل الصوت" : "Unmute") : ar ? "كتم الصوت" : "Mute"}>
            {muted ? <VolumeX className="size-4" aria-hidden /> : <Volume2 className="size-4" aria-hidden />}
          </button>
        </>
      ) : (
        <button type="button" className={pill} onClick={() => void play()}>
          <Music className="size-4" aria-hidden />
          {ar ? "شغّل الموسيقى" : "Play music"}
        </button>
      )}
    </div>
  );
}
