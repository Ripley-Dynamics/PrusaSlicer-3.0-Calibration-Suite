"""python3 -m port29 <step> [options] -o file.3mf"""

import argparse
import sys

from . import slab
from .common import parse_bed


def main(argv=None):
    ap = argparse.ArgumentParser(prog="python3 -m port29",
                                 description="Filament Dial-In test prints as PrusaSlicer 2.9 projects (3MF).")
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("-o", "--output", help="output .3mf (default: a name from the step and tag)")
    common.add_argument("--bed", type=parse_bed, default=(250.0, 210.0),
                        help="bed size WxD in mm, the object is centred on it (default 250x210, MK4S; CORE One 250x220; CORE One L 300x300; XL 360x360)")
    sub = ap.add_subparsers(dest="step", required=True)
    slab.add_cli(sub, common)
    args = ap.parse_args(argv)
    args.run(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
