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

- bash 5, coreutils, findutils and `stty`. Ubuntu 22.04 has all of them.
- A terminal with the kitty graphics protocol: Ghostty or kitty. tmux is supported and is the main case.
- `ffmpeg` on the remote host, to decode and shrink images. Without it, only PNG files have a preview.
- `file` is optional. It names the type of a file that is not an image.

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
- A terminal that answers nothing gets a fixed send rate (`--rate`). The program then watches the byte counters of tmux. When tmux dropped part of an image, the image goes out again at half the rate.

In tmux, the program turns on `allow-passthrough` for its own pane and restores it on exit.

## Develop

The source is `imgv.sh` plus the pieces in `src/`. [bashfs](https://github.com/wow-look-at-my/bashfs) joins them with `--encoding plain`, which includes each piece as readable text between marker comments. Nothing in `imgv` is compressed or encoded.

```bash
./build.sh           # writes imgv
dats dats/           # runs the tests
```

The tests run `imgv` on a fake terminal (`dats/lib/fake-term.sh`) that answers like Ghostty, limits the link speed, and records the image data.

## License

MIT, see `LICENSE`. The tools it runs keep their own licenses. Bash, coreutils and findutils are GPL-3.0-or-later, tmux is ISC, and ffmpeg is LGPL-2.1-or-later or GPL depending on the build. `imgv` only runs them as programs.
