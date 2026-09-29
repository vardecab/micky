# Micky

A small menu bar utility that shows the live microphone input level in a floating capsule at the bottom center of the screen. The panel stays above other windows and joins every Space. Drag it by its background to reposition it, or use the horizontal and vertical position sliders in Settings. Adjust its size there too. The app remembers dragged positions.

The meter follows the macOS default input device or a microphone selected in Settings. It displays short-term peak level in dBFS. The colored bars use a practical call setup guide: peaks below −30 dBFS are very quiet, −30 to −18 dBFS are low, −18 to −6 dBFS are a useful working range, −6 to −1 dBFS are hot, and −1 dBFS or higher is near digital clipping. dBFS measures headroom to digital full scale, not acoustic loudness at the microphone. Video call apps may apply automatic gain control, so use the colors as a local setup aid and confirm with the call app’s own microphone test.

The menu bar microphone icon opens controls for pausing the meter and opening Settings. Settings lets you choose any available Core Audio input or follow System Default, and includes an opacity slider, a vertical position slider, and a color legend for the speech peak thresholds. At 100% the capsule background is opaque black; lower settings blend the material with more of the desktop behind it. On macOS 26 and later the capsule uses Liquid Glass; earlier supported macOS releases use a translucent material fallback. The microphone glyph has a black tile for contrast.

The Settings speech-level legend uses the bundled Spline Sans Mono font for its dBFS ranges.

The overlay contains only the waveform: it turns fully red when the selected microphone reports itself muted, and uses the normal level colors when the mic is on. The menu bar icon shows the microphone state. Hover over the waveform to reveal the live dBFS value.

## Build and launch

On a Mac with Xcode Command Line Tools installed, run this standalone builder from the Micky folder:

```sh
./build-and-run.sh
```

It builds the Swift package with Swift Package Manager, packages `build/Micky.app`, installs or updates `/Applications/Micky.app`, and launches the installed copy. macOS may ask for administrator approval to update `/Applications`.

The first launch asks for microphone access. The app meters input locally and does not record or save audio. Use the menu bar microphone icon to pause/resume the meter or quit.
