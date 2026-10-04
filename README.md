# Sonic Dream Team Controller

A small macOS menu bar app that makes a tested Xbox-style 2.4 GHz USB controller
usable with **Sonic Dream Team** by translating controller input into keyboard
and mouse events.

This started with a third-party controller sold as a Windows/XInput gamepad:
the receiver paired successfully, but the game did not recognize it as a native
controller. The bridge reads its USB reports directly and sends the inputs that
worked in the tested game setup.

**Compatibility is currently limited to one tested receiver.** This is a
userspace Xbox One GIP bridge, not a general macOS XInput driver. A Windows
"XInput compatible" label alone does not mean a device will work here.

## Hardware and platform

| Device / platform | Status |
| --- | --- |
| Third-party 2.4 GHz Xbox-style controller and its supplied receiver, USB `20d6:a01a` | USB input and gameplay tested on an Intel Mac setup |
| USB product string `Xbox ONE liquid metal controller` | Identifier reported by the tested receiver; branding is not proof of compatibility |
| Other wired Xbox One / Series GIP devices | Experimental; require their own VID/PID and hardware testing |
| Official Microsoft Xbox Wireless Adapter | Not supported by this implementation |
| Xbox 360 / older XInput protocol, Bluetooth controllers, generic HID gamepads | Not supported by this implementation |
| Apple Silicon | Native compilation intended; hardware and gameplay not verified |

The build targets **macOS 14 or later**. The bridge does not install or provide
the game, and does not change whether the game itself runs on a particular Mac.

## Features

- Left stick movement and right stick camera / mouse movement.
- Remappable buttons, camera inversion, and three sensitivity settings.
- A visible pointer for game menus, accessible from the controller.
- English by default, with **Language → Srpski** available in the app.
- Output only while Sonic Dream Team is the foreground app.
- Releases held inputs when focus changes, the bridge is paused, or USB disconnects.
- Automatically retries the USB connection after disconnecting.

There is no kernel extension, native virtual gamepad, rumble, or analog
character movement. Left stick movement is translated to digital WASD keys.

## Build from source

Install Apple's Command Line Tools if they are not already installed:

```sh
xcode-select --install
```

Install [Homebrew](https://brew.sh/) if needed, then the dependencies:

```sh
brew install libusb pkgconf
git clone https://github.com/filiprrs/sonic-dream-team-controller-macos.git
cd sonic-dream-team-controller-macos
make
make test
```

The output is **`build/SonicDreamTeamController.app`**. The Makefile finds libusb through
`pkg-config`, so it does not assume `/usr/local` or `/opt/homebrew`. It builds for
the current machine's architecture and ad-hoc signs the app. No Developer ID,
paid Apple developer account, or `sudo` is needed to build or run the bridge.

libusb remains a dynamic dependency: keep it installed on the machine that runs
the app. The build output is not a standalone app for redistribution to other
machines. `make test` checks mapping logic and camera deadzones/directions; it
does not connect to hardware, launch the game, or verify Accessibility permission.

## First run

1. Connect the receiver and pair the controller. For the tested hardware, put
   the receiver into pairing mode with its button, then hold the controller's
   HOME button for about one second. Both lights should become steady. Other
   models may have different pairing instructions.
2. Open `build/SonicDreamTeamController.app` in Finder. A **🎮 Sonic** item appears in
   the menu bar; the app has no Dock window.
3. Use **Allow keyboard and mouse control…**, then enable **Sonic Dream Team Controller**
   under **System Settings → Privacy & Security → Accessibility**.
4. Open Sonic Dream Team and check the controller during gameplay. The menu bar
   status shows whether the app is waiting for USB, needs permission, or is ready.

The app is locally ad-hoc signed, not notarized. If macOS presents a launch
confirmation for your locally built copy, review it and use the normal system
approval flow. No security settings need to be disabled.

## Default controls

Use **Button mapping** to customize the controls.

| Controller | Output / behavior |
| --- | --- |
| Left stick | W / A / S / D |
| Right stick | Mouse movement / camera |
| A | Space, jump / homing attack |
| X | Left Shift, boost / dash binding |
| B | E, interaction binding |
| Y | Z, skip binding |
| RT | Left mouse click |
| LT | Right mouse click |
| R3 | Middle mouse click |
| L3 | Tab |
| LB | Control |
| RB | Option |
| Menu | Escape / pause, and toggles the visible menu pointer |
| View | Toggles the visible menu pointer without sending a game key |

LB, RB, L3, and LT are configurable convenience bindings; their gameplay effects
have not been confirmed.

Press View to show or hide the pointer, including when the game opens a menu
after finishing a level. Move it with the right stick and click with RT.

Camera / pointer sensitivity is **shared** between gameplay and menus:
Slow (350), Normal (900, default), or Fast (1600 pixels/second at full deflection).
There is no automatic speed change between the two. Menu pointer recovery was
added after the initial gameplay test and still needs broader in-game testing.

## Troubleshooting

**Receiver connected, but nothing happens:** verify pairing, quit other tools
that might claim the same USB interface, and check the app's Accessibility
status. Test with the game in the foreground. A paired receiver is not proof
that macOS or the game recognizes a native controller.

**Stopped working after rebuilding or moving the app:** quit the bridge, remove
the old Accessibility entry, add the current `.app` from its final location,
enable it, and reopen the app. Replacing an ad-hoc signed executable can
invalidate a previous grant. A permission check from a terminal subprocess
does not reliably prove that the Finder-launched app has permission.

**Mouse pointer disappears in a game menu:** press View to enable the visible
pointer, use the right stick and RT, then press View again when returning to play.
The app cannot automatically detect every in-game menu transition.

**Wrong jump or other action:** check what a real keyboard does in your game
setup, then change **Button mapping**. The default bindings are not verified
across all game versions.

**Different receiver:** inspect its USB vendor/product IDs in System Information
or with `system_profiler SPUSBDataType`. If it uses the same GIP protocol, an
experimental build can select its IDs:

```sh
make clean
make VID=0x1234 PID=0x5678
```

Those numbers are placeholders. Changing IDs only changes device selection; it
does not add protocol support, authentication, or a driver for a different
wireless adapter. Clean first because changing Make variables alone does not
invalidate an existing binary.

## Development and contributions

`src/SonicController.m` contains the USB reader, GIP parser, keyboard/mouse
mapping, pointer overlay, and bilingual menu. `resources/Info.plist` defines the
menu bar app bundle. The source accepts only GIP command `0x20` input reports
with at least 18 bytes, and initializes the receiver with power, LED, and auth
messages. Focus detection checks `com.sega.sdt` and the normalized app name.

Settings and local USB/input counters use macOS preferences for
`io.github.filiprrs.sonic-dream-team-controller-macos`. The app sends no telemetry and
makes no network requests. USB access and input posting happen locally.

For a compatibility report, include the controller model, receiver VID/PID,
Mac architecture, macOS version, pairing behavior, and which actions actually
worked. Avoid publishing USB serial numbers or unrelated system details.

Build validation before contributing:

```sh
make clean
make
make test
```

Hardware testing remains necessary for new devices. The public build uses its
own bundle identifier and preferences; quit older copies of the bridge before
running it so they do not compete for the receiver.

## License and references

[MIT](LICENSE). USB/GIP implementation reference and attribution:
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

- [libusb Homebrew formula](https://formulae.brew.sh/formula/libusb)
- [Homebrew dependency discovery](https://docs.brew.sh/How-to-Build-Software-Outside-Homebrew-with-Homebrew-keg-only-Dependencies)
- [Apple: allow Accessibility apps](https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac)

Independent community project; not affiliated with SEGA, Microsoft, or Apple.
