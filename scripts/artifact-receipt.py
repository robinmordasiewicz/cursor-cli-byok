#!/usr/bin/env python3
"""Record the identity of an unsigned development build."""
import hashlib
import json
import pathlib
import sys

binary = pathlib.Path(sys.argv[1])
receipt = {
    "source_commit": sys.argv[2],
    "target": sys.argv[3],
    "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    "developer_id_signed": False,
    "apple_notarized": False,
}
binary.with_suffix(".receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
