## 0.5.0

- Implemented automatic device selection and prompting when running `flutter run`.
- Reverted `Process.start` command in `FlutterRunner` from `fvm flutter` to `flutter`.
- Bumped version to 0.5.0.

## 0.4.0

- Added `--version` flag to display the current version of the CLI.
- Updated installation instructions in `README.md`.
- Updated `Process.start('flutter', flutterArgs)` to `Process.start('fvm flutter', flutterArgs)` for better FVM support.
- Bumped version to 0.4.0.

## 0.3.0

- Added `pub sort` subcommand to sort dependencies in `pubspec.yaml` alphabetically.
- Bumped version to 0.3.0.

## 0.2.0

- Refactored argument parsing to handle global options before commands.
- Improved the `_printUsage` function for better help output.
- Removed `package:args/args.dart` dependency.

## 0.1.0

- Initial version.