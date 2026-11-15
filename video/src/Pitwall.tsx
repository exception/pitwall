import React from "react";
import {
  AbsoluteFill, Audio, Img, OffthreadVideo, Sequence, interpolate, spring, staticFile,
  useCurrentFrame, useVideoConfig, Easing,
} from "remotion";

const FPS = 30;
const AMBER = "#F5A524";
const BG = "#0B0C0E";
const FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Helvetica Neue', sans-serif";

/** One footage scene: a source clip range, its caption, and timed effects (source seconds). */
type Scene = {
  clip: string;
  from: number;  // source seconds
  to: number;
  rate: number;
  title: string;
  sub: string;
  sfx?: { at: number; name: string; volume?: number }[];
  ticks?: [number, number, number]; // typing: start, end, count (source seconds)
  /** Slow push-in: [scale, focusX, focusY] at the start and end (focus in 0..1 of the window). */
  cam?: [[number, number, number], [number, number, number]];
};

const scenes: Scene[] = [
  {
    clip: "c1-dispatch", cam: [[1.0, 0.55, 0.55], [1.32, 0.56, 0.42]], from: 0.4, to: 13.4, rate: 1.15,
    title: "Hand off a task.", sub: "Every agent runs in a real terminal on one infinite canvas.",
    ticks: [0.7, 3.7, 24], sfx: [{ at: 4.2, name: "pop" }, { at: 4.4, name: "whoosh", volume: 0.5 }],
  },
  {
    clip: "c2-zoomout", from: 0.9, to: 5.6, rate: 1,
    title: "Run them all at once.", sub: "Zoom out and every agent becomes a status card.",
    sfx: [{ at: 1.5, name: "whoosh", volume: 0.8 }],
  },
  {
    clip: "c3-approve", cam: [[1.05, 0.7, 0.45], [1.38, 0.78, 0.38]], from: 3.2, to: 12.4, rate: 1.1,
    title: "Know who needs you.", sub: "Approve or deny from one Inbox, without hunting for the tab.",
    sfx: [{ at: 4.4, name: "chime" }, { at: 6.6, name: "whoosh", volume: 0.35 }, { at: 9.2, name: "pop" }],
  },
  {
    clip: "c6-watch", cam: [[1.12, 0.6, 0.4], [1.3, 0.62, 0.38]], from: 0.8, to: 14.2, rate: 1.3,
    title: "Tests fail? It closes the loop.", sub: "The failure goes to the agent, and Pitwall reruns the tests when it's done.",
    sfx: [{ at: 2.3, name: "fail" }, { at: 11.8, name: "pass" }],
  },
  {
    clip: "c7-pan", cam: [[1.0, 0.5, 0.5], [1.12, 0.55, 0.5]], from: 1.0, to: 6.0, rate: 1,
    title: "Everything else, on the same wall.", sub: "Live diffs, watches, pull requests and dev servers, linked to their agent.",
    sfx: [{ at: 1.6, name: "whoosh", volume: 0.5 }],
  },
  {
    clip: "c4-search", cam: [[1.0, 0.5, 0.3], [1.3, 0.5, 0.22]], from: 0.8, to: 6.3, rate: 1,
    title: "Search every terminal.", sub: "The full history of every agent, on every board.",
    ticks: [1.4, 1.75, 7],
  },
  {
    clip: "c5-frames", from: 0.8, to: 8.4, rate: 1.1,
    title: "Group the work.", sub: "Frames collapse to a strip that still shows who needs you.",
    sfx: [{ at: 1.6, name: "whoosh", volume: 0.3 }, { at: 2.8, name: "whoosh", volume: 0.3 }, { at: 5.6, name: "whoosh", volume: 0.3 }],
  },
];

const INTRO = 105;
const OUTRO = 165;
const XF = 12; // crossfade frames
const len = (s: Scene) => Math.round(((s.to - s.from) / s.rate) * FPS);
const starts: number[] = [];
{
  let t = INTRO - XF;
  for (const s of scenes) { starts.push(t); t += len(s) - XF; }
}
const outroStart = starts[starts.length - 1] + len(scenes[scenes.length - 1]) - XF;
export const TOTAL = outroStart + OUTRO;

const Backdrop: React.FC = () => {
  const f = useCurrentFrame();
  const drift = Math.sin(f / 140) * 60;
  return (
    <AbsoluteFill style={{ background: BG }}>
      <AbsoluteFill style={{
        background: `radial-gradient(900px 600px at ${70 + drift / 20}% 115%, rgba(245,165,36,0.16), transparent 70%),
                     radial-gradient(800px 500px at ${10 - drift / 30}% -10%, rgba(91,156,255,0.10), transparent 70%)`,
      }} />
      <AbsoluteFill style={{
        backgroundImage: "radial-gradient(rgba(255,255,255,0.06) 1.2px, transparent 1.2px)",
        backgroundSize: "26px 26px", backgroundPosition: `${drift / 4}px 0px`,
      }} />
    </AbsoluteFill>
  );
};

const fade = (frame: number, total: number) =>
  interpolate(frame, [0, XF, total - XF, total], [0, 1, 1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });

const Caption: React.FC<{ title: string; sub: string }> = ({ title, sub }) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const s = spring({ frame: f - 4, fps, config: { damping: 200 } });
  const s2 = spring({ frame: f - 10, fps, config: { damping: 200 } });
  return (
    <div style={{ position: "absolute", top: 34, left: 0, right: 0, textAlign: "center", fontFamily: FONT }}>
      <div style={{ color: "white", fontSize: 50, fontWeight: 700, letterSpacing: -1, opacity: s, transform: `translateY(${(1 - s) * 18}px)` }}>
        {title}
      </div>
      <div style={{ color: "rgba(255,255,255,0.62)", fontSize: 25, marginTop: 6, opacity: s2, transform: `translateY(${(1 - s2) * 14}px)` }}>
        {sub}
      </div>
    </div>
  );
};

const camStyle = (scene: Scene, f: number, total: number): React.CSSProperties => {
  if (!scene.cam) return { width: "100%", height: "100%" };
  const [[s0, x0, y0], [s1, x1, y1]] = scene.cam;
  const p = interpolate(f, [0, total], [0, 1], { extrapolateRight: "clamp", easing: Easing.inOut(Easing.cubic) });
  const sc = s0 + (s1 - s0) * p, fx = x0 + (x1 - x0) * p, fy = y0 + (y1 - y0) * p;
  return { width: "100%", height: "100%", transform: `scale(${sc})`, transformOrigin: `${fx * 100}% ${fy * 100}%` };
};

/** The app window: footage in a rounded frame with a soft shadow. */
const Window: React.FC<{ scene: Scene }> = ({ scene }) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const s = spring({ frame: f, fps, config: { damping: 200 }, durationInFrames: 24 });
  const W = 1472, H = 920;
  return (
    <div style={{
      position: "absolute", left: (1920 - W) / 2, top: 146, width: W, height: H,
      transform: `scale(${0.965 + 0.035 * s})`, transformOrigin: "50% 0%",
      borderRadius: 18, overflow: "hidden",
      boxShadow: "0 40px 120px rgba(0,0,0,0.65), 0 0 0 1px rgba(255,255,255,0.09)",
    }}>
      <div style={camStyle(scene, f, len(scene))}>
        <OffthreadVideo src={staticFile(`footage/${scene.clip}.mp4`)} startFrom={Math.round(scene.from * FPS)}
          playbackRate={scene.rate} muted style={{ width: W, height: H }} />
        {/* Hide the screen-capture indicator macOS draws in the window's corner. */}
        <div style={{ position: "absolute", left: 0, top: 0, width: 92, height: 30, background: "#0F1012" }} />
      </div>
    </div>
  );
};

const SceneView: React.FC<{ scene: Scene }> = ({ scene }) => {
  const f = useCurrentFrame();
  const total = len(scene);
  const toLocal = (src: number) => Math.round(((src - scene.from) / scene.rate) * FPS);
  return (
    <AbsoluteFill style={{ opacity: fade(f, total) }}>
      <Window scene={scene} />
      <Caption title={scene.title} sub={scene.sub} />
      {(scene.sfx ?? []).filter((e) => e.at >= scene.from && e.at <= scene.to).map((e, i) => (
        <Sequence key={i} from={toLocal(e.at)} durationInFrames={60}>
          <Audio src={staticFile(`audio/${e.name}.wav`)} volume={e.volume ?? 0.7} />
        </Sequence>
      ))}
      {scene.ticks && Array.from({ length: scene.ticks[2] }).map((_, i) => {
        const [a, b, n] = scene.ticks!;
        const at = a + ((b - a) * i) / Math.max(1, n - 1);
        return (
          <Sequence key={`t${i}`} from={toLocal(at)} durationInFrames={4}>
            <Audio src={staticFile("audio/tick.wav")} volume={0.18 + (i % 3) * 0.04} />
          </Sequence>
        );
      })}
    </AbsoluteFill>
  );
};

const Logo: React.FC<{ size: number; frame: number }> = ({ size, frame }) => {
  const { fps } = useVideoConfig();
  const s = spring({ frame, fps, config: { damping: 14, stiffness: 120 } });
  return (
    <Img src={staticFile("icon.png")} style={{
      width: size, height: size, borderRadius: size * 0.22,
      transform: `scale(${0.6 + 0.4 * s})`, opacity: Math.min(1, s * 1.4),
      boxShadow: `0 24px 80px rgba(245,165,36,${0.25 * s})`,
    }} />
  );
};

const Intro: React.FC = () => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t1 = spring({ frame: f - 12, fps, config: { damping: 200 } });
  const t2 = spring({ frame: f - 30, fps, config: { damping: 200 } });
  const out = interpolate(f, [INTRO - XF, INTRO], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return (
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", fontFamily: FONT, opacity: out }}>
      <Logo size={168} frame={f} />
      <div style={{ color: "white", fontSize: 110, fontWeight: 800, letterSpacing: -3, marginTop: 34, opacity: t1, transform: `translateY(${(1 - t1) * 24}px)` }}>
        Pitwall
      </div>
      <div style={{ color: "rgba(255,255,255,0.7)", fontSize: 36, marginTop: 6, opacity: t2, transform: `translateY(${(1 - t2) * 16}px)` }}>
        Every agent, <span style={{ color: AMBER }}>one wall</span>.
      </div>
      <Sequence from={0} durationInFrames={80}><Audio src={staticFile("audio/swell.wav")} volume={0.55} /></Sequence>
      <Sequence from={6} durationInFrames={30}><Audio src={staticFile("audio/thud.wav")} volume={0.7} /></Sequence>
    </AbsoluteFill>
  );
};

const Outro: React.FC = () => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const fin = interpolate(f, [0, XF], [0, 1], { extrapolateRight: "clamp" });
  const t1 = spring({ frame: f - 14, fps, config: { damping: 200 } });
  const t2 = spring({ frame: f - 30, fps, config: { damping: 200 } });
  const fadeOut = interpolate(f, [OUTRO - 20, OUTRO], [1, 0], { extrapolateLeft: "clamp", easing: Easing.in(Easing.quad) });
  return (
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", fontFamily: FONT, opacity: fin * fadeOut }}>
      <Logo size={132} frame={f} />
      <div style={{ color: "white", fontSize: 92, fontWeight: 800, letterSpacing: -2.5, marginTop: 28, opacity: t1 }}>Pitwall</div>
      <div style={{ color: "rgba(255,255,255,0.72)", fontSize: 32, marginTop: 4, opacity: t1 }}>
        Every agent, <span style={{ color: AMBER }}>one wall</span>.
      </div>
      <div style={{
        marginTop: 44, opacity: t2, transform: `translateY(${(1 - t2) * 12}px)`,
        padding: "16px 30px", borderRadius: 999, background: "rgba(255,255,255,0.08)",
        border: "1px solid rgba(255,255,255,0.14)", color: "white", fontSize: 28, fontWeight: 600,
      }}>
        Download for macOS · github.com/exception/pitwall
      </div>
      <Sequence from={0} durationInFrames={80}><Audio src={staticFile("audio/swell.wav")} volume={0.4} /></Sequence>
    </AbsoluteFill>
  );
};

export const Pitwall: React.FC = () => {
  const f = useCurrentFrame();
  const musicVol = interpolate(f, [0, 20, TOTAL - 45, TOTAL], [0, 0.55, 0.55, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return (
    <AbsoluteFill style={{ background: BG }}>
      <Backdrop />
      <Audio src={staticFile("audio/music.wav")} volume={musicVol} />
      <Sequence durationInFrames={INTRO}><Intro /></Sequence>
      {scenes.map((s, i) => (
        <Sequence key={s.clip} from={starts[i]} durationInFrames={len(s)}>
          <SceneView scene={s} />
        </Sequence>
      ))}
      <Sequence from={outroStart} durationInFrames={OUTRO}><Outro /></Sequence>
    </AbsoluteFill>
  );
};
