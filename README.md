# Cuts

Cuts is an open-source macOS menu-bar app for screenshots, annotations, and clipboard history, with optional mouse controls.

**[简体中文](#中文说明)** · **[Product page](https://www.devgo.io:5201/products/cuts)**

## What you can do

- Capture a region, including across displays. Pick a pixel color, take a scrolling capture with live preview, or pin a captured image above other windows.
- Annotate with freehand strokes, arrows with a draggable bend point, shapes, styled text, numbered markers, a magnifier, mosaic, and whole-mark or local erasing. Use on-device text recognition to select and copy text in place.
- Search and paste recent text, images, and file references. Hold ⌘V for 300 ms by default to open history; a short press still pastes. Save favorites or annotate an image from history without replacing its original.
- Choose annotation defaults with live previews, configure capture shortcuts, and export PNG or lossless WebP. Oversize WebP exports are offered as original-size PNG.
- Optionally reverse wheel axes, set wheel speed, or map mouse buttons 3/4 to back and forward shortcuts. This does not change hardware DPI.

## Build from source

Requires **Apple silicon**, **macOS 26 or later**, Xcode or command-line tools with the macOS 27 SDK, and Homebrew's libwebp:

```sh
brew install webp
zsh scripts/build-app.sh
open dist/Cuts.app
```

The default build is ad-hoc signed for local development, not notarized. Set `CUTS_CODESIGN_IDENTITY` to a signing identity available in your Keychain when you need a stable signing identity across builds. Screen capture requires macOS screen recording permission. System-wide hold shortcuts, automatic paste, and mouse event processing require the appropriate macOS access; the menu remains available without those input features.

Run the desktop smoke tests on a logged-in Mac with:

```sh
open -n -W -a "$PWD/dist/Cuts.app" --args --self-test
```

This repository contains source, not a notarized installer. Patches and reproducible bug reports are welcome. Please attach only synthetic screenshots or redacted logs to public issues.

## Local data

Cuts processes captures and OCR on the Mac. Clipboard history is stored locally: up to 50 recent entries, up to 10 favorites, and a shared storage budget. File entries store paths, not a copy of the original files. Clipboard items marked concealed, transient, or automatically generated are skipped; other applications do not always mark sensitive content. Diagnostics are local and can be disabled. This repository does not contain anyone's clipboard history, logs, or signing materials.

## 中文说明

Cuts 是一款 macOS 菜单栏工具，把跨屏截图、滚动长截图、贴图、标注和剪贴板历史放在一起，并提供可选的鼠标增强。默认长按 ⌘V 300 ms 打开历史，短按继续普通粘贴；历史可搜索、收藏，图片可二次标注。

需要 Apple 芯片的 Mac、macOS 26+、带 macOS 27 SDK 的 Xcode 或命令行工具，以及 Homebrew 的 `webp`。运行 `zsh scripts/build-app.sh` 后，应用位于 `dist/Cuts.app`。仓库提供源码，不包含公证安装包；系统级功能需要相应的 macOS 授权。

## License

Cuts source and the icons included in this repository are licensed under the [MIT License](LICENSE). libwebp is installed as a separate build dependency. Its [license](https://github.com/webmproject/libwebp/blob/main/COPYING) and [patent grant](https://github.com/webmproject/libwebp/blob/main/PATENTS) apply to libwebp; they are included in the app bundle when building.
