import 'dart:collection';
import 'dart:math';

import 'DiffClass.dart';
import 'Operation.enum.dart';
import 'PatchClass.dart';

class DiffMatchPatch {
  double Diff_Timeout = 1.0;
  int Diff_EditCost = 4;
  double Match_Threshold = 0.5;
  int Match_Distance = 1000;
  double Patch_DeleteThreshold = 0.5;
  int Patch_Margin = 4;
  int Match_MaxBits = 32;

  List<Diff> diff_main(String? text1, String? text2,
      [bool checklines = true, DateTime? deadline]) {
    // Set a deadline by which time the diff must be complete.
    if (deadline == null) {
      deadline = new DateTime.now();
      if (Diff_Timeout <= 0) {
        // One year should be sufficient for 'infinity'.
        deadline = deadline.add(new Duration(days: 365));
      } else {
        deadline = deadline
            .add(new Duration(milliseconds: (Diff_Timeout * 1000).toInt()));
      }
    }
    // Check for null inputs.
    if (text1 == null || text2 == null) {
      throw new ArgumentError('Null inputs. (diff_main)');
    }

    // Check for equality (speedup).
    List<Diff> diffs;
    if (text1 == text2) {
      diffs = [];
      if (text1.isNotEmpty) {
        diffs.add(new Diff(Operation.equal, text1));
      }
      return diffs;
    }

    // Trim off common prefix (speedup).
    int commonlength = diff_commonPrefix(text1, text2);
    String commonprefix = text1.substring(0, commonlength);
    text1 = text1.substring(commonlength);
    text2 = text2.substring(commonlength);

    // Trim off common suffix (speedup).
    commonlength = diff_commonSuffix(text1, text2);
    String commonsuffix = text1.substring(text1.length - commonlength);
    text1 = text1.substring(0, text1.length - commonlength);
    text2 = text2.substring(0, text2.length - commonlength);

    // Compute the diff on the middle block.
    diffs = _diff_compute(text1, text2, checklines, deadline);

    // Restore the prefix and suffix.
    if (commonprefix.isNotEmpty) {
      diffs.insert(0, new Diff(Operation.equal, commonprefix));
    }
    if (commonsuffix.isNotEmpty) {
      diffs.add(new Diff(Operation.equal, commonsuffix));
    }

    diff_cleanupMerge(diffs);
    return diffs;
  }

  /// Find the differences between two texts.  Assumes that the texts do not
  /// have any common prefix or suffix.
  /// [text1] is the old string to be diffed.
  /// [text2] is the new string to be diffed.
  /// [checklines] is a speedup flag.  If false, then don't run a
  ///     line-level diff first to identify the changed areas.
  ///     If true, then run a faster slightly less optimal diff.
  /// [deadline] is the time when the diff should be complete by.
  /// Returns a List of Diff objects.
  List<Diff> _diff_compute(
      String text1, String text2, bool checklines, DateTime deadline) {
    List<Diff> diffs = <Diff>[];

    if (text1.length == 0) {
      // Just add some text (speedup).
      diffs.add(new Diff(Operation.insert, text2));
      return diffs;
    }

    if (text2.length == 0) {
      // Just delete some text (speedup).
      diffs.add(new Diff(Operation.delete, text1));
      return diffs;
    }

    String longtext = text1.length > text2.length ? text1 : text2;
    String shorttext = text1.length > text2.length ? text2 : text1;
    int i = longtext.indexOf(shorttext);
    if (i != -1) {
      // Shorter text is inside the longer text (speedup).
      Operation op =
          (text1.length > text2.length) ? Operation.delete : Operation.insert;
      diffs.add(new Diff(op, longtext.substring(0, i)));
      diffs.add(new Diff(Operation.equal, shorttext));
      diffs.add(new Diff(op, longtext.substring(i + shorttext.length)));
      return diffs;
    }

    if (shorttext.length == 1) {
      // Single character string.
      // After the previous speedup, the character can't be an equality.
      diffs.add(new Diff(Operation.delete, text1));
      diffs.add(new Diff(Operation.insert, text2));
      return diffs;
    }

    // Check to see if the problem can be split in two.
    final hm = _diff_halfMatch(text1, text2);
    if (hm != null) {
      // A half-match was found, sort out the return data.
      final text1A = hm[0];
      final text1B = hm[1];
      final text2A = hm[2];
      final text2B = hm[3];
      final midCommon = hm[4];
      // Send both pairs off for separate processing.
      final diffsA = diff_main(text1A, text2A, checklines, deadline);
      final diffsB = diff_main(text1B, text2B, checklines, deadline);
      // Merge the results.
      diffs = diffsA;
      diffs.add(new Diff(Operation.equal, midCommon));
      diffs.addAll(diffsB);
      return diffs;
    }

    if (checklines && text1.length > 100 && text2.length > 100) {
      return _diff_lineMode(text1, text2, deadline);
    }

    return _diff_bisect(text1, text2, deadline);
  }

  /// Do a quick line-level diff on both strings, then rediff the parts for
  /// greater accuracy.
  /// This speedup can produce non-minimal diffs.
  /// [text1] is the old string to be diffed.
  /// [text2] is the new string to be diffed.
  /// [deadline] is the time when the diff should be complete by.
  /// Returns a List of Diff objects.
  List<Diff> _diff_lineMode(String text1, String text2, DateTime deadline) {
    // Scan the text on a line-by-line basis first.
    final a = _diff_linesToChars(text1, text2);
    text1 = a['chars1'];
    text2 = a['chars2'];
    final linearray = a['lineArray'];

    final diffs = diff_main(text1, text2, false, deadline);

    // Convert the diff back to original text.
    _diff_charsToLines(diffs, linearray);
    // Eliminate freak matches (e.g. blank lines)
    diff_cleanupSemantic(diffs);

    // Rediff any replacement blocks, this time character-by-character.
    // Add a dummy entry at the end.
    diffs.add(new Diff(Operation.equal, ''));
    int pointer = 0;
    int countDelete = 0;
    int countInsert = 0;
    final textDelete = new StringBuffer();
    final textInsert = new StringBuffer();
    while (pointer < diffs.length) {
      switch (diffs[pointer].operation) {
        case Operation.insert:
          countInsert++;
          textInsert.write(diffs[pointer].text);
          break;
        case Operation.delete:
          countDelete++;
          textDelete.write(diffs[pointer].text);
          break;
        case Operation.equal:
          // Upon reaching an equality, check for prior redundancies.
          if (countDelete >= 1 && countInsert >= 1) {
            // Delete the offending records and add the merged ones.
            diffs.removeRange(pointer - countDelete - countInsert, pointer);
            pointer = pointer - countDelete - countInsert;
            final subDiff = diff_main(
                textDelete.toString(), textInsert.toString(), false, deadline);
            for (int j = subDiff.length - 1; j >= 0; j--) {
              diffs.insert(pointer, subDiff[j]);
            }
            pointer = pointer + subDiff.length;
          }
          countInsert = 0;
          countDelete = 0;
          textDelete.clear();
          textInsert.clear();
          break;
      }
      pointer++;
    }
    diffs.removeLast(); // Remove the dummy entry at the end.

    return diffs;
  }

  /// Find the 'middle snake' of a diff, split the problem in two
  /// and return the recursively constructed diff.
  /// See Myers 1986 paper: An O(ND) Difference Algorithm and Its Variations.
  /// [text1] is the old string to be diffed.
  /// [text2] is the new string to be diffed.
  /// [deadline] is the time at which to bail if not yet complete.
  /// Returns a List of Diff objects.
  List<Diff> _diff_bisect(String text1, String text2, DateTime deadline) {
    // Cache the text lengths to prevent multiple calls.
    final text1Length = text1.length;
    final text2Length = text2.length;
    final maxD = (text1Length + text2Length + 1) ~/ 2;
    final vOffset = maxD;
    final vLength = 2 * maxD;
    final v1 = List.filled(vLength, 0, growable: false);
    final v2 = List.filled(vLength, 0, growable: false);
    for (int x = 0; x < vLength; x++) {
      v1[x] = -1;
      v2[x] = -1;
    }
    v1[vOffset + 1] = 0;
    v2[vOffset + 1] = 0;
    final delta = text1Length - text2Length;
    // If the total number of characters is odd, then the front path will
    // collide with the reverse path.
    final front = (delta % 2 != 0);
    // Offsets for start and end of k loop.
    // Prevents mapping of space beyond the grid.
    int k1start = 0;
    int k1end = 0;
    int k2start = 0;
    int k2end = 0;
    for (int d = 0; d < maxD; d++) {
      // Bail out if deadline is reached.
      if ((new DateTime.now()).compareTo(deadline) == 1) {
        break;
      }

      // Walk the front path one step.
      for (int k1 = -d + k1start; k1 <= d - k1end; k1 += 2) {
        int k1Offset = vOffset + k1;
        int x1;
        if (k1 == -d || k1 != d && v1[k1Offset - 1] < v1[k1Offset + 1]) {
          x1 = v1[k1Offset + 1];
        } else {
          x1 = v1[k1Offset - 1] + 1;
        }
        int y1 = x1 - k1;
        while (x1 < text1Length && y1 < text2Length && text1[x1] == text2[y1]) {
          x1++;
          y1++;
        }
        v1[k1Offset] = x1;
        if (x1 > text1Length) {
          // Ran off the right of the graph.
          k1end += 2;
        } else if (y1 > text2Length) {
          // Ran off the bottom of the graph.
          k1start += 2;
        } else if (front) {
          int k2Offset = vOffset + delta - k1;
          if (k2Offset >= 0 && k2Offset < vLength && v2[k2Offset] != -1) {
            // Mirror x2 onto top-left coordinate system.
            int x2 = text1Length - v2[k2Offset];
            if (x1 >= x2) {
              // Overlap detected.
              return _diff_bisectSplit(text1, text2, x1, y1, deadline);
            }
          }
        }
      }

      // Walk the reverse path one step.
      for (int k2 = -d + k2start; k2 <= d - k2end; k2 += 2) {
        int k2Offset = vOffset + k2;
        int x2;
        if (k2 == -d || k2 != d && v2[k2Offset - 1] < v2[k2Offset + 1]) {
          x2 = v2[k2Offset + 1];
        } else {
          x2 = v2[k2Offset - 1] + 1;
        }
        int y2 = x2 - k2;
        while (x2 < text1Length &&
            y2 < text2Length &&
            text1[text1Length - x2 - 1] == text2[text2Length - y2 - 1]) {
          x2++;
          y2++;
        }
        v2[k2Offset] = x2;
        if (x2 > text1Length) {
          // Ran off the left of the graph.
          k2end += 2;
        } else if (y2 > text2Length) {
          // Ran off the top of the graph.
          k2start += 2;
        } else if (!front) {
          int k1Offset = vOffset + delta - k2;
          if (k1Offset >= 0 && k1Offset < vLength && v1[k1Offset] != -1) {
            int x1 = v1[k1Offset];
            int y1 = vOffset + x1 - k1Offset;
            // Mirror x2 onto top-left coordinate system.
            x2 = text1Length - x2;
            if (x1 >= x2) {
              // Overlap detected.
              return _diff_bisectSplit(text1, text2, x1, y1, deadline);
            }
          }
        }
      }
    }
    // Diff took too long and hit the deadline or
    // number of diffs equals number of characters, no commonality at all.
    return [
      new Diff(Operation.delete, text1),
      new Diff(Operation.insert, text2)
    ];
  }

  /// Hack to allow unit tests to call private method.  Do not use.
  List<Diff> test_diff_bisect(String text1, String text2, DateTime deadline) {
    return _diff_bisect(text1, text2, deadline);
  }

  /// Given the location of the 'middle snake', split the diff in two parts
  /// and recurse.
  /// [text1] is the old string to be diffed.
  /// [text2] is the new string to be diffed.
  /// [x] is the index of split point in text1.
  /// [y] is the index of split point in text2.
  /// [deadline] is the time at which to bail if not yet complete.
  /// Returns a List of Diff objects.
  List<Diff> _diff_bisectSplit(
      String text1, String text2, int x, int y, DateTime deadline) {
    final text1a = text1.substring(0, x);
    final text2a = text2.substring(0, y);
    final text1b = text1.substring(x);
    final text2b = text2.substring(y);

    // Compute both diffs serially.
    final diffs = diff_main(text1a, text2a, false, deadline);
    final diffsb = diff_main(text1b, text2b, false, deadline);

    diffs.addAll(diffsb);
    return diffs;
  }

  /// Split two texts into a list of strings.  Reduce the texts to a string of
  /// hashes where each Unicode character represents one line.
  /// [text1] is the first string.
  /// [text2] is the second string.
  /// Returns a Map containing the encoded text1, the encoded text2 and
  ///     the List of unique strings.  The zeroth element of the List of
  ///     unique strings is intentionally blank.
  Map<String, dynamic> _diff_linesToChars(String text1, String text2) {
    final lineArray = <String>[];
    final lineHash = new HashMap<String, int>();
    // e.g. linearray[4] == 'Hello\n'
    // e.g. linehash['Hello\n'] == 4

    // '\x00' is a valid character, but various debuggers don't like it.
    // So we'll insert a junk entry to avoid generating a null character.
    lineArray.add('');

    // Allocate 2/3rds of the space for text1, the rest for text2.
    String chars1 = _diff_linesToCharsMunge(text1, lineArray, lineHash, 40000);
    String chars2 = _diff_linesToCharsMunge(text2, lineArray, lineHash, 65535);
    return {'chars1': chars1, 'chars2': chars2, 'lineArray': lineArray};
  }

  /// Hack to allow unit tests to call private method.  Do not use.
  Map<String, dynamic> test_diff_linesToChars(String text1, String text2) {
    return _diff_linesToChars(text1, text2);
  }

  /// Split a text into a list of strings.  Reduce the texts to a string of
  /// hashes where each Unicode character represents one line.
  /// [text] is the string to encode.
  /// [lineArray] is a List of unique strings.
  /// [lineHash] is a Map of strings to indices.
  /// [maxLines] is the maximum length for lineArray.
  /// Returns an encoded string.
  String _diff_linesToCharsMunge(String text, List<String> lineArray,
      Map<String, int> lineHash, int maxLines) {
    int lineStart = 0;
    int lineEnd = -1;
    String line;
    final chars = new StringBuffer();
    // Walk the text, pulling out a substring for each line.
    // text.split('\n') would would temporarily double our memory footprint.
    // Modifying text would create many large strings to garbage collect.
    while (lineEnd < text.length - 1) {
      lineEnd = text.indexOf('\n', lineStart);
      if (lineEnd == -1) {
        lineEnd = text.length - 1;
      }
      line = text.substring(lineStart, lineEnd + 1);

      if (lineHash.containsKey(line)) {
        chars.writeCharCode(lineHash[line]!);
      } else {
        if (lineArray.length == maxLines) {
          // Bail out at 65535 because
          // final chars1 = new StringBuffer();
          // chars1.writeCharCode(65536);
          // chars1.toString().codeUnitAt(0) == 55296;
          line = text.substring(lineStart);
          lineEnd = text.length;
        }
        lineArray.add(line);
        lineHash[line] = lineArray.length - 1;
        chars.writeCharCode(lineArray.length - 1);
      }
      lineStart = lineEnd + 1;
    }
    return chars.toString();
  }

  /// Rehydrate the text in a diff from a string of line hashes to real lines of
  /// text.
  /// [diffs] is a List of Diff objects.
  /// [lineArray] is a List of unique strings.
  void _diff_charsToLines(List<Diff> diffs, List<String> lineArray) {
    final text = new StringBuffer();
    for (Diff diff in diffs) {
      for (int j = 0; j < diff.text.length; j++) {
        text.write(lineArray[diff.text.codeUnitAt(j)]);
      }
      diff.text = text.toString();
      text.clear();
    }
  }

  /// Hack to allow unit tests to call private method.  Do not use.
  void test_diff_charsToLines(List<Diff> diffs, List<String> lineArray) {
    _diff_charsToLines(diffs, lineArray);
  }

  /// Determine the common prefix of two strings
  /// [text1] is the first string.
  /// [text2] is the second string.
  /// Returns the number of characters common to the start of each string.
  int diff_commonPrefix(String text1, String text2) {
    // TODO: Once Dart's performance stabilizes, determine if linear or binary
    // search is better.
    // Performance analysis: https://neil.fraser.name/news/2007/10/09/
    final n = min(text1.length, text2.length);
    for (int i = 0; i < n; i++) {
      if (text1[i] != text2[i]) {
        return i;
      }
    }
    return n;
  }

  /// Determine the common suffix of two strings
  /// [text1] is the first string.
  /// [text2] is the second string.
  /// Returns the number of characters common to the end of each string.
  int diff_commonSuffix(String text1, String text2) {
    // TODO: Once Dart's performance stabilizes, determine if linear or binary
    // search is better.
    // Performance analysis: https://neil.fraser.name/news/2007/10/09/
    final text1Length = text1.length;
    final text2Length = text2.length;
    final n = min(text1Length, text2Length);
    for (int i = 1; i <= n; i++) {
      if (text1[text1Length - i] != text2[text2Length - i]) {
        return i - 1;
      }
    }
    return n;
  }

  /// Determine if the suffix of one string is the prefix of another.
  /// [text1] is the first string.
  /// [text2] is the second string.
  /// Returns the number of characters common to the end of the first
  ///     string and the start of the second string.
  int _diff_commonOverlap(String text1, String text2) {
    // Eliminate the null case.
    if (text1.isEmpty || text2.isEmpty) {
      return 0;
    }
    // Cache the text lengths to prevent multiple calls.
    final text1Length = text1.length;
    final text2Length = text2.length;
    // Truncate the longer string.
    if (text1Length > text2Length) {
      text1 = text1.substring(text1Length - text2Length);
    } else if (text1Length < text2Length) {
      text2 = text2.substring(0, text1Length);
    }
    final textLength = min(text1Length, text2Length);
    // Quick check for the worst case.
    if (text1 == text2) {
      return textLength;
    }

    // Start by looking for a single character match
    // and increase length until no match is found.
    // Performance analysis: https://neil.fraser.name/news/2010/11/04/
    int best = 0;
    int length = 1;
    while (true) {
      String pattern = text1.substring(textLength - length);
      int found = text2.indexOf(pattern);
      if (found == -1) {
        return best;
      }
      length += found;
      if (found == 0 ||
          text1.substring(textLength - length) == text2.substring(0, length)) {
        best = length;
        length++;
      }
    }
  }

  /// Hack to allow unit tests to call private method.  Do not use.
  int test_diff_commonOverlap(String text1, String text2) {
    return _diff_commonOverlap(text1, text2);
  }

  /// Do the two texts share a substring which is at least half the length of
  /// the longer text?
  /// This speedup can produce non-minimal diffs.
  /// [text1] is the first string.
  /// [text2] is the second string.
  /// Returns a five element List of Strings, containing the prefix of text1,
  ///     the suffix of text1, the prefix of text2, the suffix of text2 and the
  ///     common middle.  Or null if there was no match.
  List<String>? _diff_halfMatch(String text1, String text2) {
    if (Diff_Timeout <= 0) {
      // Don't risk returning a non-optimal diff if we have unlimited time.
      return null;
    }
    final longtext = text1.length > text2.length ? text1 : text2;
    final shorttext = text1.length > text2.length ? text2 : text1;
    if (longtext.length < 4 || shorttext.length * 2 < longtext.length) {
      return null; // Pointless.
    }

    // First check if the second quarter is the seed for a half-match.
    final hm1 = _diff_halfMatchI(
        longtext, shorttext, ((longtext.length + 3) / 4).ceil().toInt());
    // Check again based on the third quarter.
    final hm2 = _diff_halfMatchI(
        longtext, shorttext, ((longtext.length + 1) / 2).ceil().toInt());
    List<String> hm;
    if (hm1 == null && hm2 == null) {
      return null;
    } else if (hm2 == null) {
      hm = hm1!;
    } else if (hm1 == null) {
      hm = hm2;
    } else {
      // Both matched.  Select the longest.
      hm = hm1[4].length > hm2[4].length ? hm1 : hm2;
    }

    // A half-match was found, sort out the return data.
    if (text1.length > text2.length) {
      return hm;
      //return [hm[0], hm[1], hm[2], hm[3], hm[4]];
    } else {
      return [hm[2], hm[3], hm[0], hm[1], hm[4]];
    }
  }

  /// Hack to allow unit tests to call private method.  Do not use.
  List<String>? test_diff_halfMatch(String text1, String text2) {
    return _diff_halfMatch(text1, text2);
  }

  /// Does a substring of shorttext exist within longtext such that the
  /// substring is at least half the length of longtext?
  /// [longtext] is the longer string.
  /// [shorttext is the shorter string.
  /// [i] Start index of quarter length substring within longtext.
  /// Returns a five element String array, containing the prefix of longtext,
  ///     the suffix of longtext, the prefix of shorttext, the suffix of
  ///     shorttext and the common middle.  Or null if there was no match.
  List<String>? _diff_halfMatchI(String longtext, String shorttext, int i) {
    // Start with a 1/4 length substring at position i as a seed.
    final seed =
        longtext.substring(i, i + (longtext.length / 4).floor().toInt());
    int j = -1;
    String bestCommon = '';
    String bestLongtextA = '', bestLongtextB = '';
    String bestShorttextA = '', bestShorttextB = '';
    while ((j = shorttext.indexOf(seed, j + 1)) != -1) {
      int prefixLength =
          diff_commonPrefix(longtext.substring(i), shorttext.substring(j));
      int suffixLength = diff_commonSuffix(
          longtext.substring(0, i), shorttext.substring(0, j));
      if (bestCommon.length < suffixLength + prefixLength) {
        bestCommon = shorttext.substring(j - suffixLength, j) +
            shorttext.substring(j, j + prefixLength);
        bestLongtextA = longtext.substring(0, i - suffixLength);
        bestLongtextB = longtext.substring(i + prefixLength);
        bestShorttextA = shorttext.substring(0, j - suffixLength);
        bestShorttextB = shorttext.substring(j + prefixLength);
      }
    }
    if (bestCommon.length * 2 >= longtext.length) {
      return [
        bestLongtextA,
        bestLongtextB,
        bestShorttextA,
        bestShorttextB,
        bestCommon
      ];
    } else {
      return null;
    }
  }

  /// Reduce the number of edits by eliminating semantically trivial equalities.
  /// [diffs] is a List of Diff objects.
  void diff_cleanupSemantic(List<Diff> diffs) {
    bool changes = false;
    // Stack of indices where equalities are found.
    final equalities = <int>[];
    // Always equal to diffs[equalities.last()].text
    String? lastEquality = null;
    int pointer = 0; // Index of current position.
    // Number of characters that changed prior to the equality.
    int lengthInsertions1 = 0;
    int lengthDeletions1 = 0;
    // Number of characters that changed after the equality.
    int lengthInsertions2 = 0;
    int lengthDeletions2 = 0;
    while (pointer < diffs.length) {
      if (diffs[pointer].operation == Operation.equal) {
        // Equality found.
        equalities.add(pointer);
        lengthInsertions1 = lengthInsertions2;
        lengthDeletions1 = lengthDeletions2;
        lengthInsertions2 = 0;
        lengthDeletions2 = 0;
        lastEquality = diffs[pointer].text;
      } else {
        // An insertion or deletion.
        if (diffs[pointer].operation == Operation.insert) {
          lengthInsertions2 += diffs[pointer].text.length;
        } else {
          lengthDeletions2 += diffs[pointer].text.length;
        }
        // Eliminate an equality that is smaller or equal to the edits on both
        // sides of it.
        if (lastEquality != null &&
            (lastEquality.length <= max(lengthInsertions1, lengthDeletions1)) &&
            (lastEquality.length <= max(lengthInsertions2, lengthDeletions2))) {
          // Duplicate record.
          diffs.insert(
              equalities.last, new Diff(Operation.delete, lastEquality));
          // Change second copy to insert.
          diffs[equalities.last + 1].operation = Operation.insert;
          // Throw away the equality we just deleted.
          equalities.removeLast();
          // Throw away the previous equality (it needs to be reevaluated).
          if (equalities.isNotEmpty) {
            equalities.removeLast();
          }
          pointer = equalities.isEmpty ? -1 : equalities.last;
          lengthInsertions1 = 0; // Reset the counters.
          lengthDeletions1 = 0;
          lengthInsertions2 = 0;
          lengthDeletions2 = 0;
          lastEquality = null;
          changes = true;
        }
      }
      pointer++;
    }

    // Normalize the diff.
    if (changes) {
      diff_cleanupMerge(diffs);
    }
    _diff_cleanupSemanticLossless(diffs);

    // Find any overlaps between deletions and insertions.
    // e.g: <del>abcxxx</del><ins>xxxdef</ins>
    //   -> <del>abc</del>xxx<ins>def</ins>
    // e.g: <del>xxxabc</del><ins>defxxx</ins>
    //   -> <ins>def</ins>xxx<del>abc</del>
    // Only extract an overlap if it is as big as the edit ahead or behind it.
    pointer = 1;
    while (pointer < diffs.length) {
      if (diffs[pointer - 1].operation == Operation.delete &&
          diffs[pointer].operation == Operation.insert) {
        String deletion = diffs[pointer - 1].text;
        String insertion = diffs[pointer].text;
        int overlapLength1 = _diff_commonOverlap(deletion, insertion);
        int overlapLength2 = _diff_commonOverlap(insertion, deletion);
        if (overlapLength1 >= overlapLength2) {
          if (overlapLength1 >= deletion.length / 2 ||
              overlapLength1 >= insertion.length / 2) {
            // Overlap found.
            // Insert an equality and trim the surrounding edits.
            diffs.insert(
                pointer,
                new Diff(
                    Operation.equal, insertion.substring(0, overlapLength1)));
            diffs[pointer - 1].text =
                deletion.substring(0, deletion.length - overlapLength1);
            diffs[pointer + 1].text = insertion.substring(overlapLength1);
            pointer++;
          }
        } else {
          if (overlapLength2 >= deletion.length / 2 ||
              overlapLength2 >= insertion.length / 2) {
            // Reverse overlap found.
            // Insert an equality and swap and trim the surrounding edits.
            diffs.insert(
                pointer,
                new Diff(
                    Operation.equal, deletion.substring(0, overlapLength2)));
            diffs[pointer - 1] = new Diff(Operation.insert,
                insertion.substring(0, insertion.length - overlapLength2));
            diffs[pointer + 1] =
                new Diff(Operation.delete, deletion.substring(overlapLength2));
            pointer++;
          }
        }
        pointer++;
      }
      pointer++;
    }
  }

  /// Look for single edits surrounded on both sides by equalities
  /// which can be shifted sideways to align the edit to a word boundary.
  /// e.g: The c<ins>at c</ins>ame. -> The <ins>cat </ins>came.
  /// [diffs] is a List of Diff objects.
  void _diff_cleanupSemanticLossless(List<Diff> diffs) {
    /**
     * Given two strings, compute a score representing whether the internal
     * boundary falls on logical boundaries.
     * Scores range from 6 (best) to 0 (worst).
     * Closure, but does not reference any external variables.
     * [one] the first string.
     * [two] the second string.
     * Returns the score.
     */
    int _diff_cleanupSemanticScore(String one, String two) {
      if (one.isEmpty || two.isEmpty) {
        // Edges are the best.
        return 6;
      }

      // Each port of this function behaves slightly differently due to
      // subtle differences in each language's definition of things like
      // 'whitespace'.  Since this function's purpose is largely cosmetic,
      // the choice has been made to use each language's native features
      // rather than force total conformity.
      String char1 = one[one.length - 1];
      String char2 = two[0];
      bool nonAlphaNumeric1 = char1.contains(nonAlphaNumericRegex_);
      bool nonAlphaNumeric2 = char2.contains(nonAlphaNumericRegex_);
      bool whitespace1 = nonAlphaNumeric1 && char1.contains(whitespaceRegex_);
      bool whitespace2 = nonAlphaNumeric2 && char2.contains(whitespaceRegex_);
      bool lineBreak1 = whitespace1 && char1.contains(linebreakRegex_);
      bool lineBreak2 = whitespace2 && char2.contains(linebreakRegex_);
      bool blankLine1 = lineBreak1 && one.contains(blanklineEndRegex_);
      bool blankLine2 = lineBreak2 && two.contains(blanklineStartRegex_);

      if (blankLine1 || blankLine2) {
        // Five points for blank lines.
        return 5;
      } else if (lineBreak1 || lineBreak2) {
        // Four points for line breaks.
        return 4;
      } else if (nonAlphaNumeric1 && !whitespace1 && whitespace2) {
        // Three points for end of sentences.
        return 3;
      } else if (whitespace1 || whitespace2) {
        // Two points for whitespace.
        return 2;
      } else if (nonAlphaNumeric1 || nonAlphaNumeric2) {
        // One point for non-alphanumeric.
        return 1;
      }
      return 0;
    }

    int pointer = 1;
    // Intentionally ignore the first and last element (don't need checking).
    while (pointer < diffs.length - 1) {
      if (diffs[pointer - 1].operation == Operation.equal &&
          diffs[pointer + 1].operation == Operation.equal) {
        // This is a single edit surrounded by equalities.
        String equality1 = diffs[pointer - 1].text;
        String edit = diffs[pointer].text;
        String equality2 = diffs[pointer + 1].text;

        // First, shift the edit as far left as possible.
        int commonOffset = diff_commonSuffix(equality1, edit);
        if (commonOffset != 0) {
          String commonString = edit.substring(edit.length - commonOffset);
          equality1 = equality1.substring(0, equality1.length - commonOffset);
          edit = commonString + edit.substring(0, edit.length - commonOffset);
          equality2 = commonString + equality2;
        }

        // Second, step character by character right, looking for the best fit.
        String bestEquality1 = equality1;
        String bestEdit = edit;
        String bestEquality2 = equality2;
        int bestScore = _diff_cleanupSemanticScore(equality1, edit) +
            _diff_cleanupSemanticScore(edit, equality2);
        while (edit.isNotEmpty &&
            equality2.isNotEmpty &&
            edit[0] == equality2[0]) {
          equality1 = equality1 + edit[0];
          edit = edit.substring(1) + equality2[0];
          equality2 = equality2.substring(1);
          int score = _diff_cleanupSemanticScore(equality1, edit) +
              _diff_cleanupSemanticScore(edit, equality2);
          // The >= encourages trailing rather than leading whitespace on edits.
          if (score >= bestScore) {
            bestScore = score;
            bestEquality1 = equality1;
            bestEdit = edit;
            bestEquality2 = equality2;
          }
        }

        if (diffs[pointer - 1].text != bestEquality1) {
          // We have an improvement, save it back to the diff.
          if (bestEquality1.isNotEmpty) {
            diffs[pointer - 1].text = bestEquality1;
          } else {
            diffs.removeAt(pointer - 1);
            pointer--;
          }
          diffs[pointer].text = bestEdit;
          if (bestEquality2.isNotEmpty) {
            diffs[pointer + 1].text = bestEquality2;
          } else {
            diffs.removeAt(pointer + 1);
            pointer--;
          }
        }
      }
      pointer++;
    }
  }

  /// Hack to allow unit tests to call private method.  Do not use.
  void test_diff_cleanupSemanticLossless(List<Diff> diffs) {
    _diff_cleanupSemanticLossless(diffs);
  }

  // Define some regex patterns for matching boundaries.
  RegExp nonAlphaNumericRegex_ = new RegExp(r'[^a-zA-Z0-9]');
  RegExp whitespaceRegex_ = new RegExp(r'\s');
  RegExp linebreakRegex_ = new RegExp(r'[\r\n]');
  RegExp blanklineEndRegex_ = new RegExp(r'\n\r?\n$');
  RegExp blanklineStartRegex_ = new RegExp(r'^\r?\n\r?\n');

  /// Reduce the number of edits by eliminating operationally trivial equalities.
  /// [diffs] is a List of Diff objects.
  void diff_cleanupEfficiency(List<Diff> diffs) {
    bool changes = false;
    // Stack of indices where equalities are found.
    final equalities = <int>[];
    // Always equal to diffs[equalities.last()].text
    String? lastEquality = null;
    int pointer = 0; // Index of current position.
    // Is there an insertion operation before the last equality.
    bool preIns = false;
    // Is there a deletion operation before the last equality.
    bool preDel = false;
    // Is there an insertion operation after the last equality.
    bool postIns = false;
    // Is there a deletion operation after the last equality.
    bool postDel = false;
    while (pointer < diffs.length) {
      if (diffs[pointer].operation == Operation.equal) {
        // Equality found.
        if (diffs[pointer].text.length < Diff_EditCost &&
            (postIns || postDel)) {
          // Candidate found.
          equalities.add(pointer);
          preIns = postIns;
          preDel = postDel;
          lastEquality = diffs[pointer].text;
        } else {
          // Not a candidate, and can never become one.
          equalities.clear();
          lastEquality = null;
        }
        postIns = postDel = false;
      } else {
        // An insertion or deletion.
        if (diffs[pointer].operation == Operation.delete) {
          postDel = true;
        } else {
          postIns = true;
        }
        /*
         * Five types to be split:
         * <ins>A</ins><del>B</del>XY<ins>C</ins><del>D</del>
         * <ins>A</ins>X<ins>C</ins><del>D</del>
         * <ins>A</ins><del>B</del>X<ins>C</ins>
         * <ins>A</del>X<ins>C</ins><del>D</del>
         * <ins>A</ins><del>B</del>X<del>C</del>
         */
        if (lastEquality != null &&
            ((preIns && preDel && postIns && postDel) ||
                ((lastEquality.length < Diff_EditCost / 2) &&
                    ((preIns ? 1 : 0) +
                            (preDel ? 1 : 0) +
                            (postIns ? 1 : 0) +
                            (postDel ? 1 : 0)) ==
                        3))) {
          // Duplicate record.
          diffs.insert(
              equalities.last, new Diff(Operation.delete, lastEquality));
          // Change second copy to insert.
          diffs[equalities.last + 1].operation = Operation.insert;
          equalities.removeLast(); // Throw away the equality we just deleted.
          lastEquality = null;
          if (preIns && preDel) {
            // No changes made which could affect previous entry, keep going.
            postIns = postDel = true;
            equalities.clear();
          } else {
            if (equalities.isNotEmpty) {
              equalities.removeLast();
            }
            pointer = equalities.isEmpty ? -1 : equalities.last;
            postIns = postDel = false;
          }
          changes = true;
        }
      }
      pointer++;
    }

    if (changes) {
      diff_cleanupMerge(diffs);
    }
  }

  /// Reorder and merge like edit sections.  Merge equalities.
  /// Any edit section can move as long as it doesn't cross an equality.
  /// [diffs] is a List of Diff objects.
  void diff_cleanupMerge(List<Diff> diffs) {
    diffs.add(new Diff(Operation.equal, '')); // Add a dummy entry at the end.
    int pointer = 0;
    int countDelete = 0;
    int countInsert = 0;
    String textDelete = '';
    String textInsert = '';
    int commonlength;
    while (pointer < diffs.length) {
      switch (diffs[pointer].operation) {
        case Operation.insert:
          countInsert++;
          textInsert += diffs[pointer].text;
          pointer++;
          break;
        case Operation.delete:
          countDelete++;
          textDelete += diffs[pointer].text;
          pointer++;
          break;
        case Operation.equal:
          // Upon reaching an equality, check for prior redundancies.
          if (countDelete + countInsert > 1) {
            if (countDelete != 0 && countInsert != 0) {
              // Factor out any common prefixies.
              commonlength = diff_commonPrefix(textInsert, textDelete);
              if (commonlength != 0) {
                if ((pointer - countDelete - countInsert) > 0 &&
                    diffs[pointer - countDelete - countInsert - 1].operation ==
                        Operation.equal) {
                  final i = pointer - countDelete - countInsert - 1;
                  diffs[i].text =
                      diffs[i].text + textInsert.substring(0, commonlength);
                } else {
                  diffs.insert(
                      0,
                      new Diff(Operation.equal,
                          textInsert.substring(0, commonlength)));
                  pointer++;
                }
                textInsert = textInsert.substring(commonlength);
                textDelete = textDelete.substring(commonlength);
              }

              // Factor out any common suffixies.
              commonlength = diff_commonSuffix(textInsert, textDelete);
              if (commonlength != 0) {
                diffs[pointer].text =
                    textInsert.substring(textInsert.length - commonlength) +
                        diffs[pointer].text;
                textInsert =
                    textInsert.substring(0, textInsert.length - commonlength);
                textDelete =
                    textDelete.substring(0, textDelete.length - commonlength);
              }
            }
            // Delete the offending records and add the merged ones.
            pointer -= countDelete + countInsert;
            diffs.removeRange(pointer, pointer + countDelete + countInsert);
            if (textDelete.isNotEmpty) {
              diffs.insert(pointer, new Diff(Operation.delete, textDelete));
              pointer++;
            }
            if (textInsert.isNotEmpty) {
              diffs.insert(pointer, new Diff(Operation.insert, textInsert));
              pointer++;
            }
            pointer++;
          } else if (pointer != 0 &&
              diffs[pointer - 1].operation == Operation.equal) {
            // Merge this equality with the previous one.
            diffs[pointer - 1].text =
                diffs[pointer - 1].text + diffs[pointer].text;
            diffs.removeAt(pointer);
          } else {
            pointer++;
          }
          countInsert = 0;
          countDelete = 0;
          textDelete = '';
          textInsert = '';
          break;
      }
    }
    if (diffs.last.text.isEmpty) {
      diffs.removeLast(); // Remove the dummy entry at the end.
    }

    // Second pass: look for single edits surrounded on both sides by equalities
    // which can be shifted sideways to eliminate an equality.
    // e.g: A<ins>BA</ins>C -> <ins>AB</ins>AC
    bool changes = false;
    pointer = 1;
    // Intentionally ignore the first and last element (don't need checking).
    while (pointer < diffs.length - 1) {
      if (diffs[pointer - 1].operation == Operation.equal &&
          diffs[pointer + 1].operation == Operation.equal) {
        // This is a single edit surrounded by equalities.
        if (diffs[pointer].text.endsWith(diffs[pointer - 1].text)) {
          // Shift the edit over the previous equality.
          diffs[pointer].text = diffs[pointer - 1].text +
              diffs[pointer].text.substring(0,
                  diffs[pointer].text.length - diffs[pointer - 1].text.length);
          diffs[pointer + 1].text =
              diffs[pointer - 1].text + diffs[pointer + 1].text;
          diffs.removeAt(pointer - 1);
          changes = true;
        } else if (diffs[pointer].text.startsWith(diffs[pointer + 1].text)) {
          // Shift the edit over the next equality.
          diffs[pointer - 1].text =
              diffs[pointer - 1].text + diffs[pointer + 1].text;
          diffs[pointer].text =
              diffs[pointer].text.substring(diffs[pointer + 1].text.length) +
                  diffs[pointer + 1].text;
          diffs.removeAt(pointer + 1);
          changes = true;
        }
      }
      pointer++;
    }
    // If shifts were made, the diff needs reordering and another shift sweep.
    if (changes) {
      diff_cleanupMerge(diffs);
    }
  }

  /// loc is a location in text1, compute and return the equivalent location in
  /// text2.
  /// e.g. "The cat" vs "The big cat", 1->1, 5->8
  /// [diffs] is a List of Diff objects.
  /// [loc] is the location within text1.
  /// Returns the location within text2.
  int diff_xIndex(List<Diff> diffs, int loc) {
    int chars1 = 0;
    int chars2 = 0;
    int lastChars1 = 0;
    int lastChars2 = 0;
    Diff? lastDiff = null;
    for (Diff aDiff in diffs) {
      if (aDiff.operation != Operation.insert) {
        // Equality or deletion.
        chars1 += aDiff.text.length;
      }
      if (aDiff.operation != Operation.delete) {
        // Equality or insertion.
        chars2 += aDiff.text.length;
      }
      if (chars1 > loc) {
        // Overshot the location.
        lastDiff = aDiff;
        break;
      }
      lastChars1 = chars1;
      lastChars2 = chars2;
    }
    if (lastDiff != null && lastDiff.operation == Operation.delete) {
      // The location was deleted.
      return lastChars2;
    }
    // Add the remaining character length.
    return lastChars2 + (loc - lastChars1);
  }

  /// Convert a Diff list into a pretty HTML report.
  /// [diffs] is a List of Diff objects.
  /// Returns an HTML representation.
  String diff_prettyHtml(List<Diff> diffs) {
    final html = new StringBuffer();
    for (Diff aDiff in diffs) {
      String text = aDiff.text
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('\n', '&para;<br>');
      switch (aDiff.operation) {
        case Operation.insert:
          html.write('<ins style="background:#e6ffe6;">');
          html.write(text);
          html.write('</ins>');
          break;
        case Operation.delete:
          html.write('<del style="background:#ffe6e6;">');
          html.write(text);
          html.write('</del>');
          break;
        case Operation.equal:
          html.write('<span>');
          html.write(text);
          html.write('</span>');
          break;
      }
    }
    return html.toString();
  }

  /// Compute and return the source text (all equalities and deletions).
  /// [diffs] is a List of Diff objects.
  /// Returns the source text.
  String diff_text1(List<Diff> diffs) {
    final text = new StringBuffer();
    for (Diff aDiff in diffs) {
      if (aDiff.operation != Operation.insert) {
        text.write(aDiff.text);
      }
    }
    return text.toString();
  }

  /// Compute and return the destination text (all equalities and insertions).
  /// [diffs] is a List of Diff objects.
  /// Returns the destination text.
  String diff_text2(List<Diff> diffs) {
    final text = new StringBuffer();
    for (Diff aDiff in diffs) {
      if (aDiff.operation != Operation.delete) {
        text.write(aDiff.text);
      }
    }
    return text.toString();
  }

  /// Compute the Levenshtein distance; the number of inserted, deleted or
  /// substituted characters.
  /// [diffs] is a List of Diff objects.
  /// Returns the number of changes.
  int diff_levenshtein(List<Diff> diffs) {
    int levenshtein = 0;
    int insertions = 0;
    int deletions = 0;
    for (Diff aDiff in diffs) {
      switch (aDiff.operation) {
        case Operation.insert:
          insertions += aDiff.text.length;
          break;
        case Operation.delete:
          deletions += aDiff.text.length;
          break;
        case Operation.equal:
          // A deletion and an insertion is one substitution.
          levenshtein += max(insertions, deletions);
          insertions = 0;
          deletions = 0;
          break;
      }
    }
    levenshtein += max(insertions, deletions);
    return levenshtein;
  }

  /// Crush the diff into an encoded string which describes the operations
  /// required to transform text1 into text2.
  /// E.g. =3\t-2\t+ing  -> Keep 3 chars, delete 2 chars, insert 'ing'.
  /// Operations are tab-separated.  Inserted text is escaped using %xx notation.
  /// [diffs] is a List of Diff objects.
  /// Returns the delta text.
  String diff_toDelta(List<Diff> diffs) {
    final text = new StringBuffer();
    for (Diff aDiff in diffs) {
      switch (aDiff.operation) {
        case Operation.insert:
          text.write('+');
          text.write(Uri.encodeFull(aDiff.text));
          text.write('\t');
          break;
        case Operation.delete:
          text.write('-');
          text.write(aDiff.text.length);
          text.write('\t');
          break;
        case Operation.equal:
          text.write('=');
          text.write(aDiff.text.length);
          text.write('\t');
          break;
      }
    }
    String delta = text.toString();
    if (delta.isNotEmpty) {
      // Strip off trailing tab character.
      delta = delta.substring(0, delta.length - 1);
    }
    return delta.replaceAll('%20', ' ');
  }

  /// Given the original text1, and an encoded string which describes the
  /// operations required to transform text1 into text2, compute the full diff.
  /// [text1] is the source string for the diff.
  /// [delta] is the delta text.
  /// Returns a List of Diff objects or null if invalid.
  /// Throws ArgumentError if invalid input.
  List<Diff> diff_fromDelta(String text1, String delta) {
    final diffs = <Diff>[];
    int pointer = 0; // Cursor in text1
    final tokens = delta.split('\t');
    for (String token in tokens) {
      if (token.length == 0) {
        // Blank tokens are ok (from a trailing \t).
        continue;
      }
      // Each token begins with a one character parameter which specifies the
      // operation of this token (delete, insert, equality).
      String param = token.substring(1);
      switch (token[0]) {
        case '+':
          // decode would change all "+" to " "
          param = param.replaceAll('+', '%2B');
          try {
            param = Uri.decodeFull(param);
          } on ArgumentError {
            // Malformed URI sequence.
            throw new ArgumentError('Illegal escape in diff_fromDelta: $param');
          }
          diffs.add(new Diff(Operation.insert, param));
          break;
        case '-':
        // Fall through.
        case '=':
          int n;
          try {
            n = int.parse(param);
          } on FormatException {
            throw new ArgumentError('Invalid number in diff_fromDelta: $param');
          }
          if (n < 0) {
            throw new ArgumentError(
                'Negative number in diff_fromDelta: $param');
          }
          String text;
          try {
            text = text1.substring(pointer, pointer += n);
          } on RangeError {
            throw new ArgumentError('Delta length ($pointer)'
                ' larger than source text length (${text1.length}).');
          }
          if (token[0] == '=') {
            diffs.add(new Diff(Operation.equal, text));
          } else {
            diffs.add(new Diff(Operation.delete, text));
          }
          break;
        default:
          // Anything else is an error.
          throw new ArgumentError(
              'Invalid diff operation in diff_fromDelta: ${token[0]}');
      }
    }
    if (pointer != text1.length) {
      throw new ArgumentError('Delta length ($pointer)'
          ' smaller than source text length (${text1.length}).');
    }
    return diffs;
  }

  //  MATCH FUNCTIONS

  /// Locate the best instance of 'pattern' in 'text' near 'loc'.
  /// Returns -1 if no match found.
  /// [text] is the text to search.
  /// [pattern] is the pattern to search for.
  /// [loc] is the location to search around.
  /// Returns the best match index or -1.
  int match_main(String text, String pattern, int loc) {
    // Check for null inputs.
    if (text == null || pattern == null) {
      throw new ArgumentError('Null inputs. (match_main)');
    }

    loc = max(0, min(loc, text.length));
    if (text == pattern) {
      // Shortcut (potentially not guaranteed by the algorithm)
      return 0;
    } else if (text.length == 0) {
      // Nothing to match.
      return -1;
    } else if (loc + pattern.length <= text.length &&
        text.substring(loc, loc + pattern.length) == pattern) {
      // Perfect match at the perfect spot!  (Includes case of null pattern)
      return loc;
    } else {
      // Do a fuzzy compare.
      return _match_bitap(text, pattern, loc);
    }
  }

  /// Locate the best instance of 'pattern' in 'text' near 'loc' using the
  /// Bitap algorithm.  Returns -1 if no match found.
  /// [text] is the the text to search.
  /// [pattern] is the pattern to search for.
  /// [loc] is the location to search around.
  /// Returns the best match index or -1.
  int _match_bitap(String text, String pattern, int loc) {
    if (Match_MaxBits != 0 && pattern.length > Match_MaxBits) {
      throw new Exception('Pattern too long for this application.');
    }
    // Initialise the alphabet.
    Map<String, int> s = _match_alphabet(pattern);

    // Highest score beyond which we give up.
    double scoreThreshold = Match_Threshold;
    // Is there a nearby exact match? (speedup)
    int bestLoc = text.indexOf(pattern, loc);
    if (bestLoc != -1) {
      scoreThreshold =
          min(_match_bitapScore(0, bestLoc, loc, pattern), scoreThreshold);
      // What about in the other direction? (speedup)
      bestLoc = text.lastIndexOf(pattern, loc + pattern.length);
      if (bestLoc != -1) {
        scoreThreshold =
            min(_match_bitapScore(0, bestLoc, loc, pattern), scoreThreshold);
      }
    }

    // Initialise the bit arrays.
    final matchmask = 1 << (pattern.length - 1);
    bestLoc = -1;

    int binMin, binMid;
    int binMax = pattern.length + text.length;
    List<int> lastRd = [];
    for (int d = 0; d < pattern.length; d++) {
      // Scan for the best match; each iteration allows for one more error.
      // Run a binary search to determine how far from 'loc' we can stray at
      // this error level.
      binMin = 0;
      binMid = binMax;
      while (binMin < binMid) {
        if (_match_bitapScore(d, loc + binMid, loc, pattern) <=
            scoreThreshold) {
          binMin = binMid;
        } else {
          binMax = binMid;
        }
        binMid = ((binMax - binMin) / 2 + binMin).toInt();
      }
      // Use the result from this iteration as the maximum for the next.
      binMax = binMid;
      int start = max(1, loc - binMid + 1);
      int finish = min(loc + binMid, text.length) + pattern.length;

      final rd = List.filled(finish + 2, 0, growable: false);
      rd[finish + 1] = (1 << d) - 1;
      for (int j = finish; j >= start; j--) {
        int charMatch;
        if (text.length <= j - 1 || !s.containsKey(text[j - 1])) {
          // Out of range.
          charMatch = 0;
        } else {
          charMatch = s[text[j - 1]]!;
        }
        if (d == 0) {
          // First pass: exact match.
          rd[j] = ((rd[j + 1] << 1) | 1) & charMatch;
        } else {
          // Subsequent passes: fuzzy match.
          rd[j] = ((rd[j + 1] << 1) | 1) & charMatch |
              (((lastRd[j + 1] | lastRd[j]) << 1) | 1) |
              lastRd[j + 1];
        }
        if ((rd[j] & matchmask) != 0) {
          double score = _match_bitapScore(d, j - 1, loc, pattern);
          // This match will almost certainly be better than any existing
          // match.  But check anyway.
          if (score <= scoreThreshold) {
            // Told you so.
            scoreThreshold = score;
            bestLoc = j - 1;
            if (bestLoc > loc) {
              // When passing loc, don't exceed our current distance from loc.
              start = max(1, 2 * loc - bestLoc);
            } else {
              // Already passed loc, downhill from here on in.
              break;
            }
          }
        }
      }
      if (_match_bitapScore(d + 1, loc, loc, pattern) > scoreThreshold) {
        // No hope for a (better) match at greater error levels.
        break;
      }
      lastRd = rd;
    }
    return bestLoc;
  }

  /// Hack to allow unit tests to call private method.  Do not use.
  int test_match_bitap(String text, String pattern, int loc) {
    return _match_bitap(text, pattern, loc);
  }

  /// Compute and return the score for a match with e errors and x location.
  /// [e] is the number of errors in match.
  /// [x] is the location of match.
  /// [loc] is the expected location of match.
  /// [pattern] is the pattern being sought.
  /// Returns the overall score for match (0.0 = good, 1.0 = bad).
  double _match_bitapScore(int e, int x, int loc, String pattern) {
    final accuracy = e / pattern.length;
    final proximity = (loc - x).abs();
    if (Match_Distance == 0) {
      // Dodge divide by zero error.
      return proximity == 0 ? accuracy : 1.0;
    }
    return accuracy + proximity / Match_Distance;
  }

  /// Initialise the alphabet for the Bitap algorithm.
  /// [pattern] is the the text to encode.
  /// Returns a Map of character locations.
  Map<String, int> _match_alphabet(String pattern) {
    final s = new HashMap<String, int>();
    for (int i = 0; i < pattern.length; i++) {
      s[pattern[i]] = 0;
    }
    for (int i = 0; i < pattern.length; i++) {
      s[pattern[i]] = s[pattern[i]]! | (1 << (pattern.length - i - 1));
    }
    return s;
  }

  /// Hack to allow unit tests to call private method.  Do not use.
  Map<String, int> test_match_alphabet(String pattern) {
    return _match_alphabet(pattern);
  }

  //  PATCH FUNCTIONS

  /// Increase the context until it is unique,
  /// but don't let the pattern expand beyond Match_MaxBits.
  /// [patch] is the phe patch to grow.
  /// [text] is the source text.
  void _patch_addContext(Patch patch, String text) {
    if (text.isEmpty) {
      return;
    }
    String pattern =
        text.substring(patch.start2!, patch.start2! + patch.length1);
    int padding = 0;

    // Look for the first and last matches of pattern in text.  If two different
    // matches are found, increase the pattern length.
    while (text.indexOf(pattern) != text.lastIndexOf(pattern) &&
        pattern.length < Match_MaxBits - Patch_Margin - Patch_Margin) {
      padding += Patch_Margin;
      pattern = text.substring(max(0, patch.start2! - padding),
          min(text.length, patch.start2! + patch.length1 + padding));
    }
    // Add one chunk for good luck.
    padding += Patch_Margin;

    // Add the prefix.
    final prefix =
        text.substring(max(0, patch.start2! - padding), patch.start2);
    if (prefix.isNotEmpty) {
      patch.diffs.insert(0, new Diff(Operation.equal, prefix));
    }
    // Add the suffix.
    final suffix = text.substring(patch.start2! + patch.length1,
        min(text.length, patch.start2! + patch.length1 + padding));
    if (suffix.isNotEmpty) {
      patch.diffs.add(new Diff(Operation.equal, suffix));
    }

    // Roll back the start points.
    patch.start1 = patch.start1! - prefix.length;
    patch.start2 = patch.start2! - prefix.length;
    // Extend the lengths.
    patch.length1 += prefix.length + suffix.length;
    patch.length2 += prefix.length + suffix.length;
  }

  /// Hack to allow unit tests to call private method.  Do not use.
  void test_patch_addContext(Patch patch, String text) {
    _patch_addContext(patch, text);
  }

  /// Compute a list of patches to turn text1 into text2.
  /// Use diffs if provided, otherwise compute it ourselves.
  /// There are four ways to call this function, depending on what data is
  /// available to the caller:
  /// Method 1:
  /// [a] = text1, [optB] = text2
  /// Method 2:
  /// [a] = diffs
  /// Method 3 (optimal):
  /// [a] = text1, [optB] = diffs
  /// Method 4 (deprecated, use method 3):
  /// [a] = text1, [optB] = text2, [optC] = diffs
  /// Returns a List of Patch objects.
  List<Patch> patch_make(a, [optB, optC]) {
    String text1;
    List<Diff> diffs;
    if (a is String && optB is String && optC == null) {
      // Method 1: text1, text2
      // Compute diffs from text1 and text2.
      text1 = a;
      diffs = diff_main(text1, optB, true);
      if (diffs.length > 2) {
        diff_cleanupSemantic(diffs);
        diff_cleanupEfficiency(diffs);
      }
    } else if (a is List && optB == null && optC == null) {
      // Method 2: diffs
      // Compute text1 from diffs.
      diffs = a as List<Diff>;
      text1 = diff_text1(diffs);
    } else if (a is String && optB is List && optC == null) {
      // Method 3: text1, diffs
      text1 = a;
      diffs = optB as List<Diff>;
    } else if (a is String && optB is String && optC is List) {
      // Method 4: text1, text2, diffs
      // text2 is not used.
      text1 = a;
      diffs = optC as List<Diff>;
    } else {
      throw new ArgumentError('Unknown call format to patch_make.');
    }

    final patches = <Patch>[];
    if (diffs.isEmpty) {
      return patches; // Get rid of the null case.
    }
    Patch patch = new Patch();
    int charCount1 = 0; // Number of characters into the text1 string.
    int charCount2 = 0; // Number of characters into the text2 string.
    // Start with text1 (prepatch_text) and apply the diffs until we arrive at
    // text2 (postpatch_text). We recreate the patches one by one to determine
    // context info.
    String prepatchText = text1;
    String postpatchText = text1;
    for (Diff aDiff in diffs) {
      if (patch.diffs.isEmpty && aDiff.operation != Operation.equal) {
        // A new patch starts here.
        patch.start1 = charCount1;
        patch.start2 = charCount2;
      }

      switch (aDiff.operation) {
        case Operation.insert:
          patch.diffs.add(aDiff);
          patch.length2 += aDiff.text.length;
          postpatchText = postpatchText.substring(0, charCount2) +
              aDiff.text +
              postpatchText.substring(charCount2);
          break;
        case Operation.delete:
          patch.length1 += aDiff.text.length;
          patch.diffs.add(aDiff);
          postpatchText = postpatchText.substring(0, charCount2) +
              postpatchText.substring(charCount2 + aDiff.text.length);
          break;
        case Operation.equal:
          if (aDiff.text.length <= 2 * Patch_Margin &&
              patch.diffs.isNotEmpty &&
              aDiff != diffs.last) {
            // Small equality inside a patch.
            patch.diffs.add(aDiff);
            patch.length1 += aDiff.text.length;
            patch.length2 += aDiff.text.length;
          }

          if (aDiff.text.length >= 2 * Patch_Margin) {
            // Time for a new patch.
            if (patch.diffs.isNotEmpty) {
              _patch_addContext(patch, prepatchText);
              patches.add(patch);
              patch = new Patch();
              // Unlike Unidiff, our patch lists have a rolling context.
              // https://github.com/google/diff-match-patch/wiki/Unidiff
              // Update prepatch text & pos to reflect the application of the
              // just completed patch.
              prepatchText = postpatchText;
              charCount1 = charCount2;
            }
          }
          break;
      }

      // Update the current character count.
      if (aDiff.operation != Operation.insert) {
        charCount1 += aDiff.text.length;
      }
      if (aDiff.operation != Operation.delete) {
        charCount2 += aDiff.text.length;
      }
    }
    // Pick up the leftover patch if not empty.
    if (patch.diffs.isNotEmpty) {
      _patch_addContext(patch, prepatchText);
      patches.add(patch);
    }

    return patches;
  }

  /// Given an array of patches, return another array that is identical.
  /// [patches] is a List of Patch objects.
  /// Returns a List of Patch objects.
  List<Patch> patch_deepCopy(List<Patch> patches) {
    final patchesCopy = <Patch>[];
    for (Patch aPatch in patches) {
      final patchCopy = new Patch();
      for (Diff aDiff in aPatch.diffs) {
        patchCopy.diffs.add(new Diff(aDiff.operation, aDiff.text));
      }
      patchCopy.start1 = aPatch.start1;
      patchCopy.start2 = aPatch.start2;
      patchCopy.length1 = aPatch.length1;
      patchCopy.length2 = aPatch.length2;
      patchesCopy.add(patchCopy);
    }
    return patchesCopy;
  }

  /// Merge a set of patches onto the text.  Return a patched text, as well
  /// as an array of true/false values indicating which patches were applied.
  /// [patches] is a List of Patch objects
  /// [text] is the old text.
  /// Returns a two element List, containing the new text and a List of
  ///      bool values.
  List patch_apply(List<Patch> patches, String text) {
    if (patches.isEmpty) {
      return [text, []];
    }

    // Deep copy the patches so that no changes are made to originals.
    patches = patch_deepCopy(patches);

    final nullPadding = patch_addPadding(patches);
    text = nullPadding + text + nullPadding;
    patch_splitMax(patches);

    int x = 0;
    // delta keeps track of the offset between the expected and actual location
    // of the previous patch.  If there are patches expected at positions 10 and
    // 20, but the first patch was found at 12, delta is 2 and the second patch
    // has an effective expected position of 22.
    int delta = 0;
    final results = List.filled(patches.length, false, growable: false);
    for (Patch aPatch in patches) {
      int expectedLoc = aPatch.start2! + delta;
      String text1 = diff_text1(aPatch.diffs);
      int startLoc;
      int endLoc = -1;
      if (text1.length > Match_MaxBits) {
        // patch_splitMax will only provide an oversized pattern in the case of
        // a monster delete.
        startLoc =
            match_main(text, text1.substring(0, Match_MaxBits), expectedLoc);
        if (startLoc != -1) {
          endLoc = match_main(
              text,
              text1.substring(text1.length - Match_MaxBits),
              expectedLoc + text1.length - Match_MaxBits);
          if (endLoc == -1 || startLoc >= endLoc) {
            // Can't find valid trailing context.  Drop this patch.
            startLoc = -1;
          }
        }
      } else {
        startLoc = match_main(text, text1, expectedLoc);
      }
      if (startLoc == -1) {
        // No match found.  :(
        results[x] = false;
        // Subtract the delta for this failed patch from subsequent patches.
        delta -= aPatch.length2 - aPatch.length1;
      } else {
        // Found a match.  :)
        results[x] = true;
        delta = startLoc - expectedLoc;
        String text2;
        if (endLoc == -1) {
          text2 = text.substring(
              startLoc, min(startLoc + text1.length, text.length));
        } else {
          text2 = text.substring(
              startLoc, min(endLoc + Match_MaxBits, text.length));
        }
        if (text1 == text2) {
          // Perfect match, just shove the replacement text in.
          text = text.substring(0, startLoc) +
              diff_text2(aPatch.diffs) +
              text.substring(startLoc + text1.length);
        } else {
          // Imperfect match.  Run a diff to get a framework of equivalent
          // indices.
          final diffs = diff_main(text1, text2, false);
          if (text1.length > Match_MaxBits &&
              diff_levenshtein(diffs) / text1.length > Patch_DeleteThreshold) {
            // The end points match, but the content is unacceptably bad.
            results[x] = false;
          } else {
            _diff_cleanupSemanticLossless(diffs);
            int index1 = 0;
            for (Diff aDiff in aPatch.diffs) {
              if (aDiff.operation != Operation.equal) {
                int index2 = diff_xIndex(diffs, index1);
                if (aDiff.operation == Operation.insert) {
                  // Insertion
                  text = text.substring(0, startLoc + index2) +
                      aDiff.text +
                      text.substring(startLoc + index2);
                } else if (aDiff.operation == Operation.delete) {
                  // Deletion
                  text = text.substring(0, startLoc + index2) +
                      text.substring(startLoc +
                          diff_xIndex(diffs, index1 + aDiff.text.length));
                }
              }
              if (aDiff.operation != Operation.delete) {
                index1 += aDiff.text.length;
              }
            }
          }
        }
      }
      x++;
    }
    // Strip the padding off.
    text = text.substring(nullPadding.length, text.length - nullPadding.length);
    return [text, results];
  }

  /// Add some padding on text start and end so that edges can match something.
  /// Intended to be called only from within patch_apply.
  /// [patches] is a List of Patch objects.
  /// Returns the padding string added to each side.
  String patch_addPadding(List<Patch> patches) {
    final paddingLength = Patch_Margin;
    final paddingCodes = <int>[];
    for (int x = 1; x <= paddingLength; x++) {
      paddingCodes.add(x);
    }
    String nullPadding = new String.fromCharCodes(paddingCodes);

    // Bump all the patches forward.
    for (Patch aPatch in patches) {
      aPatch.start1 = aPatch.start1! + paddingLength;
      aPatch.start2 = aPatch.start2! + paddingLength;
    }

    // Add some padding on start of first diff.
    Patch patch = patches[0];
    List<Diff> diffs = patch.diffs;
    if (diffs.isEmpty || diffs[0].operation != Operation.equal) {
      // Add nullPadding equality.
      diffs.insert(0, new Diff(Operation.equal, nullPadding));
      patch.start1 = patch.start1! - paddingLength; // Should be 0.
      patch.start2 = patch.start2! - paddingLength; // Should be 0.
      patch.length1 += paddingLength;
      patch.length2 += paddingLength;
    } else if (paddingLength > diffs[0].text.length) {
      // Grow first equality.
      Diff firstDiff = diffs[0];
      int extraLength = paddingLength - firstDiff.text.length;
      firstDiff.text =
          nullPadding.substring(firstDiff.text.length) + firstDiff.text;
      patch.start1 = patch.start1! - extraLength;
      patch.start2 = patch.start2! - extraLength;
      patch.length1 += extraLength;
      patch.length2 += extraLength;
    }

    // Add some padding on end of last diff.
    patch = patches.last;
    diffs = patch.diffs;
    if (diffs.isEmpty || diffs.last.operation != Operation.equal) {
      // Add nullPadding equality.
      diffs.add(new Diff(Operation.equal, nullPadding));
      patch.length1 += paddingLength;
      patch.length2 += paddingLength;
    } else if (paddingLength > diffs.last.text.length) {
      // Grow last equality.
      Diff lastDiff = diffs.last;
      int extraLength = paddingLength - lastDiff.text.length;
      lastDiff.text = lastDiff.text + nullPadding.substring(0, extraLength);
      patch.length1 += extraLength;
      patch.length2 += extraLength;
    }

    return nullPadding;
  }

  /// Look through the patches and break up any which are longer than the
  /// maximum limit of the match algorithm.
  /// Intended to be called only from within patch_apply.
  /// [patches] is a List of Patch objects.
  patch_splitMax(List<Patch> patches) {
    final patchSize = Match_MaxBits;
    for (var x = 0; x < patches.length; x++) {
      if (patches[x].length1 <= patchSize) {
        continue;
      }
      Patch bigpatch = patches[x];
      // Remove the big old patch.
      patches.removeAt(x--);
      int? start1 = bigpatch.start1;
      int? start2 = bigpatch.start2;
      String precontext = '';
      while (bigpatch.diffs.isNotEmpty) {
        // Create one of several smaller patches.
        final patch = new Patch();
        bool empty = true;
        patch.start1 = start1! - precontext.length;
        patch.start2 = start2! - precontext.length;
        if (precontext.isNotEmpty) {
          patch.length1 = patch.length2 = precontext.length;
          patch.diffs.add(new Diff(Operation.equal, precontext));
        }
        while (bigpatch.diffs.isNotEmpty &&
            patch.length1 < patchSize - Patch_Margin) {
          Operation diffType = bigpatch.diffs[0].operation;
          String diffText = bigpatch.diffs[0].text;
          if (diffType == Operation.insert) {
            // Insertions are harmless.
            patch.length2 += diffText.length;
            start2 = start2! + diffText.length;
            patch.diffs.add(bigpatch.diffs[0]);
            bigpatch.diffs.removeAt(0);
            empty = false;
          } else if (diffType == Operation.delete &&
              patch.diffs.length == 1 &&
              patch.diffs[0].operation == Operation.equal &&
              diffText.length > 2 * patchSize) {
            // This is a large deletion.  Let it pass in one chunk.
            patch.length1 += diffText.length;
            start1 = start1! + diffText.length;
            empty = false;
            patch.diffs.add(new Diff(diffType, diffText));
            bigpatch.diffs.removeAt(0);
          } else {
            // Deletion or equality.  Only take as much as we can stomach.
            diffText = diffText.substring(0,
                min(diffText.length, patchSize - patch.length1 - Patch_Margin));
            patch.length1 += diffText.length;
            start1 = start1! + diffText.length;
            if (diffType == Operation.equal) {
              patch.length2 += diffText.length;
              start2 = start2! + diffText.length;
            } else {
              empty = false;
            }
            patch.diffs.add(new Diff(diffType, diffText));
            if (diffText == bigpatch.diffs[0].text) {
              bigpatch.diffs.removeAt(0);
            } else {
              bigpatch.diffs[0].text =
                  bigpatch.diffs[0].text.substring(diffText.length);
            }
          }
        }
        // Compute the head context for the next patch.
        precontext = diff_text2(patch.diffs);
        precontext =
            precontext.substring(max(0, precontext.length - Patch_Margin));
        // Append the end context for this patch.
        String postcontext;
        if (diff_text1(bigpatch.diffs).length > Patch_Margin) {
          postcontext = diff_text1(bigpatch.diffs).substring(0, Patch_Margin);
        } else {
          postcontext = diff_text1(bigpatch.diffs);
        }
        if (postcontext.isNotEmpty) {
          patch.length1 += postcontext.length;
          patch.length2 += postcontext.length;
          if (patch.diffs.isNotEmpty &&
              patch.diffs.last.operation == Operation.equal) {
            patch.diffs.last.text = patch.diffs.last.text + postcontext;
          } else {
            patch.diffs.add(new Diff(Operation.equal, postcontext));
          }
        }
        if (!empty) {
          patches.insert(++x, patch);
        }
      }
    }
  }

  /// Take a list of patches and return a textual representation.
  /// [patches] is a List of Patch objects.
  /// Returns a text representation of patches.
  String patch_toText(List<Patch> patches) {
    final text = new StringBuffer();
    text.writeAll(patches);
    return text.toString();
  }

  /// Parse a textual representation of patches and return a List of Patch
  /// objects.
  /// [textline] is a text representation of patches.
  /// Returns a List of Patch objects.
  /// Throws ArgumentError if invalid input.
  List<Patch> patch_fromText(String textline) {
    final patches = <Patch>[];
    if (textline.isEmpty) {
      return patches;
    }
    final text = textline.split('\n');
    int textPointer = 0;
    final patchHeader =
        new RegExp('^@@ -(\\d+),?(\\d*) \\+(\\d+),?(\\d*) @@\$');
    while (textPointer < text.length) {
      Match m = patchHeader.firstMatch(text[textPointer]) as Match;
      if (m == null) {
        throw new ArgumentError('Invalid patch string: ${text[textPointer]}');
      }
      final patch = new Patch();
      patches.add(patch);
      patch.start1 = int.parse(m.group(1)!);
      if (m.group(2)!.isEmpty) {
        patch.start1 = patch.start1! - 1;
        patch.length1 = 1;
      } else if (m.group(2) == '0') {
        patch.length1 = 0;
      } else {
        patch.start1 = patch.start1! - 1;
        patch.length1 = int.parse(m.group(2)!);
      }

      patch.start2 = int.parse(m.group(3)!);
      if (m.group(4)!.isEmpty) {
        patch.start2 = patch.start2! - 1;
        patch.length2 = 1;
      } else if (m.group(4) == '0') {
        patch.length2 = 0;
      } else {
        patch.start2 = patch.start2! - 1;
        patch.length2 = int.parse(m.group(4)!);
      }
      textPointer++;

      while (textPointer < text.length) {
        if (text[textPointer].isNotEmpty) {
          final sign = text[textPointer][0];
          String? line;
          try {
            line = Uri.decodeFull(text[textPointer].substring(1));
          } on ArgumentError {
            // Malformed URI sequence.
            throw new ArgumentError('Illegal escape in patch_fromText: $line');
          }
          if (sign == '-') {
            // Deletion.
            patch.diffs.add(new Diff(Operation.delete, line));
          } else if (sign == '+') {
            // Insertion.
            patch.diffs.add(new Diff(Operation.insert, line));
          } else if (sign == ' ') {
            // Minor equality.
            patch.diffs.add(new Diff(Operation.equal, line));
          } else if (sign == '@') {
            // Start of next patch.
            break;
          } else {
            // WTF?
            throw new ArgumentError('Invalid patch mode "$sign" in: $line');
          }
        }
        textPointer++;
      }
    }
    return patches;
  }
}
