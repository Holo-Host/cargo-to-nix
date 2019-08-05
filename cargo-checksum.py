#!/usr/bin/env python3

import hashlib
import json
import os
import sys

BLOCKSIZE = 65536
data = {"files": {}}

for root, subdirs, files in os.walk('.'):
    for file in files:
        hash = hashlib.sha256()
        path = os.path.relpath(os.path.join(root, file), '.')
        with open(path, 'rb') as f:
            while True:
                buf = f.read(BLOCKSIZE)
                if len(buf) == 0:
                    break
                hash.update(buf)

        data['files'][path] = hash.hexdigest()

data['package'] = sys.argv[1]

with open('.cargo-checksum.json', 'w') as f:
    f.write(json.dumps(data, separators=(',', ':'), sort_keys=True))
