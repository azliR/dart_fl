import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as path;
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';
import 'package:watcher/watcher.dart';

String _cyan(String text) => '\x1B[36m$text\x1B[0m';
String _green(String text) => '\x1B[32m$text\x1B[0m';
String _yellow(String text) => '\x1B[33m$text\x1B[0m';
String _red(String text) => '\x1B[31m$text\x1B[0m';
String _gray(String text) => '\x1B[90m$text\x1B[0m';

void main(List<String> arguments) async {
  final parser =
      ArgParser()
        ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help')
        ..addFlag(
          'verbose',
          abbr: 'v',
          negatable: false,
          help: 'Verbose output',
        );

  _ParsedArgs parsed;
  try {
    parsed = _parseArguments(arguments);
  } on _UsageException catch (error) {
    stderr.writeln(_red(error.message));
    stderr.writeln('');
    _printUsage(parser);
    exitCode = 64;
    return;
  }

  final verbose = parsed.verbose;
  final rest = parsed.rest;

  if (parsed.showHelp || rest.isEmpty) {
    _printUsage(parser);
    return;
  }

  final command = rest.first;

  if (command == 'run') {
    final runArgs = rest.skip(1).toList();
    final runner = FlutterRunner(forwardedArgs: runArgs, verbose: verbose);
    await runner.run();
    return;
  }

  if (command == 'help') {
    _printUsage(parser);
    return;
  }

  stderr.writeln(_red('Unknown command: $command'));
  stderr.writeln('');
  _printUsage(parser);
  exitCode = 64;
}

void _printUsage(ArgParser parser) {
  print('fl - Enhanced Flutter CLI');
  print('');
  print('Usage: fl [options] <command> [arguments]');
  print('');
  print('Global options:');
  print(parser.usage);
  print('');
  print('Commands:');
  print('  run [flutter args]   Launch Flutter with auto reload/log capture');
  print('  help                 Show this message');
  print('');
  print('Examples:');
  print('  fl run');
  print('  fl run --flavor staging');
  print('  fl run --help');
  print('');
  print(_cyan('Commands during execution:'));
  print('  r - Hot reload');
  print('  R - Hot restart');
  print('  q - Quit');
}

class _ParsedArgs {
  final bool showHelp;
  final bool verbose;
  final List<String> rest;

  const _ParsedArgs({
    required this.showHelp,
    required this.verbose,
    required this.rest,
  });
}

class _UsageException implements Exception {
  final String message;

  const _UsageException(this.message);

  @override
  String toString() => message;
}

_ParsedArgs _parseArguments(List<String> arguments) {
  var showHelp = false;
  var verbose = false;
  final rest = <String>[];

  var index = 0;
  while (index < arguments.length) {
    final current = arguments[index];

    if (current == '--') {
      rest.addAll(arguments.sublist(index + 1));
      break;
    }

    if (current == '--help' || current == '-h') {
      showHelp = true;
      index++;
      continue;
    }

    if (current == '--verbose' || current == '-v') {
      verbose = true;
      index++;
      continue;
    }

    if (current.startsWith('-')) {
      throw _UsageException('Unknown option: $current');
    }

    rest.addAll(arguments.sublist(index));
    break;
  }

  return _ParsedArgs(showHelp: showHelp, verbose: verbose, rest: rest);
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

    // Start Flutter process WITHOUT machine mode
    final flutterArgs = ['run', ...forwardedArgs];

    _process = await Process.start('flutter', flutterArgs);

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

    // Check for VM Service URI - More robust regex
    // This pattern looks for lines containing "VM Service", "Observatory", or "Dart VM Service"
    // followed by a URL starting with http://
    final vmServiceMatch = RegExp(
      r'(?:VM\s+Service|Observatory|Dart\s+VM\s+Service).*?(http://[^\s]+)',
      caseSensitive:
          false, // Make the search case-insensitive for "VM Service" etc.
    ).firstMatch(line);

    if (vmServiceMatch != null) {
      _vmServiceUri =
          vmServiceMatch.group(
            1,
          )!; // Use ! as group(1) is guaranteed by the regex pattern if match exists
      if (verbose) {
        print(_gray('Found VM Service URI: $_vmServiceUri'));
      }
      // Attempt connection as soon as URI is found
      if (!_appStarted) {
        // If URI is found before app is considered started, it's okay,
        // connection attempt will happen here, potentially before the
        // "App started successfully" message.
      }
      _connectToVmService(_vmServiceUri!);
    }

    // Check if app started - This message usually comes after the URI
    if (line.contains('Flutter run key commands') ||
        line.contains('An Observatory debugger') ||
        line.contains('A Dart VM Service')) {
      if (!_appStarted) {
        _appStarted = true;
        print(_green('✓ App started successfully'));
        print(_cyan('Commands: r=reload, R=restart, q=quit, h=help'));

        // The URI should ideally be found before this, but double-check
        // if connection attempt hasn't happened yet due to regex mismatch
        // or timing. This part might be redundant now but is safe.
        if (_vmServiceUri != null && _vmService == null) {
          if (verbose) {
            print(
              _gray(
                'App started, attempting VM Service connection (fallback).',
              ),
            );
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
    // Prevent multiple connection attempts if URI is detected multiple times
    if (_vmService != null) {
      if (verbose) {
        print(
          _gray(
            'Already connected to VM Service, skipping new connection attempt.',
          ),
        );
      }
      return;
    }

    try {
      // Convert observatory URI to WebSocket URI
      final wsUri = uri
          .replaceFirst('http://', 'ws://')
          .replaceFirst('https://', 'wss://'); // Also handle https if needed

      if (verbose) {
        print(_gray('Connecting to VM Service at $wsUri'));
      }

      _vmService = await vmServiceConnectUri(wsUri);

      print(_green('✓ Connected to VM Service for enhanced logging'));

      // Subscribe to streams before listening to them
      await _vmService!.streamListen(EventStreams.kStdout);
      await _vmService!.streamListen(EventStreams.kStderr);
      await _vmService!.streamListen(
        EventStreams.kLogging,
      ); // Use constant for Logging stream

      // Listen to stdout stream
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

      // Listen to stderr stream
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

      // Listen to logging events (dart:developer log)
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
      // Optionally reset _vmServiceUri if connection fails immediately
      // to allow retry if the URI appears again (though unlikely)
      // _vmService = null; // _vmService is already null if connect failed
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
    // Set stdin to raw mode for immediate key capture
    stdin.lineMode = false;
    stdin.echoMode = false;

    stdin.listen((data) {
      final char = String.fromCharCodes(data);

      // Handle lowercase 'r' for reload
      if (char == 'r') {
        if (!_appStarted) {
          print(_yellow('⏳ Waiting for app to start...'));
          return;
        }
        _hotReload();
        return;
      }

      // Handle uppercase 'R' for restart
      if (char == 'R') {
        if (!_appStarted) {
          print(_yellow('⏳ Waiting for app to start...'));
          return;
        }
        _hotRestart();
        return;
      }

      // Handle quit
      if (char == 'q' || char == 'Q') {
        print(_cyan('\n👋 Quitting...'));
        _cleanup();
        exit(0);
      }

      // Handle help
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

      // Wait before allowing another reload
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

      // Wait before allowing another action
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
    await _vmService?.dispose(); // Dispose the VM Service connection properly
    _process?.kill();
  }
}
