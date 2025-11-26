import 'dart:async';
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

// Added version constant
const String _version = '0.4.0';

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

  // Handle --version flag
  if (parsed.showVersion) {
    print('fl version $_version');
    return;
  }

  final verbose = parsed.verbose;
  final command = parsed.command;
  final commandArgs = parsed.commandArgs;

  // Debug logging
  if (verbose) {
    print(_gray('Debug: Parsed arguments'));
    print(_gray('  showHelp: ${parsed.showHelp}'));
    print(_gray('  showVersion: ${parsed.showVersion}')); // Updated
    print(_gray('  verbose: ${parsed.verbose}'));
    print(_gray('  command: ${parsed.command}'));
    print(_gray('  commandArgs: ${parsed.commandArgs}'));
  }

  // Only show fl help if:
  // 1. User explicitly requested help with no command (fl --help)
  // 2. No command was provided at all (fl)
  if (parsed.showHelp && command == null) {
    if (verbose) print(_gray('Debug: Showing fl help (no command)'));
    _printUsage();
    return;
  }

  if (command == null || command.isEmpty) {
    // If no command but --help was set, we already handled it above
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
    final runner = FlutterRunner(forwardedArgs: commandArgs, verbose: verbose);
    await runner.run();
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

  stderr.writeln(_red('Unknown command: $command'));
  stderr.writeln('');
  _printUsage();
  exitCode = 64;
}

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
    // Parse sort-specific options
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

      // Check if we're entering dependencies section
      if (line.trim() == 'dependencies:') {
        // Flush any current section
        if (currentSection.isNotEmpty) {
          result.addAll(_sortDependencySection(currentSection, sectionIndent));
          currentSection.clear();
        }
        // Add any trailing empty lines that were collected
        result.addAll(trailingEmptyLines);
        trailingEmptyLines.clear();

        inDependencies = true;
        inDevDependencies = false;
        result.add(line);
        continue;
      }

      // Check if we're entering dev_dependencies section
      if (line.trim() == 'dev_dependencies:') {
        // Flush any current section
        if (currentSection.isNotEmpty) {
          result.addAll(_sortDependencySection(currentSection, sectionIndent));
          currentSection.clear();
        }
        // Add any trailing empty lines that were collected
        result.addAll(trailingEmptyLines);
        trailingEmptyLines.clear();

        inDevDependencies = true;
        inDependencies = false;
        result.add(line);
        continue;
      }

      // Check if we're leaving a dependencies section (new top-level key)
      if ((inDependencies || inDevDependencies) &&
          line.isNotEmpty &&
          !line.startsWith(' ') &&
          !line.startsWith('\t')) {
        // Flush current section
        if (currentSection.isNotEmpty) {
          result.addAll(_sortDependencySection(currentSection, sectionIndent));
          currentSection.clear();
        }
        // Add any trailing empty lines that were collected
        result.addAll(trailingEmptyLines);
        trailingEmptyLines.clear();

        inDependencies = false;
        inDevDependencies = false;
        result.add(line);
        continue;
      }

      // Collect lines within dependencies sections
      if (inDependencies || inDevDependencies) {
        if (line.trim().isNotEmpty) {
          // If we have trailing empty lines, add them before this line
          if (trailingEmptyLines.isNotEmpty) {
            currentSection.addAll(trailingEmptyLines);
            trailingEmptyLines.clear();
          }

          // Detect indent on first dependency
          if (currentSection.isEmpty && line.startsWith(' ')) {
            final match = RegExp(r'^(\s+)').firstMatch(line);
            if (match != null) {
              sectionIndent = match.group(1)!;
            }
          }
          currentSection.add(line);
        } else {
          // Empty line within section - store it temporarily
          trailingEmptyLines.add(line);
        }
      } else {
        // Outside dependencies sections, just add the line
        result.add(line);
      }
    }

    // Flush any remaining section
    if (currentSection.isNotEmpty) {
      result.addAll(_sortDependencySection(currentSection, sectionIndent));
    }
    // Add any final trailing empty lines
    result.addAll(trailingEmptyLines);

    final sortedContent = result.join('\n');

    // Create backup if requested
    if (createBackup) {
      final backupFile = File('pubspec.yaml.backup');
      await backupFile.writeAsString(content);

      if (verbose) {
        print(_gray('Created backup: pubspec.yaml.backup'));
      }
    }

    // Write sorted content
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

List<String> _sortDependencySection(List<String> section, String indent) {
  if (section.isEmpty) return section;

  // Group multi-line dependencies
  final dependencies = <_Dependency>[];
  var i = 0;

  while (i < section.length) {
    final line = section[i];

    if (line.trim().isEmpty) {
      i++;
      continue;
    }

    // Check if this is a dependency line (starts with indent and package name)
    if (line.startsWith(indent) && line.trim().contains(':')) {
      final packageLine = line;
      final dependencyLines = [packageLine];

      // Check if this is a multi-line dependency (has sub-properties)
      if (i + 1 < section.length) {
        final nextLine = section[i + 1];
        final currentIndentLength = indent.length;

        // If next line has more indent, it's a sub-property
        if (nextLine.isNotEmpty && nextLine.startsWith(' ')) {
          final nextIndentMatch = RegExp(r'^(\s+)').firstMatch(nextLine);
          if (nextIndentMatch != null) {
            final nextIndentLength = nextIndentMatch.group(1)!.length;

            if (nextIndentLength > currentIndentLength) {
              // This is a multi-line dependency, collect all sub-lines
              i++;
              while (i < section.length) {
                final subLine = section[i];
                if (subLine.trim().isEmpty) {
                  i++;
                  break;
                }

                final subIndentMatch = RegExp(r'^(\s+)').firstMatch(subLine);
                if (subIndentMatch != null) {
                  final subIndentLength = subIndentMatch.group(1)!.length;
                  if (subIndentLength > currentIndentLength) {
                    dependencyLines.add(subLine);
                    i++;
                  } else {
                    break;
                  }
                } else {
                  break;
                }
              }
              i--; // Adjust because we'll increment at the end of the outer loop
            }
          }
        }
      }

      // Extract package name for sorting
      final nameMatch = RegExp(r'^\s*([^:]+):').firstMatch(packageLine);
      if (nameMatch != null) {
        final name = nameMatch.group(1)!.trim();
        dependencies.add(_Dependency(name, dependencyLines));
      }

      i++;
    } else {
      i++;
    }
  }

  // Sort dependencies by name (case-insensitive)
  dependencies.sort(
    (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
  );

  // Reconstruct the section
  final result = <String>[];
  for (final dep in dependencies) {
    result.addAll(dep.lines);
  }

  return result;
}

class _Dependency {
  final String name;
  final List<String> lines;

  _Dependency(this.name, this.lines);
}

void _printUsage() {
  print('fl - Enhanced Flutter CLI');
  print('');
  print('Usage: fl [global-options] <command> [command-arguments]');
  print('');
  print('Global options (must come before command):');
  print('  -h, --help        Show this help message');
  print('      --version     Show version information'); // Added
  print('  -v, --verbose     Verbose output');
  print('');
  print('Commands:');
  print('  run [flutter args]    Launch Flutter with auto reload/log capture');
  print('  pub <subcommand>      Pub-related utilities');
  print(
    '    sort              Sort dependencies in pubspec.yaml alphabetically',
  );
  print('  help                Show this message');
  print('');
  print('Examples:');
  print('  fl run                          # Run with defaults');
  print('  fl run --help                   # Show Flutter run help');
  print('  fl run --target lib/main_dev.dart   # Run specific target');
  print('  fl run --flavor development --debug   # Run with flavor');
  print('  fl -v run --target lib/main.dart    # Verbose mode');
  print('  fl pub sort                       # Sort pubspec.yaml dependencies');
  print('  fl --help                       # Show this message');
  print('  fl --version                    # Show version'); // Added example
  print('');
  print(_cyan('Commands during execution:'));
  print('  r - Hot reload');
  print('  R - Hot restart');
  print('  q - Quit');
  print('  h - Help');
}

class _ParsedArgs {
  final bool showHelp;
  final bool showVersion; // Added
  final bool verbose;
  final String? command;
  final List<String> commandArgs;

  const _ParsedArgs({
    required this.showHelp,
    required this.showVersion, // Added
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

/// Parse arguments: global flags ONLY before command, everything after command passes through
_ParsedArgs _parseArguments(List<String> arguments) {
  var showHelp = false;
  var showVersion = false; // Added
  var verbose = false;
  String? command;
  final commandArgs = <String>[];

  var index = 0;

  // Phase 1: Parse global options until we hit a non-flag argument (the command)
  while (index < arguments.length) {
    final current = arguments[index];

    // Check for -- separator (everything after is for the command)
    if (current == '--') {
      index++;
      break;
    }

    // Check for global help flag
    if (current == '--help' || current == '-h') {
      showHelp = true;
      index++;
      continue;
    }

    // Check for global version flag
    if (current == '--version') {
      showVersion = true;
      index++;
      continue;
    }

    // Check for global verbose flag
    if (current == '--verbose' || current == '-v') {
      verbose = true;
      index++;
      continue;
    }

    // If it starts with dash but isn't recognized, it's an error
    // (only if we haven't found a command yet)
    if (current.startsWith('-')) {
      throw _UsageException(
        'Unknown global option: $current\n'
        'Global options must come before the command.\n'
        'Use "fl <command> --help" to see command-specific options.',
      );
    }

    // This must be the command - stop parsing global options
    command = current;
    index++;
    break;
  }

  // Phase 2: Everything remaining goes to the command (no parsing)
  while (index < arguments.length) {
    commandArgs.add(arguments[index]);
    index++;
  }

  // Debug output if verbose was set
  if (verbose) {
    stderr.writeln(_gray('Parse phase complete:'));
    stderr.writeln(_gray('  Input args: $arguments'));
    stderr.writeln(_gray('  showHelp: $showHelp'));
    stderr.writeln(_gray('  showVersion: $showVersion')); // Added
    stderr.writeln(_gray('  verbose: $verbose'));
    stderr.writeln(_gray('  command: $command'));
    stderr.writeln(_gray('  commandArgs: $commandArgs'));
  }

  return _ParsedArgs(
    showHelp: showHelp,
    showVersion: showVersion, // Added
    verbose: verbose,
    command: command,
    commandArgs: commandArgs,
  );
}

class FlutterRunner {
  final List<String> forwardedArgs;
  final bool verbose;

  Process? _process;
  VmService? _vmService;
  StreamSubscription? _watcherSubscription;
  Timer? _reloadDebounceTimer;
  bool _isReloading = false;
  bool _appStarted = false;
  String? _vmServiceUri;

  FlutterRunner({List<String>? forwardedArgs, this.verbose = false})
    : forwardedArgs = forwardedArgs ?? const [];

  Future<void> run() async {
    print(_cyan('🚀 Starting Flutter with enhanced features...'));

    // Build flutter command
    final flutterArgs = ['run', ...forwardedArgs];

    if (verbose) {
      print(_gray('Running: flutter ${flutterArgs.join(' ')}'));
    }

    _process = await Process.start('fvm flutter', flutterArgs);

    // Handle stdout
    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleFlutterOutput);

    // Handle stderr
    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleFlutterOutput);

    // Setup keyboard input
    _setupKeyboardInput();

    // Setup file watcher
    _setupFileWatcher();

    // Wait for process to exit
    final exitCode = await _process!.exitCode;
    await _cleanup();
    exit(exitCode);
  }

  void _handleFlutterOutput(String line) {
    if (line.isEmpty) return;

    // Print the line
    print(line);

    // Check for VM Service URI
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

    // Check if app started
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

    // Check for hot reload/restart confirmations
    if (line.contains('Reloaded') || line.contains('reloaded')) {
      print(_green('✓ Hot reload complete'));
    }

    if (line.contains('Restarted') || line.contains('restarted')) {
      print(_green('✓ Hot restart complete'));
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
        _cleanup();
        exit(0);
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
    await _watcherSubscription?.cancel();
    _reloadDebounceTimer?.cancel();
    await _vmService?.dispose();
    _process?.kill();
  }
}
