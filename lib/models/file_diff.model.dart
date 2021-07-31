class FileDiff {
  late String file;
  late String patches;

  FileDiff.fromJson(Map<String, dynamic> json) {
    this.file = json['file'];
    this.patches = json['patches'];
  }
}
