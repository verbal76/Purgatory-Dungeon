#!/usr/bin/env python3
"""Procedural game-feel sounds (original, license-free) -> Music & background images/Sound Effects/juice/*.wav.

Pure standard library, fixed seed: a re-run reproduces identical files. Mono 16-bit 44.1 kHz. Run from the repo root:
    python3 tools/make_juice_audio.py
then `godot --headless --import` and commit the WAVs together with their .import files.
Loops (heartbeat, crackle, bed) are generated with matching ends so they loop cleanly.
"""
import math
import os
import random
import struct
import wave

SR = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "Music & background images", "Sound Effects", "juice")
rng = random.Random(1337)


def n(sec):
    return int(SR * sec)


def noise(num):
    return [rng.uniform(-1.0, 1.0) for _ in range(num)]


def lowpass(sig, cutoff):
    a = 1.0 - math.exp(-2.0 * math.pi * cutoff / SR)
    y = 0.0
    out = []
    for x in sig:
        y += a * (x - y)
        out.append(y)
    return out


def highpass(sig, cutoff):
    lp = lowpass(sig, cutoff)
    return [x - l for x, l in zip(sig, lp)]


def env_exp(num, decay_sec, attack_sec=0.002):
    att = max(int(SR * attack_sec), 1)
    out = []
    for i in range(num):
        e = math.exp(-i / (SR * decay_sec))
        if i < att:
            e *= i / att
        out.append(e)
    return out


def sine(freq, num, phase=0.0, freq_end=None):
    out = []
    ph = phase
    for i in range(num):
        f = freq if freq_end is None else freq + (freq_end - freq) * (i / max(num - 1, 1))
        ph += 2.0 * math.pi * f / SR
        out.append(math.sin(ph))
    return out


def mul(a, b):
    return [x * y for x, y in zip(a, b)]


def add(*sigs):
    length = max(len(s) for s in sigs)
    out = [0.0] * length
    for s in sigs:
        for i, v in enumerate(s):
            out[i] += v
    return out


def gain(sig, g):
    return [x * g for x in sig]


def pad(sig, front=0.0, total=None):
    out = [0.0] * n(front) + list(sig)
    if total is not None:
        out += [0.0] * max(n(total) - len(out), 0)
    return out


def fade_edges(sig, ms=4):
    k = max(int(SR * ms / 1000.0), 1)
    out = list(sig)
    for i in range(min(k, len(out))):
        f = i / k
        out[i] *= f
        out[-1 - i] *= f
    return out


def write(name, sig, peak=0.9):
    sig = fade_edges(sig)
    m = max(max(abs(x) for x in sig), 1e-6)
    path = os.path.join(OUT, name + ".wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, x / m * peak)) * 32767)) for x in sig))
    print("wrote", name, "%.2fs" % (len(sig) / SR))


def footstep(variant):
    r = random.Random(100 + variant)
    num = n(0.14)
    body = lowpass([r.uniform(-1, 1) for _ in range(num)], 380 + 60 * variant)
    thud = mul(sine(70 + 8 * variant, num, freq_end=48), env_exp(num, 0.05))
    grit = mul(highpass([r.uniform(-1, 1) for _ in range(num)], 2200), env_exp(num, 0.012))
    return add(mul(body, env_exp(num, 0.04)), gain(thud, 0.9), gain(grit, 0.18))


def bell(freq, dur, decay):
    num = n(dur)
    return add(mul(sine(freq, num), env_exp(num, decay)), gain(mul(sine(freq * 2.01, num), env_exp(num, decay * 0.6)), 0.35), gain(mul(sine(freq * 3.0, num), env_exp(num, decay * 0.35)), 0.15))


def main():
    os.makedirs(OUT, exist_ok=True)
    # footsteps (4 variants, stone)
    for v in range(4):
        write("footstep_%d" % (v + 1), footstep(v), 0.8)
    # swing whoosh: band-passed noise with a rising then falling centre
    num = n(0.22)
    wh = noise(num)
    swept = []
    y1 = y2 = 0.0
    for i, x in enumerate(wh):
        t = i / num
        fc = 500 + 2600 * math.sin(math.pi * t)
        a = 1.0 - math.exp(-2.0 * math.pi * fc / SR)
        y1 += a * (x - y1)
        y2 += a * (y1 - y2)
        swept.append(y1 - y2)
    shape = [math.sin(math.pi * (i / num)) ** 1.5 for i in range(num)]
    write("swing_whoosh", mul(swept, shape), 0.8)
    # impact thud (kick / shove contact)
    num = n(0.22)
    thud = mul(sine(120, num, freq_end=45), env_exp(num, 0.07))
    crack = mul(highpass(noise(num), 1500), env_exp(num, 0.015))
    write("impact_thud", add(thud, gain(crack, 0.5)), 0.95)
    # landing thud
    num = n(0.28)
    write("landing_thud", add(mul(sine(80, num, freq_end=40), env_exp(num, 0.09)), gain(mul(lowpass(noise(num), 500), env_exp(num, 0.05)), 0.7)), 0.9)
    # heartbeat loop (lub-dub, 0.95 s)
    num = n(0.95)
    beat = [0.0] * num
    for start, amp in ((0.0, 1.0), (0.26, 0.7)):
        k = n(0.16)
        pulse = mul(sine(58, k, freq_end=38), env_exp(k, 0.06))
        for i, v in enumerate(pulse):
            j = n(start) + i
            if j < num:
                beat[j] += v * amp
    write("heartbeat", beat, 0.9)
    # UI / reward sounds
    num = n(0.03)
    write("tick", mul(add(sine(1500, num), gain(highpass(noise(num), 3000), 0.4)), env_exp(num, 0.008, 0.0005)), 0.7)
    write("ready_ding", bell(1320, 0.45, 0.12), 0.75)
    write("unlock_chime", add(bell(784, 0.5, 0.16), pad(bell(1175, 0.6, 0.2), 0.12)), 0.8)
    write("heal_chime", add(bell(660, 0.4, 0.12), pad(bell(990, 0.5, 0.16), 0.09)), 0.7)
    write("pop_soft", mul(sine(420, n(0.12), freq_end=900), env_exp(n(0.12), 0.04, 0.001)), 0.8)
    write("coin", add(bell(1760, 0.3, 0.07), pad(bell(2349, 0.3, 0.08), 0.06)), 0.7)
    write("key_jingle", add(bell(1047, 0.35, 0.1), pad(bell(1397, 0.3, 0.1), 0.07), pad(bell(1760, 0.35, 0.12), 0.14)), 0.7)
    write("trap_click", add(mul(highpass(noise(n(0.05)), 1800), env_exp(n(0.05), 0.01, 0.0005)), gain(mul(sine(220, n(0.05)), env_exp(n(0.05), 0.02)), 0.6)), 0.9)
    write("day_bell", add(bell(196, 1.6, 0.5), gain(bell(294, 1.4, 0.4), 0.5)), 0.8)
    # slam / boom (room lock, portal) and explosion
    num = n(0.7)
    write("door_slam", add(mul(sine(70, num, freq_end=32), env_exp(num, 0.2)), gain(mul(lowpass(noise(num), 600), env_exp(num, 0.12)), 0.8), gain(mul(highpass(noise(num), 2500), env_exp(num, 0.02)), 0.3)), 0.95)
    num = n(0.55)
    write("explosion", add(mul(lowpass(noise(num), 900), env_exp(num, 0.16)), gain(mul(sine(90, num, freq_end=30), env_exp(num, 0.18)), 0.9)), 0.95)
    num = n(0.32)
    write("fireball_cast", mul(add(lowpass(noise(num), 1800), gain(sine(260, num, freq_end=640), 0.6)), [min(i / (num * 0.35), 1.0) * math.exp(-max(i - num * 0.55, 0) / (SR * 0.08)) for i in range(num)]), 0.8)
    num = n(0.4)
    write("fireball_impact", add(mul(lowpass(noise(num), 1400), env_exp(num, 0.1)), gain(mul(sine(150, num, freq_end=55), env_exp(num, 0.09)), 0.8), gain(mul(highpass(noise(num), 3500), env_exp(num, 0.02)), 0.4)), 0.9)
    # aggro rumble (low saw with vibrato)
    num = n(0.55)
    saw = []
    ph = 0.0
    for i in range(num):
        f = 62 + 6 * math.sin(2 * math.pi * 7 * i / SR)
        ph = (ph + f / SR) % 1.0
        saw.append(2 * ph - 1)
    rumble = lowpass(saw, 380)
    write("aggro_rumble", mul(rumble, [math.sin(math.pi * i / num) ** 0.7 for i in range(num)]), 0.85)
    # stingers
    num = n(2.2)
    drone = add(sine(55, num, freq_end=36), gain(sine(82.4, num, freq_end=54), 0.6), gain(lowpass(noise(num), 220), 0.4))
    write("death_sting", mul(drone, [math.exp(-i / (SR * 0.9)) * min(i / (SR * 0.05), 1.0) for i in range(num)]), 0.9)
    notes = [(392, 0.0), (494, 0.16), (587, 0.32), (784, 0.48), (988, 0.7)]
    write("victory_sting", add(*[pad(bell(f, 1.6, 0.5), t) for f, t in notes]), 0.8)
    write("legend_sting", add(bell(1568, 1.4, 0.45), pad(bell(2093, 1.2, 0.4), 0.1), pad(bell(2637, 1.0, 0.35), 0.2), gain(mul(highpass(noise(n(1.0)), 5000), env_exp(n(1.0), 0.25)), 0.12)), 0.75)
    # ambience: torch crackle loop (4 s), cave bed loop (8 s), drip
    num = n(4.0)
    crackle = [0.0] * num
    for _ in range(46):
        pos = rng.randrange(0, num - n(0.05))
        amp = rng.uniform(0.2, 1.0)
        k = n(rng.uniform(0.004, 0.02))
        burst = mul(highpass(noise(k), 1500), env_exp(k, 0.004, 0.0003))
        for i, v in enumerate(burst):
            crackle[pos + i] += v * amp
    hiss = gain(lowpass(highpass(noise(num), 600), 4500), 0.05)
    write("torch_crackle", add(crackle, hiss), 0.5)
    num = n(8.0)
    bed = lowpass(noise(num), 160)
    lfo = [0.65 + 0.35 * math.sin(2 * math.pi * i / num) for i in range(num)]
    bed = mul(bed, lfo)
    write("cave_bed", add(bed, gain(mul(sine(46, num), lfo), 0.25)), 0.5)
    num = n(0.18)
    write("drip", mul(sine(1500, num, freq_end=900), env_exp(num, 0.035, 0.0008)), 0.55)


if __name__ == "__main__":
    main()
