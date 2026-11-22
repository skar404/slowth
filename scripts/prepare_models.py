#!/usr/bin/env python3
"""Prepare pinned app models from an explicit archive or frozen exports."""
import argparse
from pathlib import Path
from model_assets import ROOT, prepare, verify, write_bundle


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', choices=['Debug', 'Release'], default='Release')
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--exports-root', type=Path)
    source.add_argument('--model-bundle', type=Path)
    source.add_argument('--check', action='store_true')
    parser.add_argument('--output-bundle', type=Path, help='New local archive; Debug archives remain private')
    args = parser.parse_args()
    if not args.check:
        prepare(ROOT, args.configuration, exports_root=args.exports_root, bundle=args.model_bundle)
    verify(ROOT, args.configuration)
    if args.output_bundle:
        write_bundle(ROOT, args.configuration, args.output_bundle)
    print(f'{args.configuration} model resources verified')


if __name__ == '__main__':
    main()
