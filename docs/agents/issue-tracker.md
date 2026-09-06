# Issue tracker

This project uses [GitHub Issues](https://github.com/tmmywatsn/t3notch/issues).
References such as `#123` refer to `tmmywatsn/t3notch` unless another repository is specified.

For a review, use the linked issue as the spec and read its discussion:

```sh
gh issue view 123 --repo tmmywatsn/t3notch --json title,body,comments,url
```

An explicitly provided task description or file can also be the spec. For uncommitted work, compare
the working tree with the identified baseline and include untracked source files; a three-dot
commit comparison alone does not include them. State the baseline and spec source in the review.

Creating or commenting on issues and pull requests is a separate action from reading them. Do it
only when requested as part of the task. Never include private chats, local databases or credentials.
