import 'Operation.enum.dart';

class Diff {
  Operation operation;

  String text;

  Diff(this.operation, this.text);

  String toString() {
    String prettyText = this.text.replaceAll('\n', '\u00b6');
    return 'Diff(${this.operation},"$prettyText")';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Diff &&
          runtimeType == other.runtimeType &&
          operation == other.operation &&
          text == other.text;
  @override
  int get hashCode => operation.hashCode ^ text.hashCode;
}
