import React from "react";
import {
  AbsoluteFill, Audio, Img, OffthreadVideo, Sequence, interpolate, spring, staticFile,
  useCurrentFrame, useVideoConfig, Easing,
} from "remotion";

const FPS = 30;
const AMBER = "#F5A524";
const BG = "#0B0C0E";
const FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Helvetica Neue', sans-serif";

/** One footage scene: source segments (each with its own speed), a caption, timed effects (source seconds). */
type Seg = [number, number, number]; // from, to, rate
type Scene = {
  clip: string;
  segs: Seg[];
  title: string;
  sub: string;
  sfx?: { at: number; name: string; volume?: number }[];
  ticks?: [number, number, number]; // typing: start, end, count (source seconds)
};

const scenes: Scene[] = [
  {
    clip: "c1-dispatch", segs: [[0.8, 4.8, 1], [4.8, 16.6, 2.6]],
    title: "Hand off a task.", sub: "Every agent runs in a real terminal on one infinite canvas.",
    ticks: [1.0, 4.0, 30], sfx: [{ at: 4.6, name: "pop" }, { at: 4.8, name: "whoosh", volume: 0.45 }],
  },
  {
    clip: "c2-zoomout", segs: [[1.0, 5.4, 1.25]],
    title: "Run them all at once.", sub: "Zoom out and every agent becomes a status card.",
    sfx: [{ at: 1.5, name: "whoosh", volume: 0.8 }],
  },
  {
    clip: "c3-approve", segs: [[2.6, 10.6, 1.2], [10.6, 14.2, 2.5]],
    title: "Know who needs you.", sub: "Approve or deny from one Inbox, without hunting for the tab.",
    sfx: [{ at: 3.5, name: "chime" }, { at: 6.0, name: "whoosh", volume: 0.35 }, { at: 8.2, name: "pop" }],
  },
  {
    clip: "c6-watch", segs: [[1.0, 3.6, 1], [3.6, 11.6, 3.2], [11.6, 14.2, 1]],
    title: "Tests fail? It closes the loop.", sub: "The failure goes to the agent, and Pitwall reruns the tests when it's done.",
    sfx: [{ at: 2.2, name: "fail" }, { at: 12.6, name: "pass" }],
  },
  {
    clip: "c7-pan", segs: [[1.2, 5.8, 1.3]],
    title: "Everything else, on the same wall.", sub: "Live diffs, watches, pull requests and dev servers, linked to their agent.",
    sfx: [{ at: 1.6, name: "whoosh", volume: 0.5 }],
  },
  {
    clip: "c4-search", segs: [[1.0, 5.4, 1]],
    title: "Search every terminal.", sub: "The full history of every agent, on every board.",
    ticks: [1.4, 1.75, 7],
  },
  {
    clip: "c5-frames", segs: [[0.8, 7.8, 1.4]],
    title: "Group the work.", sub: "Frames collapse to a strip that still shows who needs you.",
    sfx: [{ at: 1.6, name: "whoosh", volume: 0.3 }, { at: 2.8, name: "whoosh", volume: 0.3 }, { at: 5.6, name: "whoosh", volume: 0.3 }],
  },
];

const segLen = ([f, t, r]: Seg) => Math.round(((t - f) / r) * FPS);
/** Output frame (within the scene) for a source time. */
const localFrame = (sc: Scene, src: number) => {
  let acc = 0;
  for (const g of sc.segs) {
    if (src <= g[1]) return acc + Math.round(((Math.max(src, g[0]) - g[0]) / g[2]) * FPS);
    acc += segLen(g);
  }
  return acc;
};
const INTRO = 75;
const OUTRO = 120;
const XF = 10; // crossfade frames
const len = (s: Scene) => s.segs.reduce((n, g) => n + segLen(g), 0);
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
      {scene.segs.map((g, i) => {
        const from = scene.segs.slice(0, i).reduce((n, x) => n + segLen(x), 0);
        return (
          <Sequence key={i} from={from} durationInFrames={segLen(g)} layout="none">
            <OffthreadVideo src={staticFile(`footage/${scene.clip}.mp4`)} startFrom={Math.round(g[0] * FPS)}
              playbackRate={g[2]} muted style={{ position: "absolute", width: W, height: H }} />
          </Sequence>
        );
      })}
      {/* Hide the screen-capture indicator macOS draws in the window's corner. */}
      <div style={{ position: "absolute", left: 0, top: 0, width: 92, height: 30, background: "#0F1012" }} />
    </div>
  );
};

const SceneView: React.FC<{ scene: Scene }> = ({ scene }) => {
  const f = useCurrentFrame();
  const total = len(scene);
  const toLocal = (src: number) => localFrame(scene, src);
  return (
    <AbsoluteFill style={{ opacity: fade(f, total) }}>
      <Window scene={scene} />
      <Caption title={scene.title} sub={scene.sub} />
      {(scene.sfx ?? []).filter((e) => e.at >= scene.segs[0][0] && e.at <= scene.segs[scene.segs.length - 1][1]).map((e, i) => (
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
