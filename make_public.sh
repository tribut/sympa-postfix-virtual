#!/bin/sh

# execute after git operations. makes the files globally readable/executable.
chmod 755 .
find scripts -exec chmod 755 {} \;
find templates -type f -exec chmod 644 {} \;
find templates -type d -exec chmod 755 {} \;

