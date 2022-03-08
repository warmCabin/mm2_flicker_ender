# Overview

mm2_flicker_ender reimplements a few of Rockman 2's drawing routines in Lua to overcome the 64-sprite limitation. The goal of this script is to draw the exact tiles the game would have drawn if OAM was infinite.

Only compatible with **Rockman 2** for now. Not Mega Man 2, not Super Mario Bros. 2, not Rockman 3. Just Rockman 2. Mega Man 2 support should eventually be possible. The tiledraw script is more general purpose, and could be reused in a project like this for a different game.

[Video explanation](https://www.youtube.com/watch?v=ua4mlVy9x1Y)

# Arguments

There are a few arguments you can specify in the script window to tweak the drawing order to your liking.
By default, this script imitates the alternating drawing order of the game, equivalent to the arguments: `--order canonical --shuffle alternating`

```
Usage: flicker_ender.lua [-h] [--order {canonical,recommended}]
       [--shuffle {alternating,cyclic,none}]
       [--oam-limit <num sprites>] [--disable-i-frame-flicker]
       [--debug] [--verbose]

Options:
   -h, --help            Show this help message and exit.
   --order {canonical,recommended},
        -o {canonical,recommended}
                         Sprite drawing order. canonical = what the game does. recommended = tweaks to fix certain overlapping issues
   --shuffle {alternating,cyclic,none},
          -s {alternating,cyclic,none}
                         What type of sprite shuffling to use. The real game code uses alternating. (default: alternating)
   --oam-limit <num sprites>,
            -l <num sprites>
                         Limit for the imitation OAM. 64 is the NES default, infinite is the flicker_ender default. Use this if you want to make flicker worse!
   --disable-i-frame-flicker, -i
                         Whether Mega Man and bosses should flicker on and off during i-frames
   --debug, -d           Enable debug mode. Offset rendering and draw some info to the screen
   --verbose, -v         Enable verbose printing, up to 3 levels. WARNING: very slow!
```

## Orderings

Really only noticeable if shuffle = none.

- Canonical: The order of objects as laid out in memory. Health bars appear behind everything else.
- Recommended: A modified drawing order that I think looks best. Health bars appear in front of everything else, and bosses are shifted to draw behind Mega Man's projectiles.

## Shuffle

- None: Fixed drawing order. Uses the recommended order by default.
- Alternating: Reverses the drawing order every frame, in case a set drawing order unnerves you! I recognize that enforcing a set drawing order on a game that does not have one can lead to some visibility issues. Uses canonical order by default.
- Cyclic: Changes the first sprite drawn each frame, cycling every 4 frames (starts on 0, then 4, 8, 12). Uses canonical order by default.

## OAM Limit

Sets a limit for how many sprites can be drawn each frame. While this may seem antithetical to the purpose of this script, here are the uses cases that motivated its inclusion:
- You can set it to 64 to play around with different flicker algorithms
- You can set it to 80 or so if you are experiencing slowdowns from unbounded OAM
- You can set it to less than 64 for a good laugh

## Disable i-frame flicker
An enhancement mainly for TASing. It turns off the 2-frame flicker that occurs during invincibility frames so you can better see what you're doing.
