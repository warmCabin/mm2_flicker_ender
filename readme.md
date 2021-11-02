# Overview

mm2_flicker_ender reimplements a few of Rockman 2's drawing routines in Lua to overcome the 64-sprite limitation. The goal of this script is to draw the exact tiles the game would have drawn if OAM was infinite.

Only compatible with **Rockman 2** for now. Not Mega Man 2, not Super Mario Bros. 2, not Rockman 3. Just Rockman 2. Mega Man 2 support should eventually be possible. The tiledraw script is more general purpose, and could be reused in a project like this for a different game.

[Video explanation](https://www.youtube.com/watch?v=ua4mlVy9x1Y)

# Arguments

There are a few arguments you can specify in the script window to tweak the drawing order to your liking.

```
Usage: flicker_ender.lua [-h] [--order {canonical,recommended}]
       [--alternating] [--debug] [--verbose]

Options:
   -h, --help            Show this help message and exit.
   --order {canonical,recommended},
        -o {canonical,recommended}
                         Sprite drawing order (default: recommended)
   --alternating, -a     Alternate drawing order every frame
   --debug, -d           Enable debug mode. Offset rendering and draw some info to the screen
   --verbose, -v         Enable verbose printing. WARNING: very slow!
```

## Orderings

- Canonical: The order of objects as laid out in memory. Health bars appear behind everything else.
- Recommended: A modified drawing order that I think looks best. Health bars appear in front of everything else, and bosses are shifted to draw behind Mega Man's projectiles.

## Alternating

The `alternating` flag respects the specfied drawing order and reverses it every frame, in case a set drawing order unnerves you! I recognize that enforcing a set drawing order on a game that does not have one can lead to some visibility issues.  
Try `--order canonical --alternating` (or `-ao canonical` if you prefer) to get as close to the real game as possible.

