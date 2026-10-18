One file per pull request: changelog.d/<PR number or short name>.md, e.g. 131-retranscribe.md.
Write only the sections that apply, with user-facing items:

### Repository
- ...

### macOS
- ...

### Windows
- ...

A release folds these files into CHANGELOG.md: python3 scripts/changelog.py release <version>
Check a file with: python3 scripts/changelog.py check
