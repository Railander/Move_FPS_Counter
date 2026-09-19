# Move FPS Counter Changelog

## v2.2.0
- The counter now works in World of Warcraft: Forever (beta).

## v2.1.0
- Everything now works while fighting: dragging the counter, typing coordinates, changing the size, anchor or decimals, and reset all apply instantly mid-combat and in Mythic+ / rated PvP, with no errors — nothing waits silently for the fight to end anymore.

## v2.0.1
- Fixed: on Retail the counter no longer gets stuck after reloading the UI mid-combat (or in Mythic+/rated PvP, which restrict addons even out of combat) — it now waits silently and resumes by itself once the fight is over.
- Fixed: on Retail the FPS keybind toggle keeps working in combat instead of silently breaking after the addon loads.

## v2.0.0
- New: `/movefps` now opens a config window. A "move counter" button makes the counter drag-movable while it is on, with a translucent green grab square over the counter; the X/Y boxes show exact coordinates with two decimal places.
- New: an anchor picker chooses which part of the counter stays put when its width fluctuates (single-digit FPS vs triple-digit with two decimals) — the center, any of the four sides or any corner.
- New: text size is configurable with one decimal place and starts at the game's own counter size; the number of decimal places shown for the framerate (0, 1 or 2) is a small slider.
- Rewritten from the ground up as a single implementation shared by every game version, so all features now work everywhere.
- Fixed: on Classic versions the counter no longer shows up at the center of the screen on login or reload; out of the box it now stays exactly where the game puts it, and once moved it stays put from the very first frame.
- The counter now keeps its position on its own, including when the micro menu moves or other addons shuffle the UI.
- Fixed: the remembered shown/hidden state now stays correct in every combination of toggling the counter, changing the remember option, and using the config window's preview.
- Fixed: positions saved by v1.9 with out-of-range coordinates (its command accepted any number) no longer lock the counter to the screen center; they fall back to the game's own placement.
- Existing settings carry over automatically: players who had configured a position keep it exactly, including which part of the counter was anchored; players who never moved the counter get the game's own placement instead of the old mid-screen default.
- On the first login after installing (or after upgrading from v1.9), the addon prints a short chat note about /movefps and /movefps reset.
- `/movefps reset` restores every setting to the defaults; any other input opens the config window.
