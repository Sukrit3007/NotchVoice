# Notch Voice acceptance matrix

Run this checklist on the physical MacBook that will ship the app. External displays only
need the fallback HUD check; the notch is the primary surface.

| Area | Steps | Expected result |
|---|---|---|
| Idle surface | Launch the app and wait | No floating pill or island is visible |
| Notch recording | Hold `fn`, speak, and keep holding | Recording status appears in the real MacBook notch |
| Processing | Release `fn` after a short dictation | Transcribing and cleanup status stay anchored to the notch |
| Long result | Dictate a paragraph | The connected panel expands down from the notch and closes calmly |
| Hands-free | Press `fn`+`Space`, speak, press `fn` again | The same notch flow is used |
| Busy key press | Start a dictation, then press the key again while processing | The notch says “Still processing”; no second recording starts |
| Paste | Dictate into TextEdit, then repeat in a browser text field | Each result pastes into the application active at dictation start |
| Changed target | Start dictation in TextEdit, switch applications before delivery | Nothing is pasted into the new app; the result remains on the clipboard and the notch explains copy-only delivery |
| Microphone | Deny and then grant microphone access | The app shows a clear error and recovers after permission is granted |
| Accessibility/input | Deny and then grant required event permissions | The hotkey setup explains what is missing and works after re-granting |
| External display | Move the app to a monitor without a notch | A temporary compact HUD appears on that screen only |
| Sleep/wake | Dictate before sleep and after wake | The app returns to an idle hidden state and dictation still works |
| Reduced motion | Enable Reduce Motion in macOS and repeat recording | State changes cross-fade without spring motion |
| History | Save a capture, quit, relaunch, and open Library | Existing history, dictionary entries, and snippets remain available |
| Temporary store | Make the persistent store unavailable and launch | Library visibly warns that history is temporary for this launch |
