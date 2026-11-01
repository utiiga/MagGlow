<p align="center">
  <img src="docs/icon.png" alt="MagGlow icon" width="128">
</p>

# MagGlow

Keep your Mac awake with the lid closed, and know at a glance that it's still
working: **the MagSafe charger LED blinks while the Mac is awake with its
display off.**

Made for leaving a laptop closed while an agent (Claude Code, a long build, a
download…) keeps working, without wondering whether it fell asleep.

## What it does

- **On power:** the Mac never sleeps, not even with the lid closed.
- **On battery:** it sleeps as usual, but from the menu bar you can keep it
  awake with the lid closed for **15 min, 30 min or 1 h**. When the time is up
  (or you cancel) and the lid is closed, it goes to sleep right away.
- **The MagSafe LED blinks green** while the Mac is awake with the lid closed
  or the display off. The rest of the time the LED behaves as usual.
- Menu bar icon: a connector with its LED lit (on power), hollow (on battery),
  or with the minutes left while a timer is running.

The interface is in English and Spanish, following your macOS language.

## Requirements

- Apple Silicon MacBook with a MagSafe 3 port (2021 or later MacBook Pro / Air).
- macOS 14 Sonoma or later.
- A MagSafe cable with an LED (Apple's own).

## Install

Open Terminal (⌘-Space, type "Terminal"), paste this and press Return:

```sh
curl -fsSL https://raw.githubusercontent.com/utiiga/MagGlow/main/scripts/install.sh | bash
```

It downloads the latest release into Applications, installs the background
helper (asks for your admin password once) and opens the app. Look for the
connector icon in the menu bar.

### Build from source

You need the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/utiiga/MagGlow.git
cd MagGlow
make install
```

## Uninstall

```sh
sudo /Applications/MagGlow.app/Contents/Resources/uninstall.sh
```

It stops the helper, hands the LED back to macOS, re-enables sleep and removes
the app and its files.

## How it works

MagGlow has two parts:

- **The menu bar app** (runs as you): shows the state, runs the timer and
  reports when the display goes to sleep. It writes what it wants to
  `/Library/Application Support/MagGlow/request.json`.
- **The helper** (`com.magglow.helper`, a launchd daemon running as root):
  reads that request every half second and
  - blocks or allows sleep with `pmset disablesleep`;
  - blinks the LED by writing the SMC key `ACLC`
    (`3` green, `1` off, `0` macOS control).

  It publishes its state in `status.json` for the app to display.

### Is it safe?

- `ACLC` only changes what the LED *shows*; it doesn't touch charging,
  voltage or battery management.
- Whenever the helper stops (uninstall, shutdown or a crash) it hands the LED
  back to macOS and re-enables sleep, so the Mac is never left unable to sleep.
- Right before the Mac goes to sleep, the LED returns to macOS control.

**Heads-up:** on power with the lid closed, the Mac won't sleep. Don't put it
in a sleeve or backpack like that: it can get hot.

## Credits

The idea of driving the LED through `ACLC` comes from projects like
[MagHue](https://github.com/kamenlevi/MagHue),
[batt](https://github.com/charlie0129/batt) and
[BatFi](https://github.com/rurza/BatFi).

## License

[MIT](LICENSE)
