# imgv

A terminal file browser whose main job is image previews. It is one bash script, made for Ghostty through tmux on a remote host over a slow link.

```
 ~/photos
 trips/                             │
 IMG_0412.JPG              3.4 MiB  │            (image)
 IMG_0413.JPG              2.9 MiB  │
 notes.txt                    64 B  │
                                    │ Name     IMG_0412.JPG
                                    │ File     3.4 MiB · 2026-03-01 14:22
                                    │ Type     JPEG · YCbCr 8-bit · baseline
                                    │ Image    4032×3024 · 12.1 MP · 4:3
                                    │ Camera   Apple iPhone 15
                                    │ Shot     f/1.8 · 1/120 s · ISO 64 · 6.8 mm
                                    │ Preview  normal 768×576 · 182.0 KiB
 j/k move  h/l dir  z zoom  +/- quality  / search  ? help  q quit
```

## Install

Copy the file `imgv` to the remote host and make it executable. Nothing else is needed.

```bash
scp imgv remote:~/bin/imgv && ssh remote chmod +x '~/bin/imgv'
```

One-line version, from a checkout on the remote host:

```bash
install -m 755 imgv ~/bin/imgv
```

## Use

```bash
imgv                 # browse the current directory
imgv ~/photos        # browse a directory
imgv ~/photos/a.jpg  # open the directory with that file selected
imgv --help          # every option
```

Press `?` in the program for the keys.

## What it needs

- bash 3.2 or later, `stty`, and the file tools of a GNU, a BSD or a busybox system. Ubuntu 22.04 has all of them. A NAS with busybox and an old bash has them too.
- A clock. A current bash has its own. An older bash reads the clock of Linux in `/proc/uptime`. macOS has no such file, so install bash 5 there with Homebrew.
- A terminal with the kitty graphics protocol: Ghostty or kitty. tmux is supported and is the main case.
- `ffmpeg` on the remote host, to decode and shrink images. Without it, only PNG files have a preview. A small ffmpeg build with no `image2` format also works: PNG files go through the `mov` format. The preview names any decoder that the build lacks.
- `file` is optional. It names the type of a file that is not an image.

Over ssh, Ubuntu 22.04 does not know the terminal name of Ghostty, and tmux stops with `missing or unsuitable terminal: xterm-ghostty`. This is a tmux matter, not one of `imgv`. Copy the entry to the remote host one time, or connect with a name it knows:

```bash
infocmp -x xterm-ghostty | ssh remote -- tic -x -
TERM=xterm-256color ssh remote
```

Image details come from a parser in the script itself. It reads PNG, JPEG, GIF, BMP, WebP, TIFF, OpenEXR and Radiance HDR headers, and the EXIF camera data.

## Formats

| Format | Preview | Notes |
|---|---|---|
| PNG | yes | a small file goes to the terminal as it is |
| JPEG, WebP, GIF, BMP, TIFF | yes | ffmpeg decodes, EXIF rotation is applied |
| OpenEXR (`.exr`) | yes | ffmpeg decodes, linear light is shown with the sRGB curve |
| Radiance (`.hdr`) | yes | a bash decoder expands the data when ffmpeg is too old to read the format |
| AVIF, HEIC, JPEG XL and others | when the installed ffmpeg reads them | details come from ffprobe |

Bright areas of an EXR or HDR picture clip at white. The decoder for `.hdr` is slow on a large file, and its result is kept for the session.

## How it stays responsive

- A background job decodes each image. The keys never wait for it.
- The image goes out in small windows. After each window the terminal answers a short question, so the program knows what the link can carry and adapts the window size.
- A key press stops a transfer at once. A small draft arrives first, and the full preview replaces it when you stay on the file.
- `+` and `-` change the preview quality, which is the number of bytes on the link.
- A finished image stays in the terminal. When you return to it, it shows at once, with no new transfer.
- While the selection rests, the images next to it load ahead. `--no-preload` turns this off.
- `f` changes the scaling from smooth to nearest, which keeps the pixels of a small image sharp. `--filter nearest` starts with it.
- A terminal that answers nothing gets a fixed send rate (`--rate`). The program then watches the byte counters of tmux. When tmux dropped part of an image, the image goes out again at half the rate.

In tmux, the program turns on `allow-passthrough` for its own pane and restores it on exit. The tmux client must be in UTF-8 mode: use a UTF-8 locale or attach with `tmux -u`. The program says so when it is not.

## Develop

The source is `imgv.sh` plus the pieces in `src/`. [bashfs](https://github.com/wow-look-at-my/bashfs) joins them with `--encoding plain`, which includes each piece as readable text between marker comments. Nothing in `imgv` is compressed or encoded.

```bash
./build.sh           # writes imgv
dats dats/           # runs the tests
```

The tests run `imgv` on a fake terminal (`dats/lib/fake-term.sh`) that answers like Ghostty, limits the link speed, and records the image data.

The same tests run a second time with bash 3.2 and the tools of busybox. The first command builds that environment:

```bash
dats/lib/busybox-env.sh .busybox-env
IMGV_SH=$PWD/.busybox-env/bash IMGV_PATH=$PWD/.busybox-env/bin dats dats/
```

`dats/ffmpeg-min.dats` runs `imgv` with a small ffmpeg build, like the one of an embedded system. Its setup builds that ffmpeg in `.ffmpeg-min` the first time.

## License

MIT, see `LICENSE`. The tools it runs keep their own licenses. Bash, coreutils and findutils are GPL-3.0-or-later, tmux is ISC, and ffmpeg is LGPL-2.1-or-later or GPL depending on the build. `imgv` only runs them as programs.
