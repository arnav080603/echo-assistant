# ECHO — a private, Iron-Man-style AI assistant for Mac and iPhone

ECHO is a native SwiftUI voice assistant I built for myself and use every day. The AI runs on my own hardware: no cloud chatbot, no subscription, and my data never leaves my devices.

## Highlights

- **Runs on my own computers.** A local LLM (Llama 3.1 8B via [Ollama](https://ollama.com)) runs on my Windows desktop's GPU at ~76 tokens/sec. The Mac and iPhone apps connect to it over a private [Tailscale](https://tailscale.com) network, so the phone gets desktop-class AI from anywhere.
- **Natural neural voice.** Speech comes from a self-hosted [Kokoro](https://github.com/thewh1teagle/kokoro-onnx) TTS server. Replies stream **sentence by sentence**, so ECHO starts talking before the model has finished thinking.
- **19 tools the model can call:** calendar and reminders, Schoology assignments (school LMS API), weather, news, stock and crypto prices, timers, music control, Gmail inbox, food/water logging with nutrition summaries, **screen vision** (Gemma 3 looks at your screen and answers questions about it), long-term memory, and a spoken daily briefing.
- **Four personalities:** Classic butler, Witty, Hype coach, Zen.
- **Built into the OS:** Siri App Intents ("Hey Siri, ask ECHO…"), a menu-bar extra on macOS, and a morning briefing that asks "Ready for your briefing?"
- **One codebase, two platforms:** the same SwiftUI project builds for macOS and iOS.
- **Anti-hallucination rules:** the system prompt forces tool use for facts (prices, weather, schedule) instead of letting the model guess.

## Architecture

```
 iPhone app ─┐                       ┌─ Ollama  (Llama 3.1 8B chat, Gemma 3 vision)
             ├── Tailscale VPN ──────┤
 Mac app ────┘                       └─ Kokoro TTS server (neural voice)
      │                                   Windows desktop, Radeon GPU, always on
      └─ tools: EventKit · Schoology API · Open-Meteo · Gmail · screen capture · …
```

## Build it yourself

1. Install [Ollama](https://ollama.com) and pull a model: `ollama pull llama3.1:8b` (8B models need ~8 GB of VRAM; `llama3.2` works on smaller machines).
2. Open `jarvis.xcodeproj` in Xcode 16+, choose your own signing team, and run on "My Mac" or an iPhone.
3. In ECHO's settings (the gear icon), point it at your Ollama URL. Optional: Kokoro TTS server, Schoology API key, Gmail app password.

## What I learned

Streaming LLM output into a speech pipeline without gaps, LLM tool calling, Swift concurrency, iOS App Transport Security, App Intents, and running a GPU inference server across a home network.

*Built with Swift and SwiftUI, with help from AI coding tools (Claude Code). I designed the features and system, tested everything on my own devices, and use it daily.*
