# Whispeur

**Replace macOS dictation with Whisper. Locally, and for free.**

Whispeur is a menu bar app that takes over the Dictation key on your Mac and runs
[whisper.cpp](https://github.com/ggerganov/whisper.cpp) instead of Apple's dictation. You hold the key, you
speak, you release — the text lands in whatever field had focus. Nothing leaves your machine.

<!-- TODO: screenshot or a short GIF of the menu bar + a dictation landing in a text field -->

## Why another Whisper app

Most Whisper apps on macOS are transcription studios: you open them, you drop a file in, you get text out.
Whispeur is not that. It has one job — being the dictation you actually use, all day, without thinking about it.

That shows up in details you only notice when they're missing:

- **It takes the Dictation key itself** (🎤 / F5 on most keyboards), not "one more shortcut". Whispeur reads it
  through a `CGEventTap`, which is the only way to see that key at all — it is invisible to the usual macOS
  event monitors — and consumes it before the system reacts. Any other key or modifier works too.
- **It knows when not to touch your music.** Recording pauses whatever is playing and resumes it after — unless
  you're in a call, and unless the key woke a paused player rather than stopping a playing one.
- **Your vocabulary doesn't fall out mid-sentence.** Proper nouns and jargon you teach it are pinned to every
  decoding window, instead of being pushed out of the context buffer once the dictation gets long.
- **It gives your clipboard back.** Auto-paste borrows the pasteboard and restores what was there before.

It is free, has no account, no server, and no telemetry. It is around 3 MB.

## Install

Download the latest `.dmg` from [Releases](https://github.com/emilienrk/whispeur/releases/latest), drag
Whispeur to Applications, and launch it. Updates come to you automatically after that (via Sparkle).

**Requirements:** macOS 26 or later, on Apple Silicon.

> **First launch:** builds are currently ad-hoc signed, not notarized, so macOS will refuse the first open.
> Right-click the app → **Open** → **Open**. You only do this once.

Whispeur will ask for two permissions on first run, and explains each one as it does:

| Permission | What it is for |
| --- | --- |
| **Microphone** | Recording your voice. Nothing else. |
| **Accessibility** | Reading the Dictation key, and pasting into the focused field. |

## Using it

Hold the Dictation key, speak, release. That's the whole product.

- **Push-to-talk** (default) records while the key is held. **Toggle** starts and stops on separate presses.
- The menu bar icon shows the state, and your favourite models are one click away in the menu.
- Everything you dictate is kept in a local history you can re-copy, edit, or delete, in Settings › History.
- The shortcut is yours to change in Settings › General — including single modifiers like `fn`.

## Models

Whispeur downloads ggml models on demand into
`~/Library/Application Support/Whispeur/Models/`. The full [whisper.cpp catalog](https://huggingface.co/ggerganov/whisper.cpp)
is available — 33 variants, from `tiny` at 31 MiB to `large-v3` at 2.9 GiB, in F16 and quantized flavours.

The default is **`large-v3-turbo-q5_0`** (547 MiB): the best quality-per-second of the family, and weaker only
at translation, which Whispeur never does. Slow connection? The onboarding offers `base-q5_1` at 57 MiB instead.

Settings › Engine exposes the rest: decoding strategy (greedy or beam search), a vocabulary prompt with
presets, Silero VAD to drop silence before transcription, Metal GPU acceleration, and how long a model stays
resident in RAM between dictations.

## Privacy

Everything runs on your Mac. The engine is compiled into the app, models are files on your disk, and no audio
or text is ever sent anywhere. The only network calls Whispeur makes are downloading a model you asked for and
checking for its own updates.

## Building from source

You need [XcodeGen](https://github.com/yonaskolb/XcodeGen), CMake, and Xcode 26.

```sh
git clone --recursive https://github.com/emilienrk/whispeur.git
cd whispeur
make build          # compiles whisper.cpp, generates the project, builds Release
```

Other targets: `make setup` to only generate the Xcode project, `make dmg` to package it, `make clean` to start
over. Tests run with `xcodebuild test -scheme WhispeurTests -destination 'platform=macOS'`.

Releases are cut with `make release VERSION=x.y.z` — see [docs/RELEASING.md](docs/RELEASING.md).

## Contributing

Issues and pull requests are welcome. Bug reports are most useful with your macOS version, your Mac model, and
the model you were running.

Commits follow [Conventional Commits](https://www.conventionalcommits.org/).

## License

<!-- TODO: pick one and add the LICENSE file. MIT is the low-friction default; -->
<!-- GPL-3.0 matches whisper.cpp's ecosystem expectations without being required by it. -->

Whispeur bundles [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (MIT) and
[Sparkle](https://sparkle-project.org) (MIT).
