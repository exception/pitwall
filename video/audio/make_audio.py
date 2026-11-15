"""Synthesizes the Pitwall video soundtrack and sound effects (no samples,
no third-party audio, so there is nothing to license).

    python3 video/audio/make_audio.py video/public/audio

music.wav  ~70 s, 104 BPM: soft pad chords, arpeggiated plucks, sub bass,
           light kick/hat with sidechain pump; intro and outro build/fade.
whoosh/chime/pop/tick/swell/thud.wav  short effects.
"""
import sys, wave, os
import numpy as np

SR = 44100
out = sys.argv[1] if len(sys.argv) > 1 else "."
os.makedirs(out, exist_ok=True)
rng = np.random.default_rng(7)


def write(name, x):
    x = np.asarray(x, dtype=np.float64)
    if x.ndim == 1:
        x = np.stack([x, x], axis=1)
    peak = np.max(np.abs(x)) or 1
    x = x / peak * 0.89
    data = (x * 32767).astype("<i2")
    with wave.open(os.path.join(out, name), "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(data.tobytes())


def t(sec):
    return np.arange(int(sec * SR)) / SR


def note(n):  # MIDI -> Hz
    return 440.0 * 2 ** ((n - 69) / 12)


def lowpass(x, cutoff):
    """One-pole lowpass; cutoff may be an array (sweeps)."""
    cutoff = np.broadcast_to(cutoff, x.shape)
    a = np.exp(-2 * np.pi * cutoff / SR)
    y = np.empty_like(x); s = 0.0
    for i in range(len(x)):
        s = (1 - a[i]) * x[i] + a[i] * s
        y[i] = s
    return y


def saw(f, tt, detune=0.0):
    ph = (f * (1 + detune)) * tt
    return 2 * (ph - np.floor(ph + 0.5))


def adsr(n, a, d, s, r, sustain_len):
    a, d, r = int(a * SR), int(d * SR), int(r * SR)
    env = np.zeros(n)
    hold = max(0, int(sustain_len * SR) - a - d)
    seg = np.concatenate([np.linspace(0, 1, a, endpoint=False), np.linspace(1, s, d, endpoint=False),
                          np.full(hold, s), np.linspace(s, 0, r)])
    env[:min(n, len(seg))] = seg[:n]
    return env


# ---------------------------------------------------------------- music
BPM = 104
beat = 60 / BPM
bar = beat * 4
bars = 30                     # ~69 s
dur = bars * bar + 3
N = int(dur * SR)
L = np.zeros(N); R = np.zeros(N)

# Am  F  C  G  (two bars each), voiced warm.
prog = [[57, 60, 64, 69], [53, 57, 60, 65], [48, 55, 60, 64], [55, 59, 62, 67]]
bassn = [45, 41, 48, 43]


def add(buf, start, sig):
    i = int(start * SR)
    j = min(N, i + len(sig))
    if j > i:
        buf[i:j] += sig[: j - i]


def section_gain(b):
    # intro (bars 0-1) pad only, build, full, outro fade
    return 1.0


for b in range(bars):
    chord = prog[(b // 2) % 4]
    start = b * bar
    # Pad: detuned saws, slow attack, filtered.
    if b % 2 == 0:
        tt = t(bar * 2 + 1.0)
        pad = np.zeros_like(tt)
        for n in chord:
            for dt in (-0.004, 0.0, 0.0045):
                pad += saw(note(n), tt, dt)
        cutoff = 900 + 500 * np.sin(2 * np.pi * tt / (bar * 2)) ** 2
        pad = lowpass(pad / 12, cutoff) * adsr(len(tt), 0.6, 0.5, 0.8, 1.0, bar * 2)
        lvl = 0.55 if b < 2 else 0.42
        add(L, start, pad * lvl * 1.05); add(R, start, pad * lvl * 0.95)
    # Arp plucks from bar 2: chord tones up an octave, 8th notes.
    if 2 <= b < bars - 2:
        seq = [0, 2, 1, 3, 2, 1, 3, 2]
        for k, idx in enumerate(seq):
            n = chord[idx] + 12
            tt = t(0.45)
            sig = (np.sin(2 * np.pi * note(n) * tt) + 0.35 * np.sin(2 * np.pi * note(n) * 2 * tt)) * np.exp(-tt * 9)
            pan = 0.5 + 0.35 * np.sin(k)
            lvl = 0.16 if b < 4 else 0.2
            add(L, start + k * beat / 2, sig * lvl * (1 - pan) * 2)
            add(R, start + k * beat / 2, sig * lvl * pan * 2)
    # Sub bass from bar 4: root on 1 and the "and" of 2.
    if 4 <= b < bars - 1:
        for off in (0, 1.5, 2.5):
            tt = t(beat * 0.95)
            f = note(bassn[(b // 2) % 4] - 12)
            sig = np.sin(2 * np.pi * f * tt) * adsr(len(tt), 0.01, 0.1, 0.7, 0.15, beat * 0.8)
            add(L, start + off * beat, sig * 0.5); add(R, start + off * beat, sig * 0.5)
    # Drums from bar 4: kick on beats, soft hats on 8ths.
    if 4 <= b < bars - 2:
        for k in range(4):
            tt = t(0.35)
            f = 120 * np.exp(-tt * 22) + 42
            kick = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-tt * 9)
            add(L, start + k * beat, kick * 0.55); add(R, start + k * beat, kick * 0.55)
        for k in range(8):
            tt = t(0.06)
            hat = np.diff(rng.standard_normal(len(tt) + 1)) * np.exp(-tt * 70)
            lvl = 0.05 if k % 2 == 0 else 0.08
            add(L, start + k * beat / 2, hat * lvl * 0.8); add(R, start + k * beat / 2, hat * lvl)

# Sidechain-ish pump on everything but drums would be ideal; a gentle global
# pump on the beat reads the same at this level.
tt = np.arange(N) / SR
pump = 1 - 0.18 * np.exp(-((tt % beat) / 0.12))
pump[: int(4 * bar * SR)] = 1
L *= pump; R *= pump
# Fade in/out.
fade_in = np.clip(tt / 2.0, 0, 1)
fade_out = np.clip((dur - tt) / 4.0, 0, 1)
L *= fade_in * fade_out; R *= fade_in * fade_out
# Soft clip.
write("music.wav", np.stack([np.tanh(L * 1.2), np.tanh(R * 1.2)], axis=1))

# ---------------------------------------------------------------- effects
# whoosh: band-passed noise sweeping up then down.
tt = t(0.9)
noise = rng.standard_normal(len(tt))
sweep = 300 + 3500 * np.sin(np.pi * tt / 0.9) ** 2
wh = lowpass(noise, sweep) - lowpass(noise, sweep * 0.25)
write("whoosh.wav", wh * np.sin(np.pi * tt / 0.9) ** 1.5)

# chime: two bell partials (needs you).
tt = t(1.6)
ch = sum(a * np.sin(2 * np.pi * f * tt) * np.exp(-tt * d) for f, a, d in
         [(880, 1, 3.2), (1318.5, 0.6, 4.0), (2637, 0.18, 7), (1760, 0.25, 5)])
ch2 = np.zeros(int(1.8 * SR)); ch2[int(0.12 * SR):int(0.12 * SR) + len(tt)] += 0.8 * sum(
    a * np.sin(2 * np.pi * f * tt) * np.exp(-tt * d) for f, a, d in [(1046.5, 1, 3.4), (1568, 0.5, 4.5)])
ch2[: len(ch)] += ch
write("chime.wav", ch2)

# pop: approve / confirm.
tt = t(0.18)
f = 900 * np.exp(-tt * 18) + 300
write("pop.wav", np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-tt * 28))

# tick: a soft key press.
tt = t(0.035)
tk = (np.diff(rng.standard_normal(len(tt) + 1)) * 0.6 + np.sin(2 * np.pi * 2400 * tt)) * np.exp(-tt * 160)
write("tick.wav", tk)

# swell: rising pad for the title and outro.
tt = t(2.2)
sw = sum(saw(note(n), tt, d) for n in (57, 64, 69, 76) for d in (-0.003, 0.003)) / 8
write("swell.wav", lowpass(sw, 200 + 2600 * (tt / 2.2) ** 2) * (tt / 2.2) ** 1.4 * np.exp(-np.maximum(0, tt - 1.9) * 12))

# thud: low impact under the logo.
tt = t(0.8)
f = 90 * np.exp(-tt * 8) + 38
write("thud.wav", np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-tt * 5))

# fail: low two-note "uh-oh" for a red tile; pass: bright up-chirp.
tt = t(0.22)
fa = np.concatenate([np.sin(2 * np.pi * 330 * tt) * np.exp(-tt * 12), np.sin(2 * np.pi * 247 * t(0.35)) * np.exp(-t(0.35) * 8)])
write("fail.wav", fa)
pa = np.concatenate([np.sin(2 * np.pi * 659 * tt) * np.exp(-tt * 14), np.sin(2 * np.pi * 988 * t(0.4)) * np.exp(-t(0.4) * 7)])
write("pass.wav", pa)
print("ok", round(dur, 1), "s")
