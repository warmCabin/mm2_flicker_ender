# Overview

mm2_flicker_ender reimplements a few of Rockman 2's drawing routines in Lua to overcome the 64-sprite limitation. The goal of this script is to draw the exact tiles the game would have drawn if OAM was infinite.

Only compatible with **Rockman 2** for now. Not Mega Man 2, not Super Mario Bros. 2, not Rockman 3. Just Rockman 2. Mega Man 2 support should eventually be possible. The tiledraw script is more general purpose, and could be reused in a project like this for a different game.

# Arguments

There are a few arguments you can specify in the script window to tweak the drawing order to your liking.

```
Usage: flicker_ender.lua [-h]
       [--order {canonical,health-bars-in-front}] [--debug]
       [--alternating]

Options:
   -h, --help            Show this help message and exit.
   --order {canonical,health-bars-in-front},
        -o {canonical,health-bars-in-front}
                         Sprite drawing order (default: health-bars-in-front)
   --debug, -d           Enable debug mode. Offset draws and print LOTS of info!
   --alternating, -a     Alternate drawing order every frame
```

## Orderings

- Canonical: The order of objects as laid out in memory. Health bars appear behind everything else.
- Health Bars in Front: Canonical order, but health bars are in front.

## Alternating

The `alternating` flag respects the specfied drawing order and reverses it every frame, in case a set drawing order unnerves you!  
Try `--order canonical --alternating` (or `-ao canonical` if you prefer) to get as close to the real game as possible.

