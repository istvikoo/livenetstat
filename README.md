# livenetstat

NetSpeed is a tiny macOS menu bar utility that shows your live network traffic: current download and upload speed, with a 60-second graph.

It does nothing in the background. The menu bar shows a static icon, and sampling runs only while the panel is open — 0% CPU when closed.

## Features

- Live download and upload speed, updated once per second while the panel is open
- 60-second graph of both directions
- MB/s or Mb/s units (remembered between launches)
- Counts physical interfaces only (Wi-Fi, Ethernet, cellular), so VPN traffic is not counted twice
- No Dock icon, no dependencies, no network requests, no special permissions

## Install

1. Download `NetSpeed.zip` from the [latest release](https://github.com/istvikoo/livenetstat/releases/latest) and unzip it.
2. Move `NetSpeed.app` to Applications.
3. The app is not notarized by Apple, so macOS blocks it on first launch. Clear the quarantine flag once:

```bash
xattr -dr com.apple.quarantine /Applications/NetSpeed.app
```

To start it at login, add it in System Settings → General → Login Items.

Requires macOS 13 or later. The release build is universal (Apple silicon and Intel).

## Build from source

Requires Xcode Command Line Tools (`xcode-select --install`). Xcode itself is not needed.

```bash
./build.sh
```

```bash
open NetSpeed.app
```

## How it works

The app is a single Swift file using SwiftUI's `MenuBarExtra`. Once per second, while the panel is open, it reads per-interface byte counters from the kernel (`sysctl` with `NET_RT_IFLIST2`) and shows the difference since the previous reading. macOS reports these counters truncated to 32 bits to unprivileged apps, so wrap-arounds are handled.

## License

[MIT](LICENSE)
