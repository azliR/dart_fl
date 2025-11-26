# fl

`fl` is a lightweight companion for `flutter run` that adds auto hot-reload and
brings `dart:developer` logs into your terminal without changing your workflow.

## Features

- Watches `lib/` and triggers hot reload automatically when `.dart` files change.
- Streams `dart:developer` log output alongside `print` and native logs.
- Mirrors `flutter run` options by forwarding every argument after `fl run`.
- Keeps the familiar `r`, `R`, and `q` key bindings from the stock Flutter tool.

## Installation

Clone this repo:

```sh
git clone https://github.com/azliR/dart_fl.git
```

Install the package:

```sh
dart pub global activate --source path .
```

Make sure `$HOME/.pub-cache/bin` (or the equivalent on your platform) is on
your `PATH` so the `fl` executable is available everywhere.

## Usage

```sh
# Show the CLI help
fl

# Run your app with all additional options passed through to flutter run
fl run --flavor staging -d emulator-5554

# Inspect the underlying flutter help
fl run --help
```

During execution you can use:

- `r` for hot reload
- `R` for hot restart
- `q` to quit
- `h` to show the in-app command list

## Troubleshooting

- Ensure the Flutter SDK is available in your `PATH`; `fl` shells out to the
  `flutter` executable.
- Auto reload only watches the `lib/` directory. If your project keeps code
  elsewhere, add symbolic links under `lib/` or trigger reload manually with `r`.
