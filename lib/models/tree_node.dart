class TreeNode {
  final String name;
  bool isFile;
  final Map<String, TreeNode> children = {};

  TreeNode(this.name, {this.isFile = false});
}

class TreeStats {
  int files = 0;
  int directories = 0;
}
