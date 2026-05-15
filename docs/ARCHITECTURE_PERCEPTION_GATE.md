# Architecture: split perception (ANE) from reasoning (GPU)

**Status:** design note, not implemented.

## The core idea

Don't fire Gemma 4 every N seconds. Fire it only when something is **actually worth coaching about**.

A naive live-coaching loop runs the full multimodal LLM every 10-15 seconds whether or not anything has changed. That burns battery and produces a constant stream of mostly-redundant coaching for a runner who's been holding the same pace for the last mile. The athlete tunes it out within 10 minutes.

The architecture should look more like:

```
ANE (always on, ~0.5-1 W)
  → continuously watches the runner via cheap signals
  → fires Gemma 4 ONLY when those signals say "something worth saying changed"

GPU (idle most of the time)
  → wakes up for one Gemma 4 turn
  → goes back to sleep
```

The cheap signals don't need to be smart. They need to be *fast and continuous*. Gemma 4 is the smart part; the ANE layer is just the gate.

## Why this works on iPhone specifically

ANE and GPU are physically separate silicon. Running a small classifier on ANE while Gemma 4 sits idle on GPU costs the GPU nothing — they don't share execution units, don't share thermal budget the way two threads on the same core do. So "ANE running constantly" is essentially free as long as the ANE workload itself is small.

A continuous ANE workload of ~1 W plus a Gemma 4 burst of ~3 W every 30-60 seconds (instead of every 10-15) cuts average power roughly in half over a 90-minute run. The athlete also gets coaching that means something instead of coaching that fills airtime.

## What "worth firing" should mean

Some examples — the specific list isn't the point, the gating principle is:

- **Form changed.** Pose detector says stride pattern shifted from baseline.
- **Effort changed.** HR or pace anomaly relative to the rolling window.
- **Athlete asked.** Wake-phrase or tap.
- **A long quiet stretch.** Fall back to a periodic "you're doing well" every few minutes so the app doesn't feel dead.

These are all things small models or simple thresholds can decide in milliseconds on ANE. None of them require a 4-billion-parameter LLM to answer "is now a coaching moment?"

## What stays on GPU

When the gate trips, Gemma 4 fires on GPU/Metal as we've already wired it. It gets:

- The current state (HR, pace, cadence — numeric features from the ANE layer)
- A keyframe if vision is relevant (selected by ANE-routed quality/saliency)
- A short audio clip if breathing/voice is relevant (selected by ANE-routed VAD)
- Optional retrieval context (similar past coaching, retrieved by ANE-routed embedding search)

It produces one coaching response. Streams to TTS. Done. Goes back to sleep.

## What this is NOT

It's not a hybrid inference engine. We're not modifying LiteRT-LM's C++. We're not splitting Gemma 4 across silicon. The model itself runs entirely on GPU as it already does.

What changes is *how often the model runs and what's already pre-digested when it does*. That's an orchestration layer above LiteRT-LM, not a modification to it.

## Why this isn't built yet

Many of the specific perception components (custom form classifier, breathing-rate extractor, embedding-based RAG over past workouts) would each be small projects. The current `litert-lm/` app fires Gemma 4 on a fixed timer because that gets the live coaching pipeline tested fastest.

Documenting the target architecture so it's not forgotten when we get past the "does it work on a real iPhone" milestone.

## When to revisit

After the live-mode app is verified on a real iPhone and the basic UX is right. Then introduce the gating layer one signal at a time, starting with whichever signal cuts the most useless coaching turns first (probably HR/pace anomaly — easiest to implement, biggest battery win).
