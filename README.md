# Disc Burner

A macOS terminal application for mastering and burning data Blu-ray, DVD, and
CD discs, creating compressed DMG files from folders, burning existing disc
images, and writing audio CDs from CUE sheets.

## Build and run

Open the project in CLion, or build from the project directory:

```sh
cmake -S . -B build
cmake --build build
./build/disc-burner
```

The app uses macOS `hdiutil` to create and burn disc images and `drutil` for
drive listing, status, and eject controls. Choose **Create a compressed DMG**
to package a folder as a read-only, compressed `.dmg` file. For CUE-based audio
CDs, install `cdrdao` (which provides `cue2toc`) with Homebrew:

```sh
brew install cdrdao
```

In the CUE workflow, enter the device identifier in the format accepted by
`cdrdao` (see `cdrdao scanbus`). CUE sheets and their referenced audio files
must be accessible; the converter and recorder determine which audio formats
are supported.

Burning requires a compatible external or internal recorder and blank media.
Blu-ray image creation uses UDF 1.50; DVD uses UDF 1.02 plus ISO/Joliet, and CD
data discs use ISO/Joliet. The app asks for explicit confirmation before
writing media and does not overwrite an existing image file.
