# Plan

Goal: a desktop companion like the "Furever Dock" cat. It lives on the screen, interacts with
windows and the Dock, and does real tasks when you ask. It's a free, original genie for now; the art can be swapped out later.

## Stage 1: Alive ✅ (first version written, needs testing on a Mac)
- [x] Transparent floating window that clicks pass through everywhere except the genie
- [x] Original genie drawn in code: smoke tail, blinking, eyes follow cursor, leans when flying
- [x] Poses: idle, flying, talking/waving, thinking, tapping, sleeping, reading (focus)
- [x] Wanders, sits on top of the front window and moves with it, follows cursor, naps when you're away
- [x] Drag him around, hover to wake him, click to chat
- [x] Speech bubble with Yes / No questions
- [x] Menu bar item + ⌥Space hotkey

## Stage 2: Powers ✅ (basic)
- [x] Open / quit / hide apps, open websites and searches
- [x] Flies to the real Dock icon and taps it (Accessibility API)
- [x] Quitting always asks first
- [x] Focus timer (pomodoro) with reading pose and countdown clock
- [ ] Click buttons inside other apps (Accessibility actions)
- [ ] Manage browser tabs (AppleScript for Safari / Chrome)
- [ ] Move and resize windows ("put Safari on the left half")
- [ ] Multi-monitor polish (Dock on another screen, hopping between screens)

## Stage 3: Smart
- [x] Claude chat through your Claude Code login (no API bill), API key as fallback
- [ ] Voice: push-to-talk with Speech framework + spoken replies
- [ ] See the screen (screenshot → Claude) so he can explain what you're looking at
- [ ] Memory of your preferences between launches
- [ ] Multi-step tasks ("open my project in Xcode and run it")

## Later
- [ ] Swap in realistic art (AI-generated video clips or a 3D model). `GenieFigure` is the only view to replace.
- [ ] Settings window (hotkey, how often he wanders, nap timeout)
- [ ] Launch at login, signed + notarized build
