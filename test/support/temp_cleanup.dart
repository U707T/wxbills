import 'dart:async';
import 'dart:io';

Future<void> deleteTempDirectory(Directory directory) async {
  FileSystemException? lastError;
  for (var attempt = 0; attempt < 10; attempt++) {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
      return;
    } on FileSystemException catch (error) {
      lastError = error;
      if (!await directory.exists()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  if (lastError != null) throw lastError;
}
