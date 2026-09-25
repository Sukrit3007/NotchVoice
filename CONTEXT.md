# Notch Voice

Notch Voice is a local macOS dictation tool whose primary status surface is the MacBook notch.

## Language

**Dictation**:
A single hold-to-talk recording and the text produced from it.
_Avoid_: capture, request, job

**Notch Surface**:
The temporary status UI anchored to the MacBook's physical notch, including its connected message panel.
_Avoid_: floating pill, bottom pill

**Processing**:
The period after recording stops while audio is transcribed, rewritten, delivered, and saved.
_Avoid_: recording, cleanup

**Cleanup Session**:
One isolated on-device language-model interaction used to tidy one transcript.
_Avoid_: conversation, chat history

**Copy-only Delivery**:
A completed transcript placed on the clipboard because the original target application could not be verified safely.
_Avoid_: failed paste

**Temporary History**:
The in-memory store used when the persistent history database cannot be opened; it lasts only for the current launch.
_Avoid_: empty history, lost dictation
