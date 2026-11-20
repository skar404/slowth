#!/usr/bin/env python3
"""Compatibility entry point for generating all localized privacy pages."""
import sys
from render_slowth import main
if __name__ == '__main__':
    sys.argv += ['--page', 'privacy']
    main()
