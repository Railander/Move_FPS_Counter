# Move FPS Counter

Super lightweight addon that moves the default FPS counter and remembers its state, on every version of the game. Type `/movefps` in chat to open the configuration window.

## Commands

- `/movefps` — open the configuration window
- `/movefps reset` — restore every setting to the game's defaults

Any other input opens the window as well.

## The config window

- **move counter** — turn on move mode, then drag the counter anywhere; a green square marks its exact spot. Closing the window leaves move mode.
- **X / Y** — move the counter, with boxes for exact values (or drag it in move mode)
- **Size** — change the counter's text size, starting at the game's own size
- **Decimals** — choose how many decimal places the framerate shows (0, 1 or 2)
- **Anchor** — which part of the counter stays put (center, any side or any corner) when its width fluctuates between single-digit and triple-digit FPS
- **Remember** — remember the counter's shown/hidden state between sessions, so it comes back exactly as you left it when you login/reload

## Compatibility

Works on Modern, Classic Era, TBC, Wrath, Cataclysm and Mists.

## Links

- [Changelog](CHANGELOG.md)
