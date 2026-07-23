# Sonic Annotator (local dependency)

`sonic-annotator` is a local native executable used by the optional fast Vamp
pYIN engine. It is not committed to Git because it is platform-specific.

Install the official macOS binary as:

```text
tools/sonic-annotator/sonic-annotator
```

The corresponding Vamp pYIN plugin must be installed in the user's macOS Vamp
plugin directory. The local app reports a clear error if either dependency is
missing.
