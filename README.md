# netease-radio

> **Note:** This project is inspired by and heavily references
> [ytm-radio](https://github.com/LuciusChen/ytm-radio) by Lucius Chen —
> a small-player-style Emacs audio player for YouTube Music.

An experimental Emacs audio player for NetEase Cloud Music.

It follows the small-player shape of `ytm-radio`: Emacs owns the browser buffer,
queue, key bindings, and playback state; external tools do media work.

## Requirements

- Emacs 28.1 or newer
- `mpv`
- `yt-dlp` for importing arbitrary NetEase URLs

## Setup

```elisp
(add-to-list 'load-path "~/.emacs.d/netease-radio")
(require 'netease-radio)
```

## Commands

- `M-x netease-radio` opens the browser with Home/Search/Now-Playing tabs.
- `M-x netease-radio-now-playing` opens the child-frame mini-player.
- `M-x netease-radio-search` searches NetEase Cloud Music.
- `M-x netease-radio-add-playlist` saves a playlist URL to Home view.
- `M-x netease-radio-add-url` imports and plays a NetEase URL via `yt-dlp`.
- `M-x netease-radio-play-track` selects a known track.
- `M-x netease-radio-toggle-pause` toggles mpv pause.
- `M-x netease-radio-cycle-repeat` cycles repeat off/all/one.
- `M-x netease-radio-toggle-shuffle` toggles shuffle.
- `M-x netease-radio-next` and `M-x netease-radio-previous` move in the queue.
- `M-x netease-radio-stop` stops playback.
- `M-x netease-radio-share` copies the current track URL.
- `M-x netease-radio-doctor` checks local tool visibility.

Inside the browser buffer:

| Key | Action |
| --- | --- |
| `H` | Home (saved playlists) |
| `/` | Search NetEase Cloud Music |
| `N` | Now Playing queue |
| `a` | Add playlist (Home) / import URL |
| `c` | Open now-playing |
| `RET` | Play track at point |
| `s` | Play the current source |
| `TAB`, `S-TAB` | Move between sections |
| `j`, `k`, `Down`, `Up` | Move between rows |
| `SPC` | Toggle pause |
| `n`, `p` | Next / previous track |
| `r`, `x` | Repeat / shuffle |
| `f`, `B` | Seek forward / backward |
| `S` | Copy current track URL |
| `g` | Refresh last search |
| `q` | Quit window |

The now-playing view mirrors `ytm-radio`: by default it opens as a small child
frame in graphical Emacs, with centered title, artist, progress text, and
clickable repeat/previous/play/next/shuffle controls. Set
`netease-radio-display-style` to `buffer` to show it in a normal window. Cover
images are read from NetEase search results or `yt-dlp` metadata, cached locally,
and rendered in this view when Emacs supports the image type.

Runtime state is stored in:

```text
~/.netease-radio/state.eld
```

Cover images are cached under:

```text
~/.netease-radio/covers/
```
