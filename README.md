# Disc Burner

A macOS application for mastering and burning data Blu-ray, DVD, and CD discs,
creating compressed DMG files from folders, burning existing disc images, and
writing audio CDs from CUE sheets.

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
to package a folder as a read-only, compressed `.dmg` file. For CUE burning in
a local CMake build, install `cdrdao` (which provides `cue2toc`) with Homebrew:

```sh
brew install cdrdao
```

The installer package includes `cdrdao`, `cue2toc`, and their runtime
libraries, so CUE burning does not require Homebrew. A CMake build can also
find `cdrdao` and `cue2toc` on `PATH` as a development fallback. In the CUE
workflow, enter the device identifier in the format accepted by `cdrdao`
(see `cdrdao scanbus`). CUE sheets and their referenced audio files must be
accessible; the converter and recorder determine which audio formats are
supported. In the GUI, use **Scan CUE Recorder** to find recorder devices with
the bundled `cdrdao`. The package includes upstream source archives and license
information for the bundled open-source components under
`/usr/local/share/doc/disc-burner/`.

The drive listing shows both macOS `drutil` information and `cdrdao` device
paths. A `SupportLevel: Unsupported` line from `drutil` does not mean the drive
was not detected; use the corresponding `IOService:` path reported by
`cdrdao scanbus` for CUE burning and CD copying.

Use **Copy CD…** to duplicate an audio or data CD directly from a source drive
to a separate recorder with a blank CD-R/RW. The original and destination
drives must be different; use **Scan CUE Recorder** to find `cdrdao` device
identifiers. DVD and Blu-ray disc copying are not supported by this feature.

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
bundled CUE tools are built for Apple Silicon; macOS system disc utilities are
used for other disc operations.
