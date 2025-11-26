## 0.7.2

- Added comprehensive Dartdoc comments to improve code documentation and readability.
- Simplified `analysis_options.yaml` by removing unnecessary comments.
- Updated debug logging and error handling for device parsing.
- Bumped version to 0.7.2.

## 0.7.1

- Implemented SIGINT (Ctrl+C) signal handling for graceful shutdown of `fl` and its subprocesses.
- Updated `_cleanup` function to manage the shutdown process and prevent multiple cleanup calls.
- Bumped version to 0.7.1.

## 0.7.0

- Implemented dynamic detection of FVM configuration to use `fvm flutter` or `flutter` accordingly.
- Refactored `FlutterRunner` and `_runFlutterPassthrough` to leverage the new FVM integration.
- Bumped version to 0.7.0.

## 0.6.0

- Implemented `flutter` command to directly pass arguments to the Flutter CLI.
- Updated usage documentation for the new `flutter` command.
- Bumped version to 0.6.0.

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