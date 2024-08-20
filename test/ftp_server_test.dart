import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ftp_server/file_operations/physical_file_operations.dart';
import 'package:ftp_server/ftp_server.dart';
import 'package:ftp_server/server_type.dart';
import 'package:intl/intl.dart';

import 'platform_output_handler/platform_output_handler.dart';
import 'platform_output_handler/platform_output_handler_factory.dart';

String _formatModificationTime(DateTime dateTime) {
  return DateFormat('MMM dd HH:mm').format(dateTime);
}

void main() {
  final Directory tempDir = Directory.systemTemp.createTempSync('ftp_test');
  final PlatformOutputHandler outputHandler =
      PlatformOutputHandlerFactory.create();
  late FtpServer server;
  late Process ftpClient;
  const int port = 2126;
  final String logFilePath = '${tempDir.path}/ftpsession.log';

  Future<String> execFTPCmdOnWin(String commands) async {
    const String ftpHost = '127.0.0.1 $port';
    const String user = 'test';
    const String password = 'password';
    String command = '''
    open $ftpHost
    user $user $password
    $commands
    quit
    ''';

    File scriptFile = File('ftp_win_script.txt');
    await scriptFile.writeAsString(command);

    try {
      ProcessResult result = await Process.run(
          'ftp', ['-n', '-v', '-s:ftp_win_script.txt'],
          runInShell: true);
      return result.stdout + result.stderr;
    } catch (e) {
      // print('Error: $e');
    } finally {
      await scriptFile.delete();
    }
    return "";
  }

  Future<bool> isFtpAvailable() async {
    try {
      final result = await Process.run('ftp', ['-v'], runInShell: true);
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }

  Future<void> installFtp() async {
    if (Platform.isLinux) {
      await Process.run('sudo', ['apt-get', 'update'], runInShell: true);
      await Process.run('sudo', ['apt-get', 'install', '-y', 'ftp'],
          runInShell: true);
    } else if (Platform.isMacOS) {
      await Process.run('brew', ['install', 'inetutils'], runInShell: true);
    } else if (Platform.isWindows) {
      // FTP command should be available on Windows by default
    }
  }

  Future<void> connectAndAuthenticate() async {
    ftpClient = await Process.start(
      Platform.isWindows ? 'ftp' : 'bash',
      Platform.isWindows ? ['-n', '-v'] : ['-c', 'ftp -n -v'],
      runInShell: true,
    );

    File(logFilePath).writeAsStringSync(''); // Clear the log file
    ftpClient.stdout.transform(utf8.decoder).listen((data) {
      File(logFilePath).writeAsStringSync(data, mode: FileMode.append);
    });
    ftpClient.stderr.transform(utf8.decoder).listen((data) {
      File(logFilePath).writeAsStringSync(data, mode: FileMode.append);
    });

    ftpClient.stdin.writeln('open 127.0.0.1 $port');
    await ftpClient.stdin.flush();
    ftpClient.stdin.writeln('user test password');
    await ftpClient.stdin.flush();
  }

  Future<String> readAllOutput() async {
    await Future.delayed(
        const Duration(milliseconds: 500)); // Wait for log to be written
    return File(logFilePath).readAsStringSync();
  }

  group('FTP Server Tests', () {
    setUpAll(() async {
      // Ensure the ftp command is available
      if (!await isFtpAvailable()) {
        await installFtp();
      }
      if (!await isFtpAvailable()) {
        throw Exception(
            'FTP command is not available and could not be installed.');
      }

      // Create the allowed directory and start the FTP server
      tempDir.createSync(recursive: true);
      server = FtpServer(
        port,
        username: 'test',
        password: 'password',
        fileOperations: PhysicalFileOperations(tempDir.path),
        serverType: ServerType.readAndWrite,
        logFunction: (String message) => print(message),
      );
      await server.startInBackground();
    });

    tearDownAll(() async {
      await server.stop();
      tempDir.deleteSync(recursive: true);
    });

    setUp(() async {
      await connectAndAuthenticate();
    });

    tearDown(() async {
      ftpClient.kill();
    });

    test('Authentication Success', () async {
      ftpClient.stdin.writeln('quit');
      await ftpClient.stdin.flush();

      var output = await readAllOutput();
      if (Platform.isWindows) {
        output = await execFTPCmdOnWin("quit");
      }

      expect(output, contains('230 User logged in, proceed'));
    });

    test('List Directory', () async {
      ftpClient.stdin.writeln('ls');
      if (Platform.isLinux) {
        ftpClient.stdin.writeln('passive on');
        ftpClient.stdin.writeln('ls');
        ftpClient.stdin.writeln('passive off');
      }
      ftpClient.stdin.writeln('quit');
      await ftpClient.stdin.flush();

      var output = await readAllOutput();
      if (Platform.isWindows) {
        output = await execFTPCmdOnWin("ls");
      }

      // Build the expected listing dynamically based on the actual directory contents
      var listing = StringBuffer();
      var dirContents = Directory(tempDir.path).listSync();
      for (var entity in dirContents) {
        var stat = entity.statSync();
        String permissions = (entity is File) ? '-rw-r--r--' : 'drwxr-xr-x';
        String fileSize = stat.size.toString();
        String modificationTime = _formatModificationTime(stat.modified);
        String fileName = entity.path.split(Platform.pathSeparator).last;

        // Ignore the size and modification time for ftpsession.log
        if (fileName == 'ftpsession.log') {
          fileSize = '[IGNORED SIZE]';
          modificationTime = '[IGNORED TIME]';
        }

        listing.writeln(
            '$permissions 1 ftp ftp $fileSize $modificationTime $fileName');
      }

      // Adjust the actual output to ignore the size and modification time for ftpsession.log
      var adjustedOutput = output.replaceAll(
          RegExp(
              r'-rw-r--r-- 1 ftp ftp \d+ \w{3} \d{2} \d{2}:\d{2} ftpsession.log'),
          '-rw-r--r-- 1 ftp ftp [IGNORED SIZE] [IGNORED TIME] ftpsession.log');

      final expectedOutput = outputHandler
          .getExpectedDirectoryListingOutput(listing.toString().trim());
      expect(adjustedOutput, contains(expectedOutput));
    });

    test('Change Directory', () async {
      ftpClient.stdin.writeln('cd ${tempDir.path}');
      ftpClient.stdin.writeln('quit');
      await ftpClient.stdin.flush();

      var output = await readAllOutput();
      if (Platform.isWindows) {
        output = await execFTPCmdOnWin("cd ${tempDir.path}");
      }

      final expectedOutput =
          outputHandler.getExpectedDirectoryChangeOutput(tempDir.path);
      expect(output, contains(expectedOutput));
    });

    test('Make Directory', () async {
      ftpClient.stdin.writeln('mkdir test_dir');
      ftpClient.stdin.writeln('ls');
      ftpClient.stdin.writeln('quit');
      await ftpClient.stdin.flush();

      var output = await readAllOutput();
      if (Platform.isWindows) {
        output = await execFTPCmdOnWin("mkdir test_dir\nls");
      }

      expect(output, contains('257 "test_dir" created'));
      expect(output, contains('test_dir'));
      expect(Directory('${tempDir.path}/test_dir').existsSync(), isTrue);
    });

    test('Remove Directory', () async {
      ftpClient.stdin.writeln('mkdir test_dir');
      ftpClient.stdin.writeln('rmdir test_dir');
      ftpClient.stdin.writeln('ls');
      ftpClient.stdin.writeln('quit');
      await ftpClient.stdin.flush();

      var output = await readAllOutput();
      if (Platform.isWindows) {
        output = await execFTPCmdOnWin("mkdir test_dir\nrmdir test_dir");
        expect(output, contains('250 Directory deleted'));
        output = await execFTPCmdOnWin("ls");
      } else {
        expect(output, contains('250 Directory deleted'));
      }
      expect(output, isNot(contains('test_dir')));
      expect(Directory('${tempDir.path}/test_dir').existsSync(), isFalse);
    });

    test('Store File', () async {
      final testFile = File('${tempDir.path}/test_file.txt')
        ..writeAsStringSync('Hello, FTP!');

      ftpClient.stdin.writeln('put ${testFile.path}');
      ftpClient.stdin.writeln('ls');
      ftpClient.stdin.writeln('quit');
      await ftpClient.stdin.flush();

      var output = await readAllOutput();
      if (Platform.isWindows) {
        output = await execFTPCmdOnWin("put ${testFile.path}");
        expect(output, contains('226 Transfer complete'));
        output = await execFTPCmdOnWin("ls");
      } else {
        expect(output, contains('226 Transfer complete'));
      }
      expect(output, contains('test_file.txt'));
    });

    test('Retrieve File', () async {
      final testPath = '${tempDir.path}/test_file_ret.txt';
      final testFile = File(testPath)..writeAsStringSync('Hello, FTP!');

      ftpClient.stdin.writeln('get ${testFile.path} $testPath');
      ftpClient.stdin.writeln('ls');
      ftpClient.stdin.writeln('quit');
      await ftpClient.stdin.flush();

      var output = await readAllOutput();
      if (Platform.isWindows) {
        output = await execFTPCmdOnWin('get ${testFile.path} $testPath');
        expect(output, contains('226 Transfer complete'));
        output = await execFTPCmdOnWin('dir');
      } else {
        expect(output, contains('226 Transfer complete'));
      }
      expect(File(testPath).existsSync(), isTrue);
    });

    test('Delete File', () async {
      final testFile = File('${tempDir.path}/test_file.txt')
        ..writeAsStringSync('Hello, FTP!');

      ftpClient.stdin.writeln('delete ${testFile.path}');
      ftpClient.stdin.writeln('ls');
      ftpClient.stdin.writeln('quit');
      await ftpClient.stdin.flush();

      var output = await readAllOutput();
      if (Platform.isWindows) {
        output = (await execFTPCmdOnWin('delete ${testFile.path}'));
        expect(output, contains('250 File deleted'));
        output = (await execFTPCmdOnWin('dir'));
      } else {
        expect(output, contains('250 File deleted'));
      }
      expect(output, isNot(contains('test_file.txt')));
      expect(testFile.existsSync(), isFalse);
    });

    if (!Platform.isWindows) {
      test('File Size', () async {
        final testFile = File('${tempDir.path}/test_file.txt')
          ..writeAsStringSync('Hello, FTP!');

        ftpClient.stdin.writeln('size ${testFile.path}');
        ftpClient.stdin.writeln('ls');
        ftpClient.stdin.writeln('quit');
        await ftpClient.stdin.flush();

        var output = await readAllOutput();
        var expectText = outputHandler.getExpectedSizeOutput(11);

        expect(output, contains(expectText)); // File size is 11 bytes
        expect(output, contains('test_file.txt'));
      });

      test('System Command', () async {
        ftpClient.stdin.writeln('syst');
        ftpClient.stdin.writeln('quit');
        await ftpClient.stdin.flush();

        var output = await readAllOutput();

        expect(output, contains('215 UNIX Type: L8'));
      });
    }

    test('Print Working Directory Command', () async {
      ftpClient.stdin.writeln('pwd');
      ftpClient.stdin.writeln('quit');
      await ftpClient.stdin.flush();

      var output = await readAllOutput();
      if (Platform.isWindows) {
        output = await execFTPCmdOnWin('pwd');
      }

      final expectText = outputHandler
          .getExpectedPwdOutput(tempDir.path.replaceAll("\\", "/"));
      expect(output, contains(expectText));
    });

    test('List Nested Directories', () async {
      // Step 1: Create nested directories
      final nestedDirPath = '${tempDir.path}/outer_dir/inner_dir';
      Directory(nestedDirPath).createSync(recursive: true);

      // Step 2: Change directory to the outer directory
      ftpClient.stdin.writeln('cd ${tempDir.path}/outer_dir');
      ftpClient.stdin.writeln('pwd'); // To check we're in the right directory

      // Step 3: List directories inside the outer directory
      ftpClient.stdin.writeln('ls');

      // Step 4: Change directory to the inner directory using relative path
      ftpClient.stdin.writeln('cd inner_dir');
      ftpClient.stdin.writeln('pwd'); // To check we're in the right directory

      // Step 5: List directories inside the inner directory
      ftpClient.stdin.writeln('ls');

      // Step 6: Quit FTP session
      ftpClient.stdin.writeln('quit');
      await ftpClient.stdin.flush();

      var output = await readAllOutput();
      if (Platform.isWindows) {
        output = await execFTPCmdOnWin(
            'cd ${tempDir.path}/outer_dir\npwd\nls\ncd inner_dir\npwd\nls');
      }

      final expectedOuterDir = '${tempDir.path}/outer_dir';
      final expectedInnerDir = '${tempDir.path}/outer_dir/inner_dir';

      expect(
          output,
          contains(outputHandler
              .getExpectedDirectoryChangeOutput(expectedOuterDir)));
      expect(
          output,
          contains(outputHandler
              .getExpectedDirectoryChangeOutput(expectedInnerDir)));
      expect(output, contains('inner_dir'));
    });

    test('Change Directories Using Absolute and Relative Paths', () async {
      // Step 1: Create nested directories
      final nestedDirPath = '${tempDir.path}/outer_dir/inner_dir';
      Directory(nestedDirPath).createSync(recursive: true);

      // Step 2: Change directory using absolute path to outer directory
      ftpClient.stdin.writeln('cd ${tempDir.path}/outer_dir');
      ftpClient.stdin.writeln('pwd'); // To check we're in the right directory

      // Step 3: Change directory using relative path to inner directory
      ftpClient.stdin.writeln('cd inner_dir');
      ftpClient.stdin.writeln('pwd'); // To check we're in the right directory

      // Step 4: Change directory back to the outer directory using relative path
      ftpClient.stdin.writeln('cd ..');
      ftpClient.stdin.writeln('pwd'); // To check we're in the outer directory

      // Step 5: Change directory using absolute path back to the inner directory
      ftpClient.stdin.writeln('cd $nestedDirPath');
      ftpClient.stdin.writeln('pwd'); // To check we're in the inner directory

      // Step 6: Quit FTP session
      ftpClient.stdin.writeln('quit');
      await ftpClient.stdin.flush();

      var output = await readAllOutput();
      if (Platform.isWindows) {
        output = await execFTPCmdOnWin(
            'cd ${tempDir.path}/outer_dir\npwd\ncd inner_dir\npwd\ncd ..\npwd\ncd $nestedDirPath\npwd');
      }

      final expectedOuterDir = '${tempDir.path}/outer_dir';
      final expectedInnerDir = '${tempDir.path}/outer_dir/inner_dir';

      expect(
          output,
          contains(outputHandler
              .getExpectedDirectoryChangeOutput(expectedOuterDir)));
      expect(
          output,
          contains(outputHandler
              .getExpectedDirectoryChangeOutput(expectedInnerDir)));
      expect(
          output,
          contains(outputHandler
              .getExpectedDirectoryChangeOutput(expectedOuterDir)));
      expect(
          output,
          contains(outputHandler
              .getExpectedDirectoryChangeOutput(expectedInnerDir)));
    });
  });
}
