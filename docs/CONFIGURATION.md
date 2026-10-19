# DEsk configuration reference

Everything DEsk reads and writes, for v0.1 (BETA). Shell Settings
(`desk-settings`) edits `shell.conf` for you; everything here can also be
edited by hand, and DEsk picks up a changed `shell.conf` within a second.
Unknown keys and bad values are reported in the session log
(`~/.local/state/desk/session.log`) and otherwise ignored.

`$XDG_CONFIG_HOME` is `~/.config`, `$XDG_DATA_HOME` is `~/.local/share`,
`$XDG_STATE_HOME` is `~/.local/state` and `$XDG_CACHE_HOME` is `~/.cache`
unless set otherwise.

## Files

| File | Written by | What it holds |
| --- | --- | --- |
| `$XDG_CONFIG_HOME/desk/shell.conf` | Shell Settings, you | DEsk's settings (below). |
| `/etc/xdg/desk/shell.conf` | the installer | The machine's defaults, under each user's own file; the installer writes the Graphics level it measured. |
| `$XDG_CONFIG_HOME/desk/displays.conf` | DEsk | How a display tool last arranged each set of screens. |
| `$XDG_CONFIG_HOME/desk/drawer` | DEsk | The programs in the drawer, in order. |
| `$XDG_CONFIG_HOME/desk/shelves.conf` | you | Programs filed on a shelf other than their own. |
| `~/.config/desk-mimeapps.list` | you | Default programs inside DEsk only, before `mimeapps.list`. |
| `$XDG_DATA_HOME/desk/calendar` | DEsk | Notes stuck on the calendar. |
| `$XDG_DATA_HOME/desk/memo` | DEsk | The memo pad's sheets. |
| `$XDG_CACHE_HOME/desk/` | DEsk | The traced room, icons converted from SVG, your picture for the door. Safe to delete; it is made again. |
| `$XDG_STATE_HOME/desk/session.log`, `session.log.old` | `desk-session` | What DEsk said this session and the one before. |
| `$XDG_STATE_HOME/desk/install.log` | `install_session.sh` | What the last install run through it said (one run straight from `install_<system>.sh` says it only on the terminal). |
| `$XDG_STATE_HOME/desk/cpu-letter` | DEsk | When the "running on the CPU" letter was last sent. |

DEsk writes every file to a new name and renames it into place, so a crash
never leaves half a file.

## shell.conf

One `key = value` per line; `#` starts a comment.

### Windows

| Key | Values | Default | |
| --- | --- | --- | --- |
| `paper_for_all_windows` | `yes`, `no` | `yes` | Lay programs that draw their own frame (Firefox, GNOME programs) on paper too. |
| `paper.<program>` | `yes`, `no` | | One program the other way. `<program>` is its desktop file id, app id or X class. |
| `throw_closed_windows` | `yes`, `no` | `yes` | Crumple a closed window and throw it away. |
| `corner_on_hover` | `yes`, `no` | `yes` | Turn a corner up when the pointer rests on it (otherwise only on a click). |

### The desk

| Key | Values | Default | |
| --- | --- | --- | --- |
| `scale` | `auto`, a number from `0.5` to `4`, or a percentage (`125%`) | `auto` | Pixels per point. `auto` follows the screen's density. |
| `graphics` | `ultra`, `high`, `medium`, `low`, `2d` | `high` (`2d` when the screen is drawn on the CPU) | How much is drawn. |
| `motion` | `brisk`, `normal`, `gentle` | `normal` | How long movements take. |
| `camera_bounce` | `normal`, `low`, `off` | `normal` | How far the view swings past and settles. |
| `language` | `auto`, `en`, `ja`, `zh`, `ko`, `es`, `fr`, `de` | `auto` | The desk's words and the names programs are filed under. `auto` follows `LC_ALL`, `LC_MESSAGES`, `LANG`. |
| `clock` | `24h`, `12h` | `24h` | |
| `lights_at_login` | `yes`, `no` | `yes` | The room starts dark and the lamp comes up as it is made. |
| `celebrations` | `yes`, `no` | `yes` | The door and clock on certain days (not in Shell Settings). |
| `bell` | `none`, or a desktop file id (`grok-bot.desktop`) | `none` | A brass service bell on the tray, between the clock and the post box. Clicking it brings that program's window to the front (unfolding it if it was folded away), or starts the program if it has no window. Not in Shell Settings. |

### Screen

| Key | Values | Default | |
| --- | --- | --- | --- |
| `screen_off` | `never`, or minutes (`1` to `1440`) | `10` | Minutes untouched before the screen goes dark. |
| `lock_on_screen_off` | `yes`, `no` | `yes` | Lock (the front door) when it does. |

### Keyboard and pointer

| Key | Values | Default | |
| --- | --- | --- | --- |
| `tap_to_click` | `yes`, `no` | `yes` | |
| `natural_scrolling` | `yes`, `no` | `no` | |
| `pointer_speed` | `slow`, `normal`, `fast`, or `-1` to `1` | `normal` | |
| `left_handed` | `yes`, `no` | `no` | |
| `keyboard_layout` | `system`, or an xkb layout (`us`, `jp`, `de`, `us(intl)`) | `system` | |
| `keyboard_second` | `none`, or an xkb layout | `none` | A second layout to switch to. |
| `keyboard_switch` | `alt_shift`, `super_space`, `ctrl_shift`, `caps_lock` | `alt_shift` | |
| `key_repeat` | `slow`, `normal`, `fast` | `normal` | |

### Days and weather

| Key | Values | Default | |
| --- | --- | --- | --- |
| `birthday` | `MM-DD` | none | |
| `weather` | `yes`, `no` | `yes` | Ask open-meteo.com every half hour for the weather at your time zone's city (only its latitude and longitude are sent). |

### Drawer and ALL APPS

| Key | Values | Default | |
| --- | --- | --- | --- |
| `drawer_closes` | `yes`, `no` | `yes` | Close the drawer after something in it is used. |
| `fold_into_drawer` | `yes`, `no` | `no` | Folded windows go into the drawer instead of lying on the desk. |
| `take_sheet` | `yes`, `no` | `yes` | A program taken from ALL APPS has its sheet carried down first. |
| `app.terminal`, `app.browser`, `app.files`, `app.editor` | a desktop file id (`xfce4-terminal.desktop`) | | The standard programs, instead of DEsk's choice. |

### Sound

| Key | Values | Default | |
| --- | --- | --- | --- |
| `sound` | `off`, `quiet`, `normal` | `normal` | |
| `letter_sound` | `yes`, `no` | `yes` | Hear a letter arrive. |

## displays.conf

Written when a display tool (wdisplays, wlr-randr, kanshi) changes the
screens, and applied again whenever the same set of screens is connected.
The size of a point is not kept here; it is `shell.conf`'s `scale`.

```
set = <screen> + <screen> ...
screen = <make> / <model> / <serial>    (or the connector name, DP-1, if there is no serial)
enabled = yes | no
mode = <width>x<height>@<Hz> [custom]
position = <x>,<y>                      (pixels; the desk's screen is at 0,0)
transform = normal | 90 | 180 | 270 | flipped | flipped-90 | flipped-180 | flipped-270
```

The screen at position 0,0 is the one the desk is drawn on; any other shows
a plain desk for windows.

## shelves.conf

```
# desktop file id = shelf
org.kde.kate.desktop = Development
```

Shelves: `Development`, `Internet`, `Office`, `Graphics`, `Media`, `Games`,
`Utilities`, `System`.

## The front door

The door (the lock, and leaving) is traced on the GPU when the room is,
on a thread and GL context of its own, and on the CPU otherwise: with
`DESK_NO_GPU` or `DESK_DOOR_CPU`, on a software renderer (llvmpipe), when
the room's own GPU check found the driver unfit, if the GPU fails at any
point (from then on until DEsk restarts), and while the door's shader is
first being compiled. That first compile takes about half a minute; the
driver keeps it (NVIDIA in `~/.nv`, Mesa in `~/.cache/mesa_shader_cache`),
so afterwards it is ready at once. Both draw the same door; the GPU's
frames match the CPU's finest to within rounding.

What `graphics` gives up for the door only spares the CPU, so on the GPU
none of it applies and the door is drawn in full at every level:

| | CPU | GPU |
| --- | --- | --- |
| Size | no larger than the room's overlays (1280 wide at `medium`, 960 at `low`, 640 at `2d`) | the screen's own |
| While the eye moves | 50 to 85% of that, as keeps about 30 frames a second; finely only once it stops | the whole size, every edge smoothed, every frame; only if a frame takes over 25 ms (a dressed door at night on a small GPU) smaller while moving, never under half, and the whole size again as soon as it stops |
| At `2d` | half size again | the whole size |
| The walk up to the door | not at `low` or `2d` | at every level |
| Rain, snow, lights | 30 times a second (15 at `low`) | every frame |


For users:

| Variable | |
| --- | --- |
| `DESK_SCALE` | Pixels per point (overrides `scale`). |
| `DESK_ROOM_W` | Trace the room at this width (320 to 3840), whatever the GPU. |
| `DESK_NO_GPU` | Trace the room on the CPU. |
| `DESK_GPU_NODE` | Trace the room on this render node (`/dev/dri/renderD129`). |
| `DESK_ON_CPU` | `1` or `0`: say whether the screen is drawn on the CPU instead of detecting it. |
| `DESK_NO_XWAYLAND` | Do not offer X11. |
| `DESK_SLOW` | Make every movement this many times slower. |
| `DESK_SOUND` | `auto`, `pulse`, `alsa`, `off`, or `file:PATH` (`%p` is the process id). |
| `DESK_LOOK` | `0`: do not install DEsk's icons and GTK theme into its dconf layer. |
| `DESK_LOG` | `-`: `desk-session` leaves the log on stderr instead of `session.log`. |
| `DESK_ALLOW_MULTIPLE` | `1`: start even though a DEsk is already running for this user. |
| `DESK_SIZE`, `DESK_RENDERER` | For `desk-window`: the window's size, and `pixman` or `gles2`. |

For development and testing:

| Variable | |
| --- | --- |
| `DESK_PROFILE`, `DESK_PROFILE_FRAMES` | Frame timings in the log; a CSV of every frame. |
| `DESK_TODAY` | Pretend it is this date (`2026-12-24T18:00`). |
| `DESK_WEATHER` | Pretend the weather is `clear`, `clouds`, `overcast`, `fog`, `rain`, `snow` or `storm` (`rain:0.8` for how heavy). |
| `DESK_LOCK_PAM_DIR` | Check the lock's password against this PAM directory (only when not the real session). |
| `DESK_ROOM_GLSL` | Load the room's shader from this file. |
| `DESK_GPU_DUMP` | Write the shader as the driver receives it (the door's as `.door0` and `.door2` to `.door6` beside it). |
| `DESK_DOOR_CPU` | Trace the front door on the CPU (the room stays on the GPU). |
| `DESK_DOOR_GLSL` | Load the door's shader (`src/door.glsl`) from this file. |
| `DESK_DOOR_PROFILE` | Log how long each stage of each door frame took on the GPU. |
| `DESK_LOCK_FINE` | Trace every door frame finely at the whole size, on the CPU too, and never smaller on the GPU (slow on the CPU; what the GPU is compared with). |
| `DESK_LOCK_BENCH` | For `desk-preview --lock`: trace each frame this many times more and give the mean. |
| `DESK_SOUND_DEBUG` | Log each sound's latency. |
| `DESK_SYSFS` | Read the Control Panel's instruments from this directory instead of `/sys`. |

`DESK_SESSION`, `DESK_IM` and `DESK_NESTED` are set by `desk-session` and
`desk-session-helper` for their own use. Old `DESKWM_*` names still work.

## Starting over

- Settings: delete `~/.config/desk/` (or one file in it).
- The traced room: delete `~/.cache/desk/` and it is traced again at the next
  start.
- Notes and memo: `~/.local/share/desk/`.
