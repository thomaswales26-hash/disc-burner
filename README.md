# Disc Burner

A macOS application for mastering and burning data Blu-ray, DVD, and CD discs,
creating compressed DMG files from folders, burning existing disc images, and
copying CDs between drives.

## Build and run

Open the project in CLion, or build from the project directory:

```sh
cmake -S . -B build
cmake --build build
open "build/Disc Burner.app"
```

The build also includes the command-line version at `build/disc-burner`.

The app uses macOS `hdiutil` to create and burn disc images and `drutil` for
drive listing, status, and eject controls. Choose **Create a compressed DMG**
to package a folder as a read-only, compressed `.dmg` file. CD copying and
device scanning use `cdrdao`; install it for local builds with Homebrew:

```sh
brew install cdrdao
```

The installer package includes `cdrdao` and its runtime libraries. A CMake
build can also find `cdrdao` on `PATH` as a development fallback. Use **Scan CD
Recorder** to find recorder devices. The package includes upstream source
archives and license information for bundled open-source components under
`/usr/local/share/doc/disc-burner/`.

The drive listing shows both macOS `drutil` information and `cdrdao` device
paths. A `SupportLevel: Unsupported` line from `drutil` does not mean the drive
was not detected; use the corresponding `IOService:` path reported by
`cdrdao scanbus` for CD copying.

Use **Copy CD…** to duplicate an audio or data CD directly from a source drive
to a separate recorder with a blank CD-R/RW. The original and destination
drives must be different; use **Scan CD Recorder** to find `cdrdao` device
identifiers. The app streams copy output to the Activity log and displays a
live progress bar (determinate when the drive reports a percentage). DVD and
Blu-ray disc copying are not supported by this feature.

Use **Copy CD to Documents…** to read an audio or data CD into a `.toc` and
`.bin` pair, with the save dialog initially opened to Documents. Select the
source drive and wait for the read to finish; the Activity panel shows output
and progress when the drive reports it.

Burning requires a compatible external or internal recorder and blank media.
Blu-ray image creation uses UDF 1.50; DVD uses UDF 1.02 plus ISO/Joliet, and CD
data discs use ISO/Joliet. The app asks for explicit confirmation before
writing media and does not overwrite an existing image file.

## Build the installer package

On Apple Silicon, install the packaging prerequisite and run:

```sh
brew install cdrdao
bash scripts/build-package.sh
```

The installer, including `Disc Burner.app`, is written to `dist/`. The app and
bundled recorder tool are built for Apple Silicon; macOS system disc utilities
are used for other disc operations.
