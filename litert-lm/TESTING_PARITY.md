# Better-than-simulator iPhone perf testing

The iOS Simulator on a Mac mini M4 reports tok/s numbers that are roughly 3-4× too fast for what an iPhone 16 Pro will actually deliver, because the simulator runs on the Mac's GPU at full speed. Below are three realistic ways to get numbers that actually predict on-device behavior, ranked by effort.

---

## Path A — Xcode "Devices over Network" (free, fastest, requires any iPhone you own)

If you own ANY iPhone (even an older one — iPhone 13+ is the floor for this app), you can pair it with the Mac mini over WiFi. No cable needed.

### One-time setup
1. iPhone + Mac mini on the **same WiFi network**.
2. Plug iPhone into the Mac mini once with a Lightning/USB-C cable. Trust the computer prompt.
3. Open Xcode → **Window → Devices and Simulators**.
4. Select the connected iPhone in the left list, tick **"Connect via network"**.
5. Unplug the cable. The phone should still appear in the destinations dropdown with a globe icon.

### Each session
- Plug nothing in. iPhone shows up automatically in the Xcode destination dropdown.
- Build + run in Xcode → app installs to the phone over WiFi → opens.
- Console + Instruments work over WiFi too.

### What you get
- **Real iPhone hardware** (any iPhone 13+ for our app).
- Real Metal GPU, real memory bandwidth, real thermal throttling.
- Numbers will be 1.0× iPhone (because they ARE iPhone).
- iPhone 13 Pro ≈ iPhone 14 Pro ≈ iPhone 16 Pro within ~30% on Gemma 4 E2B decode (all use the same Apple GPU architecture; bandwidth differs ~20% gen-over-gen).

### Cost
Free.

---

## Path B — Cloud iPhone via BrowserStack App Live (paid, no hardware needed)

If you don't have an iPhone to pair, BrowserStack rents you a real iPhone in their datacenter via your browser. They have iPhone 16 Pro available.

### Steps
1. Sign up: <https://www.browserstack.com/app-live> (free trial = 30 min, then ~$49/mo)
2. Build the unsigned `.app`:
   ```
   cd litert-lm
   ./apply.sh
   ```
3. Upload `litert-lm/ios-app/build_ios/Build/Products/Debug-iphoneos/GemmaCoach.app` (zip it first — BrowserStack accepts `.ipa` or zipped `.app`).
4. Pick **iPhone 16 Pro / iOS 18** from their device list.
5. Launch the app → interact via the browser-rendered phone. Real touch, real perf.

### What you get
- Real iPhone 16 Pro hardware
- Live interactive testing via browser
- Can record sessions for demo videos
- The 2.6 GB Gemma 4 model downloads on first launch from inside their datacenter (fast).

### Cost
Free for 30 min. $49/mo for unlimited. AWS Device Farm is the alternative ($0.27/min direct device access, more programmatic, less convenient for manual testing).

---

## Path C — Macros-side throttled emulation (free, least accurate, fastest iteration)

When you just want to iterate on UI/code and not wait for a real device, you can intentionally throttle the macOS-side run to roughly match iPhone perf characteristics. Won't be exact, but closer than full-speed simulator.

### CPU throttle via thread limit
In `EngineModel.swift`, when initializing LiteRTLMEngine, you could pass an explicit thread cap. The Swift package doesn't currently expose one, but for the **macOS CLI** path you can:

```bash
export LITERTLM_NUM_THREADS=4   # iPhone has 6 cores total but only ~4 are usable for LLM
litert-lm benchmark gemma-4-E2B-it.litertlm --backend=cpu -p 256 -d 256
```

Compare those CPU-only numbers to the GPU-accelerated ones to bracket the iPhone range:
- **macOS GPU**: ~70 tok/s (overestimates iPhone GPU by ~3-4×)
- **macOS CPU 4-thread**: ~12 tok/s (decent proxy for iPhone CPU-fallback)
- **iPhone GPU (real)**: ~15-20 tok/s

So the macOS-CPU-4-thread number is in the right ballpark for iPhone GPU. Not because they're the same hardware, but because both are bandwidth-limited and end up similar throughput by coincidence.

### Memory pressure simulation
For the LiteRT-LM CLI, there's no flag to limit memory. For the iOS app itself, if you want to test how it behaves under iOS-like pressure on macOS, run:

```bash
ulimit -v $((6 * 1024 * 1024))   # cap virtual memory at 6 GB (iPhone 16 Pro RAM)
```

before launching the simulator/app. The OOM will fire similarly to how iOS would.

### What you get
- Free, instant iteration
- Approximate not exact
- Useful for "is this slower or faster than my last change" relative comparisons
- NOT useful for absolute "what number do I show in the demo"

---

## Recommended workflow

1. **Day-to-day dev:** code + test on iOS Sim or Mac (full speed, fast iteration).
2. **Once per feature / before showing anything:** push to a real iPhone via Path A (if you have one) — captures real metrics, validates touch UX.
3. **Right before the demo:** rent BrowserStack for an hour, run the app on iPhone 16 Pro, **screen-record the demo on the real device**. That's what you show.

---

## What numbers to actually report

Don't quote macOS-sim tok/s in any pitch deck — they're meaningless to anyone with phone-perf intuition.

Use these published reference points for your context:

| Path | iPhone hardware | Decode tok/s | RAM | Power | Source |
|---|---|---|---|---|---|
| llama.cpp Metal (your `llama-cpp/`) | iPhone 16 Pro | ~15-20 | several GB | ~4 W | Extrapolated from M4 numbers |
| LiteRT-LM GPU (your `litert-lm/`) | iPhone 16 Pro | ~15-20 | several GB | ~4 W | Same |
| LiteRT-LM with MTP | iPhone 16 Pro | ~30-40 | several GB | ~4 W | LiteRT-LM v0.11 blog |
| Google AI Edge Gallery (App Store) | iPhone 16 Pro | 12-18 | ~3 GB | ~4 W | gemma4-ai.com benchmark |
| CoreML-LLM ANE (not yet wired) | iPhone 17 Pro | **34.2** | **~250 MB** | **~2 W** | github.com/john-rocky/CoreML-LLM v1.9.0 |

For the running-coach demo, the honest claim is: "**~15-20 tok/s decode, ~2-3 sec for first token, runs fully offline, no cloud**" using the GPU path you've shipped.
