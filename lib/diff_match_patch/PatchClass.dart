import 'DiffClass.dart';
import 'Operation.enum.dart';

class Patch {
  late List<Diff> diffs;
  late int? start1;
  late int? start2;
  int length1 = 0;
  int length2 = 0;

  Patch() {
    this.diffs = <Diff>[];
  }

  String toString() {
    String coords1, coords2;
    if (this.length1 == 0) {
      coords1 = '${this.start1},0';
    } else if (this.length1 == 1) {
      coords1 = (this.start1! + 1).toString();
    } else {
      coords1 = '${this.start1! + 1},${this.length1}';
    }
    if (this.length2 == 0) {
      coords2 = '${this.start2},0';
    } else if (this.length2 == 1) {
      coords2 = (this.start2! + 1).toString();
    } else {
      coords2 = '${this.start2! + 1},${this.length2}';
    }
    final text = new StringBuffer('@@ -$coords1 +$coords2 @@\n');
    for (Diff aDiff in this.diffs) {
      switch (aDiff.operation) {
        case Operation.insert:
          text.write('+');
          break;
        case Operation.delete:
          text.write('-');
          break;
        case Operation.equal:
          text.write(' ');
          break;
      }
      text.write(Uri.encodeFull(aDiff.text));
      text.write('\n');
    }
    return text.toString().replaceAll('%20', ' ');
  }
}
