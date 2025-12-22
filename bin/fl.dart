import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';
import 'package:watcher/watcher.dart';

String _cyan(String text) => '\x1B[36m$text\x1B[0m';
String _green(String text) => '\x1B[32m$text\x1B[0m';
String _yellow(String text) => '\x1B[33m$text\x1B[0m';
String _red(String text) => '\x1B[31m$text\x1B[0m';
String _gray(String text) => '\x1B[90m$text\x1B[0m';

/// Current CLI version string.
const String _version = '0.15.1';

/// Duration after which unpicked devices are removed from cache.
const Duration _staleDeviceDuration = Duration(days: 30);

final _flutterCommand = _resolveFlutterCommand();

/// Detects whether to run Flutter via FVM or the global installation.
_FlutterCommand _resolveFlutterCommand() {
  var currentDir = Directory.current.absolute;
  while (true) {
    final fvmDir = Directory(path.join(currentDir.path, '.fvm'));
    final configFile = File(path.join(currentDir.path, 'fvm_config.json'));
    final nestedConfig = File(
      path.join(currentDir.path, '.fvm', 'fvm_config.json'),
    );
    if (fvmDir.existsSync() ||
        configFile.existsSync() ||
        nestedConfig.existsSync()) {
      return const _FlutterCommand('fvm', ['flutter']);
    }

    final parent = currentDir.parent;
    if (parent.path == currentDir.path) {
      break;
    }
    currentDir = parent;
  }

  return const _FlutterCommand('flutter', []);
}

class _FlutterCommand {
  final String executable;
  final List<String> prefix;

  /// Builds a Flutter command with a consistent executable and prefix args.
  const _FlutterCommand(this.executable, this.prefix);

  List<String> withArgs(List<String> args) => [...prefix, ...args];
}

/// Formats the Flutter command for display.
String _describeFlutterCommand(List<String> commandArgs) {
  if (commandArgs.isEmpty) return _flutterCommand.executable;
  return '${_flutterCommand.executable} ${commandArgs.join(' ')}';
}

final Directory? _deviceCacheDirectory = _resolveDeviceCacheDirectory();
final File? _deviceCacheFile = _resolveDeviceCacheFile();

Directory? _resolveDeviceCacheDirectory() {
  final basePath = _resolveDeviceCacheBasePath();
  if (basePath == null || basePath.isEmpty) return null;
  final directory = Directory(basePath);
  try {
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    return directory;
  } catch (_) {
    return null;
  }
}

File? _resolveDeviceCacheFile() {
  final directory = _deviceCacheDirectory ?? _resolveDeviceCacheDirectory();
  if (directory == null) return null;
  return File(path.join(directory.path, 'device-cache.json'));
}

String? _resolveDeviceCacheBasePath() {
  final override = Platform.environment['FL_DEVICE_CACHE_DIR'];
  if (override != null && override.isNotEmpty) return override;

  if (Platform.isWindows) {
    final userProfile = Platform.environment['USERPROFILE'];
    if (userProfile != null && userProfile.isNotEmpty) {
      return path.join(userProfile, '.fl');
    }
    return null;
  }

  final xdg = Platform.environment['XDG_CACHE_HOME'];
  if (xdg != null && xdg.isNotEmpty) {
    return path.join(xdg, 'fl');
  }

  final home = Platform.environment['HOME'];
  if (home != null && home.isNotEmpty) {
    return path.join(home, '.cache', 'fl');
  }

  return null;
}

/// Entry point for the CLI.
void main(List<String> arguments) async {
  _ParsedArgs parsed;
  try {
    parsed = _parseArguments(arguments);
  } on _UsageException catch (error) {
    stderr.writeln(_red(error.message));
    stderr.writeln('');
    _printUsage();
    exitCode = 64;
    return;
  }

  if (parsed.showVersion) {
    print('fl version $_version');
    return;
  }

  final verbose = parsed.verbose;
  final command = parsed.command;
  final commandArgs = parsed.commandArgs;

  if (verbose) {
    print(_gray('Debug: Parsed arguments'));
    print(_gray('  showHelp: ${parsed.showHelp}'));
    print(_gray('  showVersion: ${parsed.showVersion}'));
    print(_gray('  verbose: ${parsed.verbose}'));
    print(_gray('  command: ${parsed.command}'));
    print(_gray('  commandArgs: ${parsed.commandArgs}'));
  }

  if (parsed.showHelp && command == null) {
    if (verbose) print(_gray('Debug: Showing fl help (no command)'));
    _printUsage();
    return;
  }

  if (command == null || command.isEmpty) {
    if (!parsed.showHelp) {
      stderr.writeln(_red('No command specified'));
      stderr.writeln('');
    }
    if (verbose) print(_gray('Debug: No command provided'));
    _printUsage();
    exitCode = 64;
    return;
  }

  if (command == 'run') {
    if (verbose) print(_gray('Debug: Executing run command'));
    _RunCommandArgs runArgs;
    try {
      runArgs = _extractRunCommandArgs(commandArgs);
    } on _UsageException catch (error) {
      stderr.writeln(_red(error.message));
      stderr.writeln('');
      _printUsage();
      exitCode = 64;
      return;
    }

    final runner = FlutterRunner(
      forwardedArgs: runArgs.cleanedArgs,
      platformOverride: runArgs.platformOverride,
      verbose: verbose,
      forceDeviceRefresh: runArgs.forceDeviceRefresh,
      autoYes: runArgs.autoYes,
    );
    await runner.run();
    return;
  }

  if (command == 'flutter') {
    if (verbose) print(_gray('Debug: Forwarding to flutter command'));
    await _runFlutterPassthrough(commandArgs, verbose);
    return;
  }

  if (command == 'pub') {
    if (verbose) print(_gray('Debug: Executing pub command'));
    await _handlePubCommand(commandArgs, verbose);
    return;
  }

  if (command == 'help') {
    if (verbose) print(_gray('Debug: Showing help command'));
    _printUsage();
    return;
  }

  if (command == 'device') {
    if (verbose) print(_gray('Debug: Executing device command'));
    await _handleDeviceCommand(commandArgs, verbose);
    return;
  }

  stderr.writeln(_red('Unknown command: $command'));
  stderr.writeln('');
  _printUsage();
  exitCode = 64;
}

/// Routes `fl pub` subcommands to the appropriate handler.
Future<void> _handlePubCommand(List<String> args, bool verbose) async {
  if (args.isEmpty) {
    stderr.writeln(_red('No pub subcommand specified'));
    stderr.writeln('');
    stderr.writeln('Available subcommands:');
    stderr.writeln(
      '  sort [options]    Sort dependencies in pubspec.yaml alphabetically',
    );
    stderr.writeln('');
    stderr.writeln('Sort options:');
    stderr.writeln(
      '  --create-backup   Create a backup file (pubspec.yaml.backup)',
    );
    exitCode = 64;
    return;
  }

  final subcommand = args.first;

  if (subcommand == 'sort') {
    var createBackup = false;
    for (var i = 1; i < args.length; i++) {
      if (args[i] == '--create-backup') {
        createBackup = true;
      } else {
        stderr.writeln(_red('Unknown option: ${args[i]}'));
        stderr.writeln('');
        stderr.writeln('Sort options:');
        stderr.writeln(
          '  --create-backup   Create a backup file (pubspec.yaml.backup)',
        );
        exitCode = 64;
        return;
      }
    }

    await _sortPubspec(verbose, createBackup);
    return;
  }

  stderr.writeln(_red('Unknown pub subcommand: $subcommand'));
  stderr.writeln('');
  stderr.writeln('Available subcommands:');
  stderr.writeln(
    '  sort [options]    Sort dependencies in pubspec.yaml alphabetically',
  );
  exitCode = 64;
}

/// Handles `fl device` subcommands.
Future<void> _handleDeviceCommand(List<String> args, bool verbose) async {
  if (args.isEmpty) {
    stderr.writeln(_red('No device subcommand specified'));
    stderr.writeln('');
    stderr.writeln('Available subcommands:');
    stderr.writeln('  refresh           Refresh the device cache');
    stderr.writeln(
      '  list [options]    List devices (use --force-device-refresh to refresh)',
    );
    stderr.writeln('  rm <device-id>    Remove a device from the cache');
    exitCode = 64;
    return;
  }

  final subcommand = args.first;

  if (subcommand == 'refresh') {
    print(_cyan('Refreshing device cache...'));
    final devices = await _fetchDevices(verbose: verbose);
    if (devices.isNotEmpty) {
      await _saveDeviceCache(devices, verbose: verbose);
      print(_green('✓ Device cache updated with ${devices.length} devices.'));
      for (final device in devices) {
        print('  • ${device.name} (${device.id})');
      }
    } else {
      print(_yellow('No devices found.'));
    }
    return;
  }

  if (subcommand == 'list') {
    var forceRefresh = false;
    for (var i = 1; i < args.length; i++) {
      if (args[i] == '--force-device-refresh') {
        forceRefresh = true;
      }
    }

    if (forceRefresh) {
      print(_cyan('Refreshing device cache...'));
      final devices = await _fetchDevices(verbose: verbose);
      if (devices.isNotEmpty) {
        await _saveDeviceCache(devices, verbose: verbose);
      }
      _printDevices(devices);
      return;
    }

    final cachedDevices = await _loadCachedDevices(verbose: verbose);
    if (cachedDevices != null && cachedDevices.isNotEmpty) {
      _printDevices(cachedDevices);
    } else {
      print(_yellow('No cached devices found.'));
      print(
        _gray(
          'Run "fl device refresh" or "fl device list --force-device-refresh" to update.',
        ),
      );
    }
    return;
  }

  if (subcommand == 'rm') {
    if (args.length < 2) {
      stderr.writeln(_red('No device ID specified'));
      stderr.writeln(_gray('Usage: fl device rm <device-id>'));
      exitCode = 64;
      return;
    }

    final deviceId = args[1];
    final removed = await _removeDeviceFromCache(deviceId, verbose: verbose);
    if (removed) {
      print(_green('✓ Device $deviceId removed from cache.'));
    } else {
      print(_yellow('Device $deviceId not found in cache.'));
    }
    return;
  }

  stderr.writeln(_red('Unknown device subcommand: $subcommand'));
  exitCode = 64;
}

void _printDevices(List<_FlutterDevice> devices) {
  if (devices.isEmpty) {
    print(_yellow('No devices available.'));
    return;
  }
  print(_green('Available devices:'));
  for (final device in devices) {
    print(
      '  • ${device.name} (${device.id}) - ${device.targetPlatform} ${device.sdk ?? ''}',
    );
  }
}

/// Forwards arguments directly to the Flutter executable.
Future<void> _runFlutterPassthrough(List<String> args, bool verbose) async {
  final commandArgs = _flutterCommand.withArgs(args);
  if (verbose) {
    print(_gray('Running: ${_describeFlutterCommand(commandArgs)}'));
  }

  final process = await Process.start(_flutterCommand.executable, commandArgs);

  final stdinSubscription = stdin.listen(
    process.stdin.add,
    onDone: process.stdin.close,
  );

  process.stdout.listen(stdout.add);
  process.stderr.listen(stderr.add);

  final exitCode = await process.exitCode;
  await stdinSubscription.cancel();
  exit(exitCode);
}

/// Sorts `dependencies` and `dev_dependencies` entries in `pubspec.yaml`.
Future<void> _sortPubspec(bool verbose, bool createBackup) async {
  final pubspecFile = File('pubspec.yaml');

  if (!pubspecFile.existsSync()) {
    stderr.writeln(_red('Error: pubspec.yaml not found in current directory'));
    exitCode = 1;
    return;
  }

  try {
    if (verbose) {
      print(_gray('Reading pubspec.yaml...'));
    }

    final content = await pubspecFile.readAsString();
    final lines = content.split('\n');

    final result = <String>[];
    var inDependencies = false;
    var inDevDependencies = false;
    var currentSection = <String>[];
    var sectionIndent = '';
    var trailingEmptyLines = <String>[];

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      if (line.trim() == 'dependencies:') {
        if (currentSection.isNotEmpty) {
          result.addAll(_sortDependencySection(currentSection, sectionIndent));
          currentSection.clear();
        }
        result.addAll(trailingEmptyLines);
        trailingEmptyLines.clear();

        inDependencies = true;
        inDevDependencies = false;
        result.add(line);
        continue;
      }

      if (line.trim() == 'dev_dependencies:') {
        if (currentSection.isNotEmpty) {
          result.addAll(_sortDependencySection(currentSection, sectionIndent));
          currentSection.clear();
        }
        result.addAll(trailingEmptyLines);
        trailingEmptyLines.clear();

        inDevDependencies = true;
        inDependencies = false;
        result.add(line);
        continue;
      }

      if ((inDependencies || inDevDependencies) &&
          line.isNotEmpty &&
          !line.startsWith(' ') &&
          !line.startsWith('\t')) {
        if (currentSection.isNotEmpty) {
          result.addAll(_sortDependencySection(currentSection, sectionIndent));
          currentSection.clear();
        }
        result.addAll(trailingEmptyLines);
        trailingEmptyLines.clear();

        inDependencies = false;
        inDevDependencies = false;
        result.add(line);
        continue;
      }

      if (inDependencies || inDevDependencies) {
        if (line.trim().isNotEmpty) {
          if (trailingEmptyLines.isNotEmpty) {
            currentSection.addAll(trailingEmptyLines);
            trailingEmptyLines.clear();
          }

          if (currentSection.isEmpty && line.startsWith(' ')) {
            final match = RegExp(r'^(\s+)').firstMatch(line);
            if (match != null) {
              sectionIndent = match.group(1)!;
            }
          }
          currentSection.add(line);
        } else {
          trailingEmptyLines.add(line);
        }
      } else {
        result.add(line);
      }
    }

    if (currentSection.isNotEmpty) {
      result.addAll(_sortDependencySection(currentSection, sectionIndent));
    }
    result.addAll(trailingEmptyLines);

    final sortedContent = result.join('\n');

    if (createBackup) {
      final backupFile = File('pubspec.yaml.backup');
      await backupFile.writeAsString(content);

      if (verbose) {
        print(_gray('Created backup: pubspec.yaml.backup'));
      }
    }

    await pubspecFile.writeAsString(sortedContent);

    print(_green('✓ Successfully sorted pubspec.yaml'));
    if (createBackup) {
      print(_gray('  Backup saved to: pubspec.yaml.backup'));
    }
  } catch (e) {
    stderr.writeln(_red('Error sorting pubspec.yaml: $e'));
    exitCode = 1;
  }
}

/// Sorts a dependency section and groups multi-line entries.
List<String> _sortDependencySection(List<String> section, String indent) {
  if (section.isEmpty) return section;

  final dependencies = <_Dependency>[];
  var i = 0;

  while (i < section.length) {
    final line = section[i];

    if (line.trim().isEmpty) {
      i++;
      continue;
    }

    if (line.startsWith(indent) && line.trim().contains(':')) {
      final dependencyLines = <String>[line];
      final currentIndentLength = indent.length;
      var j = i + 1;

      while (j < section.length) {
        final subLine = section[j];
        if (subLine.trim().isEmpty) {
          j++;
          break;
        }

        final subIndentMatch = RegExp(r'^(\s+)').firstMatch(subLine);
        final subIndentLength = subIndentMatch?.group(1)?.length;
        if (subIndentLength != null && subIndentLength > currentIndentLength) {
          dependencyLines.add(subLine);
          j++;
          continue;
        }
        break;
      }

      final nameMatch = RegExp(r'^\s*([^:]+):').firstMatch(line);
      if (nameMatch != null) {
        dependencies.add(
          _Dependency(nameMatch.group(1)!.trim(), dependencyLines),
        );
      }

      i = j;
      continue;
    }

    i++;
  }

  dependencies.sort(
    (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
  );

  final result = <String>[];
  for (final dep in dependencies) {
    result.addAll(dep.lines);
  }

  return result;
}

class _Dependency {
  final String name;
  final List<String> lines;

  /// Represents a dependency block and its source lines.
  _Dependency(this.name, this.lines);
}

const Map<String, String> _platformDirectoryMap = {
  'android': 'Android',
  'ios': 'iOS',
  'windows': 'Windows',
  'linux': 'Linux',
  'macos': 'macOS',
  'web': 'Web',
};

class _RunCommandArgs {
  final List<String> cleanedArgs;
  final String? platformOverride;
  final bool forceDeviceRefresh;
  final bool autoYes;

  const _RunCommandArgs({
    required this.cleanedArgs,
    this.platformOverride,
    this.forceDeviceRefresh = false,
    this.autoYes = false,
  });
}

_RunCommandArgs _extractRunCommandArgs(List<String> args) {
  final cleanedArgs = <String>[];
  String? platformOverride;
  var sawDoubleDash = false;
  var forceDeviceRefresh = false;
  var autoYes = false;

  for (var index = 0; index < args.length; index++) {
    final current = args[index];

    if (current == '--') {
      sawDoubleDash = true;
      cleanedArgs.add(current);
      continue;
    }

    if (!sawDoubleDash && current == '--force-device-refresh') {
      forceDeviceRefresh = true;
      continue;
    }

    if (!sawDoubleDash && (current == '-y' || current == '--yes')) {
      autoYes = true;
      continue;
    }

    if (!sawDoubleDash && current == '--platform') {
      if (platformOverride != null) {
        throw _UsageException('Multiple --platform arguments are not allowed.');
      }
      if (index + 1 >= args.length) {
        throw _UsageException('Expected a platform name after --platform.');
      }
      platformOverride = _normalizePlatformValue(args[++index]);
      continue;
    }

    if (!sawDoubleDash && current.startsWith('--platform=')) {
      if (platformOverride != null) {
        throw _UsageException('Multiple --platform arguments are not allowed.');
      }
      final value = current.substring('--platform='.length);
      platformOverride = _normalizePlatformValue(value);
      continue;
    }

    cleanedArgs.add(current);
  }

  return _RunCommandArgs(
    cleanedArgs: cleanedArgs,
    platformOverride: platformOverride,
    forceDeviceRefresh: forceDeviceRefresh,
    autoYes: autoYes,
  );
}

String _normalizePlatformValue(String rawInput) {
  final normalized = rawInput.trim().toLowerCase();
  if (normalized.isEmpty) {
    throw _UsageException('Expected a platform name after --platform.');
  }
  if (!_platformDirectoryMap.containsKey(normalized)) {
    throw _UsageException(
      'Unknown platform: $rawInput.\n'
      'Supported platforms: ${_platformDirectoryMap.keys.join(', ')}.',
    );
  }
  return normalized;
}

/// Prints CLI usage information.
void _printUsage() {
  print('fl - Enhanced Flutter CLI');
  print('');
  print('Usage: fl [global-options] <command> [command-arguments]');
  print('');
  print('Global options (must come before command):');
  print('  -h, --help        Show this help message');
  print('      --version     Show version information');
  print('  -v, --verbose     Verbose output');
  print('');
  print('Commands:');
  print('  run [flutter args]    Launch Flutter with auto reload/log capture');
  print(
    '      --platform <name>   Restrict device selection to one platform '
    '(android, ios, linux, macos, windows, web)',
  );
  print(
    '      --force-device-refresh   Bypass device cache and fetch fresh devices',
  );
  print('      -y, --yes            Auto-select the first device');
  print('  pub <subcommand>      Pub-related utilities');
  print(
    '  flutter <flutter args>  Pass through any command to the Flutter CLI',
  );
  print('  device <subcommand>   Device management commands');
  print('    refresh           Manually refresh the device cache');
  print(
    '    list              List devices from cache (supports --force-device-refresh)',
  );
  print('    rm <device-id>    Remove a device from the cache');
  print('  help                Show this message');
  print('');
  print('Examples:');
  print('  fl run                          # Run with defaults');
  print('  fl run --help                   # Show Flutter run help');
  print('  fl run --target lib/main_dev.dart   # Run specific target');
  print('  fl run --flavor development --debug   # Run with flavor');
  print(
    '  fl run --platform ios              # Limit selection to iOS devices',
  );
  print('  fl run --force-device-refresh    # Refresh device list');
  print('  fl -v run --target lib/main.dart    # Verbose mode');
  print('  fl pub sort                       # Sort pubspec.yaml dependencies');
  print('  fl device refresh                 # Refresh device cache');
  print('  fl device list                    # List cached devices');
  print('  fl device list --force-device-refresh # Refresh and list devices');
  print('  fl --help                       # Show this message');
  print('  fl --version                    # Show version');
  print('  fl flutter doctor             # Run Flutter CLI commands directly');
  print('');
  print(_cyan('Commands during execution:'));
  print('  r - Hot reload');
  print('  R - Hot restart');
  print('  q - Quit');
  print('  h - Help');
}

class _ParsedArgs {
  /// Indicates whether help output was requested.
  final bool showHelp;

  /// Indicates whether version output was requested.
  final bool showVersion;

  /// Enables verbose logging when true.
  final bool verbose;

  /// The primary command after global options.
  final String? command;

  /// Arguments forwarded to the command.
  final List<String> commandArgs;

  const _ParsedArgs({
    required this.showHelp,
    required this.showVersion,
    required this.verbose,
    required this.command,
    required this.commandArgs,
  });
}

class _UsageException implements Exception {
  final String message;

  const _UsageException(this.message);

  @override
  String toString() => message;
}

/// Parses CLI arguments, keeping global flags before the command intact.
_ParsedArgs _parseArguments(List<String> arguments) {
  var showHelp = false;
  var showVersion = false;
  var verbose = false;
  String? command;
  final commandArgs = <String>[];

  var index = 0;

  while (index < arguments.length) {
    final current = arguments[index];

    if (current == '--') {
      index++;
      break;
    }

    if (current == '--help' || current == '-h') {
      showHelp = true;
      index++;
      continue;
    }

    if (current == '--version') {
      showVersion = true;
      index++;
      continue;
    }

    if (current == '--verbose' || current == '-v') {
      verbose = true;
      index++;
      continue;
    }

    if (current.startsWith('-')) {
      throw _UsageException(
        'Unknown global option: $current\n'
        'Global options must come before the command.\n'
        'Use "fl <command> --help" to see command-specific options.',
      );
    }

    command = current;
    index++;
    break;
  }

  while (index < arguments.length) {
    commandArgs.add(arguments[index]);
    index++;
  }

  if (verbose) {
    stderr.writeln(_gray('Parse phase complete:'));
    stderr.writeln(_gray('  Input args: $arguments'));
    stderr.writeln(_gray('  showHelp: $showHelp'));
    stderr.writeln(_gray('  showVersion: $showVersion'));
    stderr.writeln(_gray('  verbose: $verbose'));
    stderr.writeln(_gray('  command: $command'));
    stderr.writeln(_gray('  commandArgs: $commandArgs'));
  }

  return _ParsedArgs(
    showHelp: showHelp,
    showVersion: showVersion,
    verbose: verbose,
    command: command,
    commandArgs: commandArgs,
  );
}

/// Runs Flutter with enhanced logging, reload handling, and device selection.
class FlutterRunner {
  final List<String> forwardedArgs;
  final bool verbose;
  final String? platformOverride;
  final bool forceDeviceRefresh;
  final bool autoYes;

  Process? _process;
  VmService? _vmService;
  StreamSubscription? _watcherSubscription;
  Timer? _reloadDebounceTimer;
  bool _isReloading = false;
  bool _appStarted = false;
  String? _vmServiceUri;
  StreamSubscription<ProcessSignal>? _sigintSubscription;
  bool _cleanupInProgress = false;

  FlutterRunner({
    List<String>? forwardedArgs,
    this.platformOverride,
    this.verbose = false,
    this.forceDeviceRefresh = false,
    this.autoYes = false,
  }) : forwardedArgs = forwardedArgs ?? const [];

  Future<void> run() async {
    print(_cyan('🚀 Starting Flutter with enhanced features...'));

    final deviceId = await _resolveDeviceId();

    final flutterArgs = ['run'];

    if (deviceId != null) {
      flutterArgs.addAll(['-d', deviceId]);
    }

    flutterArgs.addAll(forwardedArgs);

    final commandArgs = _flutterCommand.withArgs(flutterArgs);
    if (verbose) {
      print(_gray('Running: ${_describeFlutterCommand(commandArgs)}'));
    }

    _process = await Process.start(_flutterCommand.executable, commandArgs);

    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleFlutterOutput);

    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleFlutterOutput);

    _setupKeyboardInput();

    _setupSignalHandler();

    _setupFileWatcher();

    final exitCode = await _process!.exitCode;
    await _cleanup();
    exit(exitCode);
  }

  void _handleFlutterOutput(String line) {
    if (line.isEmpty) return;

    print(line);

    final vmServiceMatch = RegExp(
      r'(?:VM\s+Service|Observatory|Dart\s+VM\s+Service).*?(http://[^\s]+)',
      caseSensitive: false,
    ).firstMatch(line);

    if (vmServiceMatch != null) {
      _vmServiceUri = vmServiceMatch.group(1)!;
      if (verbose) {
        print(_gray('Found VM Service URI: $_vmServiceUri'));
      }
      _connectToVmService(_vmServiceUri!);
    }

    if (line.contains('Flutter run key commands') ||
        line.contains('An Observatory debugger') ||
        line.contains('A Dart VM Service')) {
      if (!_appStarted) {
        _appStarted = true;
        print(_green('✓ App started successfully'));
        print(_cyan('Commands: r=reload, R=restart, q=quit, h=help'));

        if (_vmServiceUri != null && _vmService == null) {
          if (verbose) {
            print(_gray('Attempting VM Service connection (fallback).'));
          }
          _connectToVmService(_vmServiceUri!);
        }
      }
    }

    if (line.contains('Reloaded') || line.contains('reloaded')) {
      print(_green('✓ Hot reload complete'));
    }

    if (line.contains('Restarted') || line.contains('restarted')) {
      print(_green('✓ Hot restart complete'));
    }
  }

  Future<String?> _resolveDeviceId() async {
    if (_hasDeviceIdFlag()) {
      if (verbose) {
        print(
          _gray('Device flag already provided; skipping device selection.'),
        );
      }
      return null;
    }

    final filter = _determinePlatformFilter();

    // Load device records for ranking
    var records = await _loadDeviceRecords(verbose: verbose) ?? {};
    var usingCachedDevices = records.isNotEmpty;

    if (!forceDeviceRefresh && usingCachedDevices) {
      print(_gray('Using cached device list (press "r" to refresh).'));
    }

    if (forceDeviceRefresh || !usingCachedDevices) {
      print(_gray('Fetching device list...'));
      final fetchedDevices = await _fetchDevices(verbose: verbose);
      if (fetchedDevices.isNotEmpty) {
        records = await _mergeDevicesIntoRecords(
          fetchedDevices,
          verbose: verbose,
        );
        await _saveDeviceRecords(records, verbose: verbose);
        usingCachedDevices = false;
      }
    }

    // Filter and rank devices
    var rankedRecords = records.values.toList();
    if (filter != null) {
      rankedRecords =
          rankedRecords.where((r) => filter.matches(r.device)).toList();
    }

    // Sort by pickCount descending (most used first)
    rankedRecords.sort((a, b) => b.pickCount.compareTo(a.pickCount));

    final devicesForPrompt = rankedRecords.map((r) => r.device).toList();

    if (devicesForPrompt.isEmpty) {
      stderr.writeln(_red('No devices available.'));
      stderr.writeln(
        _gray('Run "fl device refresh" to update the device cache.'),
      );
      exit(64);
    }

    // If autoYes is set, pick the first device automatically
    if (autoYes) {
      final selected = devicesForPrompt.first;
      print(
        _gray('Auto-selecting first device: ${selected.name} (${selected.id})'),
      );
      await _incrementDevicePick(selected.id, verbose: verbose);
      return selected.id;
    }

    if (!stdin.hasTerminal) {
      stderr.writeln(
        _red(
          'stdin is not a terminal; specify a device with -d <deviceId> or use -y to auto-select.',
        ),
      );
      exit(64);
    }

    final selection = _DeviceSelectionContext();
    selection.initialize(devicesForPrompt);
    _printDeviceChoicesFromSelection(selection);

    final session = _SelectionSession();
    final selectedId = await _promptDeviceSelection(
      selection,
      filter: filter,
      session: session,
      startedFromCache: usingCachedDevices,
    );
    session.deactivate();

    // Increment pick count for selected device
    if (selectedId != null) {
      await _incrementDevicePick(selectedId, verbose: verbose);
    }

    return selectedId;
  }

  bool _hasDeviceIdFlag() {
    for (final arg in forwardedArgs) {
      if (arg == '-d' || arg == '--device-id') return true;
      if (arg.startsWith('-d') && arg.length > 2) return true;
      if (arg.startsWith('--device-id=')) return true;
    }
    return false;
  }

  Future<void> _refreshDevicesOnce({
    _DirectoryPlatformFilter? filter,
    required _DeviceSelectionContext selection,
    required bool startedFromCache,
    required _SelectionSession session,
  }) async {
    try {
      final devices = await _fetchDevices(verbose: verbose);
      if (devices.isEmpty) {
        print(_yellow('No devices detected on refresh.'));
        return;
      }
      await _saveDeviceCache(devices, verbose: verbose);
      final filtered = _filterDevicesByDirectory(devices, filter);
      final changes = selection.refresh(filtered);
      if (!session.isActive || !changes.hasChanges) {
        if (!startedFromCache) {
          print(_gray('Device list is unchanged.'));
        }
        return;
      }

      print('');
      print(_yellow('Device list updated:'));
      _printDeviceChoicesFromSelection(selection);
    } catch (error) {
      if (verbose) {
        stderr.writeln(_red('Failed to refresh devices: $error'));
      }
    }
  }

  _DirectoryPlatformFilter? _determinePlatformFilter() {
    if (platformOverride != null) {
      final label =
          _platformDirectoryMap[platformOverride!] ?? platformOverride!;
      return _DirectoryPlatformFilter._([platformOverride!], [label]);
    }
    return _determineDirectoryPlatformFilter();
  }

  _DirectoryPlatformFilter? _determineDirectoryPlatformFilter() {
    final segments = <String>[];
    final labels = <String>[];
    for (final entry in _platformDirectoryMap.entries) {
      if (Directory(entry.key).existsSync()) {
        segments.add(entry.key);
        labels.add(entry.value);
      }
    }
    if (segments.isEmpty) return null;
    return _DirectoryPlatformFilter._(segments, labels);
  }

  List<_FlutterDevice> _filterDevicesByDirectory(
    List<_FlutterDevice> devices,
    _DirectoryPlatformFilter? filter,
  ) {
    if (filter == null) return devices;
    final filtered = devices.where(filter.matches).toList();
    if (verbose) {
      if (filtered.isEmpty) {
        print(
          _gray(
            'No devices matched the requested ${filter.describe()} platform(s).',
          ),
        );
      } else {
        print(
          _gray(
            'Filtering to ${filter.describe()} devices (${filtered.length} available).',
          ),
        );
      }
    }
    return filtered;
  }

  void _printDeviceChoicesFromSelection(_DeviceSelectionContext selection) {
    print('');
    print('Connected devices:');
    for (final entry in selection.entries()) {
      final device = entry.value;
      final platform = device.targetPlatform ?? 'unknown';
      final sdk = device.sdk;
      final sdkSuffix = sdk != null && sdk.isNotEmpty ? ' • $sdk' : '';
      print(
        '[${entry.key}]: ${device.name} (${device.id}) • $platform$sdkSuffix',
      );
    }
    print('');
  }

  Future<String?> _promptDeviceSelection(
    _DeviceSelectionContext selection, {
    _DirectoryPlatformFilter? filter,
    required _SelectionSession session,
    required bool startedFromCache,
  }) async {
    final useSingleKey = stdin.hasTerminal;
    final originalLineMode = stdin.lineMode;
    final originalEchoMode = stdin.echoMode;

    if (useSingleKey) {
      stdin.lineMode = false;
      stdin.echoMode = false;
    }

    try {
      while (true) {
        stdout.write('Please choose one (Enter=1, "q"=quit, "r"=refresh): ');

        String? input;
        if (useSingleKey) {
          try {
            final byte = stdin.readByteSync();
            if (byte == -1) continue; // EOF
            final char = String.fromCharCode(byte);
            // Enter key selects first device
            if (char == '\n' || char == '\r') {
              if (selection.containsIndex(1)) {
                print('');
                return selection.deviceForIndex(1)!.id;
              }
              continue;
            }
            input = char;
          } catch (_) {
            continue;
          }
        } else {
          input = stdin.readLineSync();
        }

        if (input == null) return null;
        final trimmed = input.trim();
        // Empty input (Enter in line mode) selects first device
        if (trimmed.isEmpty) {
          if (selection.containsIndex(1)) {
            print('');
            return selection.deviceForIndex(1)!.id;
          }
          continue;
        }

        final lower = trimmed.toLowerCase();
        if (lower == 'q') {
          print(_cyan('\n👋 Quitting...'));
          exit(0);
        }
        if (lower == 'r') {
          print(_cyan('\nRefreshing device list...'));
          await _refreshDevicesOnce(
            filter: filter,
            selection: selection,
            startedFromCache: startedFromCache,
            session: session,
          );
          continue;
        }

        final index = int.tryParse(trimmed);
        if (index != null) {
          if (selection.containsIndex(index)) {
            print('');
            return selection.deviceForIndex(index)!.id;
          }
          if (selection.isMissingIndex(index)) {
            print(
              _red(
                '\nDevice $index is no longer available; please choose another device.',
              ),
            );
            continue;
          }
        }

        final candidate = trimmed.toLowerCase();
        final match = selection.matchByNameOrId(candidate);
        if (match != null) {
          print('');
          return match.id;
        }

        print(
          _red(
            '\nInvalid selection. Enter a device number or its name/ID, or "q" to quit.',
          ),
        );
      }
    } finally {
      if (useSingleKey) {
        stdin.lineMode = originalLineMode;
        stdin.echoMode = originalEchoMode;
      }
    }
  }

  Future<void> _connectToVmService(String uri) async {
    if (_vmService != null) {
      if (verbose) {
        print(_gray('Already connected to VM Service.'));
      }
      return;
    }

    try {
      final wsUri = uri
          .replaceFirst('http://', 'ws://')
          .replaceFirst('https://', 'wss://');

      if (verbose) {
        print(_gray('Connecting to VM Service at $wsUri'));
      }

      _vmService = await vmServiceConnectUri(wsUri);

      print(_green('✓ Connected to VM Service for enhanced logging'));

      await _vmService!.streamListen(EventStreams.kStdout);
      await _vmService!.streamListen(EventStreams.kStderr);
      await _vmService!.streamListen(EventStreams.kLogging);

      _vmService!.onStdoutEvent.listen((event) {
        try {
          final message = utf8.decode(base64Decode(event.bytes!));
          final trimmed = message.trimRight();
          if (trimmed.isNotEmpty) {
            print(trimmed);
          }
        } catch (e) {
          if (verbose) {
            print(_gray('Failed to decode stdout: $e'));
          }
        }
      });

      _vmService!.onStderrEvent.listen((event) {
        try {
          final message = utf8.decode(base64Decode(event.bytes!));
          final trimmed = message.trimRight();
          if (trimmed.isNotEmpty) {
            print(_red(trimmed));
          }
        } catch (e) {
          if (verbose) {
            print(_gray('Failed to decode stderr: $e'));
          }
        }
      });

      _vmService!.onLoggingEvent.listen((event) async {
        final iso = event.isolate?.id;
        final rec = event.logRecord;
        if (iso == null || rec == null) return;

        final name = await _readFullString(rec.loggerName, iso);
        final msg = await _readFullString(rec.message, iso);
        final err = await _readMaybeString(rec.error, iso);
        final st = await _readMaybeString(rec.stackTrace, iso);
        final level = rec.level?.toString() ?? '';

        final prefix =
            name.isNotEmpty ? '[$name]' : (level.isNotEmpty ? '[L$level]' : '');
        final b = StringBuffer('📝 $prefix $msg');
        if (err.isNotEmpty) b.write('  error: $err');
        if (st.isNotEmpty) b.write('\n$st');

        print(_yellow(b.toString()));
      });
    } catch (e) {
      print(_red('Failed to connect to VM Service: $e'));
      if (verbose) {
        print(_gray('Enhanced logging will not be available'));
      }
    }
  }

  Future<String> _readMaybeString(InstanceRef? ref, String isolateId) async {
    if (ref == null) return '';
    final k = ref.kind;
    if (k == InstanceKind.kNull || k == 'Null' || ref is NullValRef) return '';
    final s = await _readFullString(ref, isolateId);
    if (s == 'null') return '';
    return s;
  }

  Future<String> _readFullString(InstanceRef? ref, String isolateId) async {
    if (ref == null) return '';
    try {
      final first = await _vmService!.getObject(isolateId, ref.id!) as Instance;
      final len = first.length ?? first.valueAsString?.length ?? 0;
      final buf = StringBuffer(first.valueAsString ?? '');
      var got = buf.length;
      while (got < len) {
        final chunk =
            await _vmService!.getObject(
                  isolateId,
                  ref.id!,
                  offset: got,
                  count: len - got > 16384 ? 16384 : len - got,
                )
                as Instance;
        final s = chunk.valueAsString ?? '';
        if (s.isEmpty) break;
        buf.write(s);
        got += s.length;
      }
      return buf.toString();
    } catch (_) {
      try {
        final r = await _vmService!.invoke(
          isolateId,
          ref.id!,
          'toString',
          const [],
        );
        if (r is InstanceRef) return await _readFullString(r, isolateId);
      } catch (_) {}
      return '';
    }
  }

  void _setupKeyboardInput() {
    stdin.lineMode = false;
    stdin.echoMode = false;

    stdin.listen((data) {
      final char = String.fromCharCodes(data);

      if (char == 'r') {
        if (!_appStarted) {
          print(_yellow('⏳ Waiting for app to start...'));
          return;
        }
        _hotReload();
        return;
      }

      if (char == 'R') {
        if (!_appStarted) {
          print(_yellow('⏳ Waiting for app to start...'));
          return;
        }
        _hotRestart();
        return;
      }

      if (char == 'q' || char == 'Q') {
        print(_cyan('\n👋 Quitting...'));
        if (_process != null) {
          _process!.stdin.write('q');
        } else {
          _cleanup().then((_) => exit(0));
        }
        return;
      }

      if (char == 'h' || char == 'H') {
        _showHelp();
        return;
      }
    });
  }

  void _setupFileWatcher() {
    final libDir = Directory('lib');
    if (!libDir.existsSync()) {
      print(_yellow('Warning: lib directory not found'));
      return;
    }

    print(_gray('👀 Watching for file changes in lib/...'));

    final watcher = DirectoryWatcher(libDir.path);
    _watcherSubscription = watcher.events.listen((event) {
      if (event.type == ChangeType.MODIFY) {
        final ext = path.extension(event.path);
        if (ext == '.dart') {
          final fileName = path.basename(event.path);
          _scheduleAutoReload(fileName);
        }
      }
    });
  }

  void _scheduleAutoReload(String fileName) {
    if (!_appStarted) return;

    _reloadDebounceTimer?.cancel();
    _reloadDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      if (!_isReloading && _appStarted) {
        print(_cyan('📝 File changed: $fileName'));
        _hotReload();
      }
    });
  }

  Future<void> _hotReload() async {
    if (_isReloading || !_appStarted || _process == null) return;

    _isReloading = true;

    try {
      print(_cyan('🔥 Hot reload...'));
      _process!.stdin.write('r');
      await Future.delayed(const Duration(milliseconds: 1000));
    } catch (e) {
      print(_red('Hot reload failed: $e'));
    } finally {
      _isReloading = false;
    }
  }

  Future<void> _hotRestart() async {
    if (_isReloading || !_appStarted || _process == null) return;

    _isReloading = true;

    try {
      print(_cyan('🔄 Hot restart...'));
      _process!.stdin.write('R');
      await Future.delayed(const Duration(milliseconds: 2000));
    } catch (e) {
      print(_red('Hot restart failed: $e'));
    } finally {
      _isReloading = false;
    }
  }

  void _setupSignalHandler() {
    _sigintSubscription = ProcessSignal.sigint.watch().listen((_) async {
      if (_cleanupInProgress) return;
      print(_cyan('\n👋 Received Ctrl+C; cleaning up...'));
      await _cleanup();
      exit(130);
    });
  }

  void _showHelp() {
    print('');
    print(_cyan('═══════════════════════════════'));
    print(_cyan('  Available Commands'));
    print(_cyan('═══════════════════════════════'));
    print('  ${_cyan('r')} - Hot reload (fast refresh)');
    print('  ${_cyan('R')} - Hot restart (full restart)');
    print('  ${_cyan('q')} - Quit application');
    print('  ${_cyan('h')} - Show this help');
    print(_cyan('═══════════════════════════════'));
    print('');
  }

  Future<void> _cleanup() async {
    if (_cleanupInProgress) return;
    _cleanupInProgress = true;
    await _sigintSubscription?.cancel();
    await _watcherSubscription?.cancel();
    _reloadDebounceTimer?.cancel();
    await _vmService?.dispose();
    _process?.kill();
  }
}

Future<List<_FlutterDevice>> _fetchDevices({bool verbose = false}) async {
  try {
    final commandArgs = _flutterCommand.withArgs(['devices', '--machine']);
    final result = await Process.run(_flutterCommand.executable, commandArgs);
    if (result.exitCode != 0) {
      if (verbose) {
        stderr.writeln(_red('Failed to list devices: ${result.stderr}'));
      }
      return [];
    }

    final output = (result.stdout as String).trim();
    return _parseDevicesFromOutput(output, verbose: verbose);
  } catch (error) {
    if (verbose) {
      stderr.writeln(_red('Failed to list devices: $error'));
    }
    return [];
  }
}

Future<Map<String, _DeviceRecord>?> _loadDeviceRecords({
  bool verbose = false,
}) async {
  final file = _deviceCacheFile;
  if (file == null) return null;
  try {
    if (!await file.exists()) return null;

    final content = await file.readAsString();
    final decoded = json.decode(content);
    if (decoded is! Map<String, dynamic>) return null;

    final devicesData = decoded['devices'];
    if (devicesData is! Map<String, dynamic>) return null;

    final records = <String, _DeviceRecord>{};
    final now = DateTime.now();

    for (final entry in devicesData.entries) {
      if (entry.value is! Map<String, dynamic>) continue;
      final record = _DeviceRecord.fromJson(
        entry.value as Map<String, dynamic>,
      );
      if (record == null) continue;

      // Prune devices not picked for 30 days
      if (record.lastPickedAt != null) {
        final age = now.difference(record.lastPickedAt!);
        if (age > _staleDeviceDuration) {
          if (verbose) {
            print(
              _gray(
                'Removing stale device: ${record.device.name} (not picked for ${age.inDays} days)',
              ),
            );
          }
          continue;
        }
      }

      records[entry.key] = record;
    }

    return records;
  } catch (error) {
    if (verbose) {
      stderr.writeln(_red('Failed to load device cache: $error'));
    }
    return null;
  }
}

Future<void> _saveDeviceRecords(
  Map<String, _DeviceRecord> records, {
  bool verbose = false,
}) async {
  final file = _deviceCacheFile;
  if (file == null) return;

  final devicesJson = <String, dynamic>{};
  for (final entry in records.entries) {
    devicesJson[entry.key] = entry.value.toJson();
  }

  final payload = json.encode({'devices': devicesJson});
  try {
    await file.writeAsString(payload);
  } catch (error) {
    if (verbose) {
      stderr.writeln(_red('Failed to write device cache: $error'));
    }
  }
}

/// Merges fetched devices into existing records, preserving pick counts.
Future<Map<String, _DeviceRecord>> _mergeDevicesIntoRecords(
  List<_FlutterDevice> fetchedDevices, {
  bool verbose = false,
}) async {
  final existing = await _loadDeviceRecords(verbose: verbose) ?? {};
  final now = DateTime.now();

  for (final device in fetchedDevices) {
    if (existing.containsKey(device.id)) {
      // Update device info but preserve pick count and lastPickedAt
      final old = existing[device.id]!;
      existing[device.id] = _DeviceRecord(
        device: device,
        pickCount: old.pickCount,
        lastPickedAt: old.lastPickedAt,
        lastSeenAt: now,
      );
    } else {
      // New device
      existing[device.id] = _DeviceRecord(
        device: device,
        pickCount: 0,
        lastPickedAt: null,
        lastSeenAt: now,
      );
    }
  }

  return existing;
}

/// Increments the pick count for a device and saves the cache.
Future<void> _incrementDevicePick(
  String deviceId, {
  bool verbose = false,
}) async {
  final records = await _loadDeviceRecords(verbose: verbose) ?? {};
  final now = DateTime.now();

  if (records.containsKey(deviceId)) {
    final old = records[deviceId]!;
    records[deviceId] = _DeviceRecord(
      device: old.device,
      pickCount: old.pickCount + 1,
      lastPickedAt: now,
      lastSeenAt: old.lastSeenAt,
    );
    await _saveDeviceRecords(records, verbose: verbose);
  }
}

/// Removes a device from the cache.
Future<bool> _removeDeviceFromCache(
  String deviceId, {
  bool verbose = false,
}) async {
  final records = await _loadDeviceRecords(verbose: verbose) ?? {};
  if (records.containsKey(deviceId)) {
    records.remove(deviceId);
    await _saveDeviceRecords(records, verbose: verbose);
    return true;
  }
  return false;
}

/// Legacy wrapper for compatibility - returns list of devices from records.
Future<List<_FlutterDevice>?> _loadCachedDevices({bool verbose = false}) async {
  final records = await _loadDeviceRecords(verbose: verbose);
  if (records == null || records.isEmpty) return null;
  return records.values.map((r) => r.device).toList();
}

/// Legacy wrapper for compatibility - saves devices as records.
Future<void> _saveDeviceCache(
  List<_FlutterDevice> devices, {
  bool verbose = false,
}) async {
  final records = await _mergeDevicesIntoRecords(devices, verbose: verbose);
  await _saveDeviceRecords(records, verbose: verbose);
}

List<_FlutterDevice> _parseDevicesFromOutput(
  String output, {
  bool verbose = false,
}) {
  if (output.isEmpty) return <_FlutterDevice>[];

  try {
    final decoded = json.decode(output);
    return _extractDevices(decoded);
  } catch (_) {
    final devices = <_FlutterDevice>[];
    for (final line in const LineSplitter().convert(output)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final decoded = json.decode(trimmed);
        devices.addAll(_extractDevices(decoded));
      } catch (_) {
        if (verbose) {
          stderr.writeln(_red('Skipping malformed device entry: $trimmed'));
        }
      }
    }
    return devices;
  }
}

List<_FlutterDevice> _extractDevices(dynamic decoded) {
  final devices = <_FlutterDevice>[];

  void addFromMap(Map<String, dynamic> deviceJson) {
    final id = deviceJson['id']?.toString();
    final name = deviceJson['name']?.toString();
    if (id == null || name == null) return;
    final targetPlatform = deviceJson['targetPlatform']?.toString();
    final sdk = deviceJson['sdk']?.toString();
    devices.add(
      _FlutterDevice(
        id: id,
        name: name,
        targetPlatform: targetPlatform,
        sdk: sdk,
      ),
    );
  }

  if (decoded is List) {
    for (final entry in decoded) {
      if (entry is Map<String, dynamic>) {
        addFromMap(entry);
      }
    }
    return devices;
  }

  if (decoded is Map<String, dynamic>) {
    if (decoded['devices'] is List) {
      for (final entry in decoded['devices']) {
        if (entry is Map<String, dynamic>) {
          addFromMap(entry);
        }
      }
      return devices;
    }

    if (decoded['device'] is Map<String, dynamic>) {
      addFromMap(decoded['device'] as Map<String, dynamic>);
      return devices;
    }

    addFromMap(decoded);
  }

  return devices;
}

class _SelectionSession {
  bool _active = true;

  bool get isActive => _active;

  void deactivate() {
    _active = false;
  }
}

class _DeviceSelectionChanges {
  final List<int> removedIndexes;
  final List<_FlutterDevice> addedDevices;

  const _DeviceSelectionChanges({
    required this.removedIndexes,
    required this.addedDevices,
  });

  bool get hasChanges => removedIndexes.isNotEmpty || addedDevices.isNotEmpty;
}

class _DeviceSelectionContext {
  final LinkedHashMap<int, _FlutterDevice> _slots = LinkedHashMap();
  final Map<String, int> _indexById = {};
  final Set<int> _missingIndexes = <int>{};
  int _nextIndex = 1;

  void initialize(List<_FlutterDevice> devices) {
    _slots.clear();
    _indexById.clear();
    _missingIndexes.clear();
    _nextIndex = 1;
    for (final device in devices) {
      _slots[_nextIndex] = device;
      _indexById[device.id] = _nextIndex;
      _nextIndex++;
    }
  }

  Iterable<MapEntry<int, _FlutterDevice>> entries() => _slots.entries;

  bool containsIndex(int index) => _slots.containsKey(index);

  _FlutterDevice? deviceForIndex(int index) => _slots[index];

  bool isMissingIndex(int index) => _missingIndexes.contains(index);

  _FlutterDevice? matchByNameOrId(String candidate) {
    for (final device in _slots.values) {
      if (device.id.toLowerCase() == candidate ||
          device.name.toLowerCase() == candidate) {
        return device;
      }
    }
    return null;
  }

  _DeviceSelectionChanges refresh(List<_FlutterDevice> newDevices) {
    final removed = <int>[];
    final added = <_FlutterDevice>[];
    final newIds = <String>{};
    for (final device in newDevices) {
      newIds.add(device.id);
    }

    final existingIds = _indexById.keys.toSet();
    final removedIds = existingIds.difference(newIds);
    for (final id in removedIds) {
      final index = _indexById.remove(id)!;
      _slots.remove(index);
      _missingIndexes.add(index);
      removed.add(index);
    }

    for (final device in newDevices) {
      final existingIndex = _indexById[device.id];
      if (existingIndex != null) {
        _slots[existingIndex] = device;
      } else {
        _slots[_nextIndex] = device;
        _indexById[device.id] = _nextIndex;
        added.add(device);
        _nextIndex++;
      }
    }

    return _DeviceSelectionChanges(
      removedIndexes: removed,
      addedDevices: added,
    );
  }
}

class _DirectoryPlatformFilter {
  final List<String> segments;
  final List<String> labels;

  const _DirectoryPlatformFilter._(this.segments, this.labels);

  bool matches(_FlutterDevice device) {
    final target = device.targetPlatform?.toLowerCase() ?? '';
    final sdk = device.sdk?.toLowerCase() ?? '';
    for (final segment in segments) {
      if (target.contains(segment) || sdk.contains(segment)) {
        return true;
      }
    }
    return false;
  }

  String describe() {
    if (labels.isEmpty) return 'detected platforms';
    if (labels.length == 1) return labels.first;
    if (labels.length == 2) {
      return '${labels.first} and ${labels.last}';
    }
    final allExceptLast = labels.sublist(0, labels.length - 1).join(', ');
    return '$allExceptLast, and ${labels.last}';
  }
}

class _FlutterDevice {
  final String id;
  final String name;
  final String? targetPlatform;
  final String? sdk;

  const _FlutterDevice({
    required this.id,
    required this.name,
    this.targetPlatform,
    this.sdk,
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'targetPlatform': targetPlatform,
      'sdk': sdk,
    };
  }
}

/// Tracks device usage stats for ranking and staleness checks.
class _DeviceRecord {
  final _FlutterDevice device;
  final int pickCount;
  final DateTime? lastPickedAt;
  final DateTime? lastSeenAt;

  const _DeviceRecord({
    required this.device,
    required this.pickCount,
    this.lastPickedAt,
    this.lastSeenAt,
  });

  static _DeviceRecord? fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString();
    final name = json['name']?.toString();
    if (id == null || name == null) return null;

    final device = _FlutterDevice(
      id: id,
      name: name,
      targetPlatform: json['targetPlatform']?.toString(),
      sdk: json['sdk']?.toString(),
    );

    return _DeviceRecord(
      device: device,
      pickCount: (json['pickCount'] as num?)?.toInt() ?? 0,
      lastPickedAt:
          json['lastPickedAt'] != null
              ? DateTime.tryParse(json['lastPickedAt'].toString())
              : null,
      lastSeenAt:
          json['lastSeenAt'] != null
              ? DateTime.tryParse(json['lastSeenAt'].toString())
              : null,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': device.id,
      'name': device.name,
      'targetPlatform': device.targetPlatform,
      'sdk': device.sdk,
      'pickCount': pickCount,
      'lastPickedAt': lastPickedAt?.toIso8601String(),
      'lastSeenAt': lastSeenAt?.toIso8601String(),
    };
  }
}
